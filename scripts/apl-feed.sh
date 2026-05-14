#!/usr/bin/env bash
# apl-feed - feeder-side management CLI for airplanes.live.

set -euo pipefail

resolve_lib_dir() {
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/apl-feed" ]]; then
        printf '%s\n' "$script_dir/apl-feed"
    else
        printf '%s\n' '/usr/local/share/airplanes/apl-feed'
    fi
}

APL_FEED_LIB_DIR="${APL_FEED_LIB_DIR:-$(resolve_lib_dir)}"

# Resolve the daemon-lib directory ($IPATH/lib in production, ../lib in the
# repo checkout) so apl-feed can source pure-function libs like
# configure-validators.sh that ship alongside the daemons.
resolve_daemon_lib_dir() {
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/lib" ]]; then
        printf '%s\n' "$script_dir/lib"
    else
        printf '%s\n' '/usr/local/share/airplanes/lib'
    fi
}
APL_FEED_DAEMON_LIB_DIR="${APL_FEED_DAEMON_LIB_DIR:-$(resolve_daemon_lib_dir)}"

# Pure-function validators shared with configure.sh. Sourced defensively
# (mirrors apl-feed/status.sh's state-reader fallback) so a partial install
# missing the lib produces a clear error at first use rather than failing
# every CLI invocation.
if [[ -r "$APL_FEED_DAEMON_LIB_DIR/configure-validators.sh" ]]; then
    # shellcheck source=scripts/lib/configure-validators.sh
    source "$APL_FEED_DAEMON_LIB_DIR/configure-validators.sh"
else
    valid_latitude()         { echo "configure-validators.sh missing at $APL_FEED_DAEMON_LIB_DIR; reinstall feed" >&2; return 2; }
    valid_longitude()        { valid_latitude "$@"; }
    valid_altitude()         { valid_latitude "$@"; }
    normalize_altitude()     { valid_latitude "$@"; }
    sanitize_mlat_user()     { valid_latitude "$@"; }
    valid_mlat_user_strict() { valid_latitude "$@"; }
    valid_bool()             { valid_latitude "$@"; }
    valid_gain()             { valid_latitude "$@"; }
    valid_uat_input()        { valid_latitude "$@"; }
    valid_dump978_serial()   { valid_latitude "$@"; }
    valid_dump978_gain()     { valid_latitude "$@"; }
fi

# Feed-env key registry + apply library. Pure data + pure functions, no
# side effects. Sourced defensively so a missing install still produces a
# clear error rather than crashing every CLI invocation.
if [[ -r "$APL_FEED_DAEMON_LIB_DIR/feed-env-keys.sh" ]]; then
    # shellcheck source=scripts/lib/feed-env-keys.sh
    source "$APL_FEED_DAEMON_LIB_DIR/feed-env-keys.sh"
else
    apl_feed_is_writable_key() { return 1; }
    apl_feed_is_readable_key() { return 1; }
    declare -ga APL_FEED_WRITABLE_KEYS=()
    declare -ga APL_FEED_READABLE_KEYS=()
    declare -gA APL_FEED_KEY_TYPE=()
    declare -gA APL_FEED_KEY_RESTART=()
fi
if [[ -r "$APL_FEED_DAEMON_LIB_DIR/feed-env-apply.sh" ]]; then
    # shellcheck source=scripts/lib/feed-env-apply.sh
    source "$APL_FEED_DAEMON_LIB_DIR/feed-env-apply.sh"
else
    apl_feed_apply() {
        echo "feed-env-apply.sh missing at $APL_FEED_DAEMON_LIB_DIR; reinstall feed" >&2
        APL_APPLY_STATUS=usage_error
        return 5
    }
fi

# Legacy-key translation helpers (single source of truth for the
# PRIVACY / MLAT_MARKER → MLAT_PRIVATE mapping used by import.sh, the
# update-time migration, and the daemon runtime fallback). Defensive
# source mirrors the pattern above.
if [[ -r "$APL_FEED_DAEMON_LIB_DIR/legacy-mlat-translation.sh" ]]; then
    # shellcheck source=scripts/lib/legacy-mlat-translation.sh
    source "$APL_FEED_DAEMON_LIB_DIR/legacy-mlat-translation.sh"
else
    derive_mlat_private_from_privacy() { return 1; }
    derive_mlat_private_from_marker()  { return 1; }
fi

# shellcheck source=scripts/apl-feed/common.sh
source "$APL_FEED_LIB_DIR/common.sh"
# shellcheck source=scripts/apl-feed/http.sh
source "$APL_FEED_LIB_DIR/http.sh"
# shellcheck source=scripts/apl-feed/claim.sh
source "$APL_FEED_LIB_DIR/claim.sh"
# shellcheck source=scripts/apl-feed/id.sh
source "$APL_FEED_LIB_DIR/id.sh"
# shellcheck source=scripts/apl-feed/status.sh
source "$APL_FEED_LIB_DIR/status.sh"
# shellcheck source=scripts/apl-feed/backup.sh
source "$APL_FEED_LIB_DIR/backup.sh"
# shellcheck source=scripts/apl-feed/mlat.sh
source "$APL_FEED_LIB_DIR/mlat.sh"
# shellcheck source=scripts/apl-feed/uat.sh
source "$APL_FEED_LIB_DIR/uat.sh"
# shellcheck source=scripts/apl-feed/diagnostics.sh
source "$APL_FEED_LIB_DIR/diagnostics.sh"
# shellcheck source=scripts/apl-feed/apply.sh
source "$APL_FEED_LIB_DIR/apply.sh"
# shellcheck source=scripts/apl-feed/schema.sh
source "$APL_FEED_LIB_DIR/schema.sh"
# shellcheck source=scripts/apl-feed/import.sh
source "$APL_FEED_LIB_DIR/import.sh"

main() {
    local cmd="${1:-}"
    case "$cmd" in
        status)
            shift
            feed_status "$@"
            ;;
        claim)
            shift
            dispatch_claim "$@"
            ;;
        id)
            shift
            dispatch_id "$@"
            ;;
        backup)
            shift
            config_backup "$@"
            ;;
        restore)
            shift
            config_restore "$@"
            ;;
        mlat)
            shift
            dispatch_mlat "$@"
            ;;
        978)
            shift
            dispatch_uat "$@"
            ;;
        diagnostics)
            shift
            dispatch_diagnostics "$@"
            ;;
        apply)
            shift
            apl_feed_apply_cli "$@"
            ;;
        schema)
            shift
            apl_feed_schema_cli "$@"
            ;;
        import)
            shift
            dispatch_import "$@"
            ;;
        -h|--help|'')
            usage
            ;;
        *)
            die "unknown command: $cmd"
            ;;
    esac
}

main "$@"
