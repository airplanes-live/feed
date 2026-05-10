#!/usr/bin/env bash

# MLAT enable/disable management. Operator-facing alternative to editing
# /etc/airplanes/feed.env by hand.
#
# The on-disk schema (since commit 2851612) treats MLAT_USER as a name and
# MLAT_ENABLED as the state flag. These commands flip MLAT_ENABLED while
# preserving MLAT_USER, so a disable→enable round-trip restores the
# operator's previously-configured name.
#
# Empty MLAT_USER is filled in with "Anonymous" on enable so the runtime
# (which strict-fails empty MLAT_USER + MLAT_ENABLED=true) never trips on
# a name that was never set in non-interactive setup.

DEFAULT_MLAT_NAME="Anonymous"

# Skip the systemctl restart when running against a non-host filesystem
# (--root /mnt/...) or under AIRPLANES_BUILD_MODE=1 (image build-time
# invocation, no live systemd to talk to). File edits still happen.
_mlat_should_skip_restart() {
    if [[ "$ROOT" != "/" ]]; then
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
        return 0
    fi
    case "${AIRPLANES_BUILD_MODE:-}" in
        1|true|yes)
            echo "Skipping service restart (AIRPLANES_BUILD_MODE set)" >&2
            return 0
            ;;
    esac
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_mlat_restart_service() {
    if _mlat_should_skip_restart; then
        return 0
    fi
    if ! systemctl restart airplanes-mlat 2>&1; then
        echo "service restart failed; recent journal output:" >&2
        journalctl -u airplanes-mlat -n 10 --no-pager 2>/dev/null >&2 || true
        return 1
    fi
}

# Atomic rewrite of feed.env that updates MLAT_USER and MLAT_ENABLED while
# preserving every other key, line ordering of unrelated keys, and file
# mode/owner. Mirrors update-migrations.sh's migrate_user_to_mlat_split
# pattern (mktemp same-dir, drop existing keys via grep -v, append the
# canonical pair, chmod/chown --reference, mv -f).
_mlat_rewrite_feed_env() {
    local feed_env="$1"
    local new_user="$2"
    local new_enabled="$3"

    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"

    # Refuse to "fix" an unmigrated install — silently inserting MLAT_USER
    # / MLAT_ENABLED into a feed.env that still has the legacy USER= would
    # cross update-migrations.sh's responsibility and produce a confusing
    # mid-state.
    if ! grep -qE '^MLAT_USER=' "$feed_env"; then
        die "feed.env at $feed_env appears unmigrated (no MLAT_USER= line); run \`sudo /usr/local/share/airplanes/update.sh\` first"
    fi

    local tmp escaped
    tmp="$(mktemp "${feed_env}.XXXXXX")"
    grep -vE '^(MLAT_USER|MLAT_ENABLED)=' "$feed_env" > "$tmp" || true
    # Same escape rule as migrate_user_to_mlat_split — make sourcing the
    # written file produce the literal username, no expansion.
    escaped="${new_user//\\/\\\\}"
    escaped="${escaped//\$/\\\$}"
    escaped="${escaped//\`/\\\`}"
    escaped="${escaped//\"/\\\"}"
    printf 'MLAT_USER="%s"\n' "$escaped" >> "$tmp"
    printf 'MLAT_ENABLED=%s\n' "$new_enabled" >> "$tmp"
    chmod --reference="$feed_env" "$tmp" 2>/dev/null || true
    chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$feed_env"
}

apl_feed_mlat_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat disable: $1" ;;
        esac
    done

    local feed_env current_user
    feed_env="$(feed_env_path)"
    current_user="$(feed_env_get MLAT_USER 2>/dev/null || true)"

    _mlat_rewrite_feed_env "$feed_env" "$current_user" "false"
    echo "MLAT_ENABLED set to false in $feed_env"
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done (daemon will sleep while disabled)"
    else
        return 1
    fi
}

apl_feed_mlat_enable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat enable: $1" ;;
        esac
    done

    local feed_env user
    feed_env="$(feed_env_path)"
    user="$(feed_env_get MLAT_USER 2>/dev/null || true)"
    if [[ -z "$user" ]]; then
        user="$DEFAULT_MLAT_NAME"
        echo "MLAT_USER was empty; filling in with default \"$DEFAULT_MLAT_NAME\""
    fi

    _mlat_rewrite_feed_env "$feed_env" "$user" "true"
    echo "MLAT_ENABLED set to true in $feed_env"
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done"
    else
        return 1
    fi
}

dispatch_mlat() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "mlat requires a subcommand (enable|disable)"
    shift || true
    case "$sub" in
        enable)  apl_feed_mlat_enable  "$@" ;;
        disable) apl_feed_mlat_disable "$@" ;;
        -h|--help) usage ;;
        *) die "unknown mlat subcommand: $sub" ;;
    esac
}

# Status reporting lives in `apl-feed status`, which reads the daemon's
# runtime state file via scripts/lib/state-reader.sh. A focused
# `apl-feed mlat status` would either duplicate that logic or violate
# the "CLI side does not re-derive predicates from feed.env" rule —
# neither pays back vs. just running `apl-feed status`.
