#!/usr/bin/env bash
# Runtime state writer. Daemons call airplanes_write_state to publish
# their config decision to a state file consumed by apl-feed status,
# render-status, and the webconfig dashboard.
#
# Format: env-style, line-based. First line is schema_version=1
# (writer-emitted; caller MUST NOT supply this key). Subsequent lines
# are KEY=VALUE in caller-provided order. Values are emitted verbatim
# (no shell-quoting). Newlines and carriage returns in values are
# rejected. Keys must match [A-Za-z_][A-Za-z0-9_]*.
#
# Atomic: writes a temp file in the same directory, then renames over
# the target. Readers may see the previous file or the new file, never
# a partial mix. Mode 0644 (state is not sensitive).
#
# Lifecycle: state file is written ONCE per daemon activation, before
# any sleep/exec/exit. It represents the daemon's config decision at
# activation time, NOT live runtime status. Mid-run updates are NOT
# emitted; live runtime status (process alive, exec succeeded, child
# connected) is observable via systemd liveness, journal output, and
# external probes.
#
# Dedupe: when an activation re-runs the wrapper and produces the same
# decision (the common case for wrappers that sleep + exit 0 under
# Restart=always — dump978-fa's no_hardware loop, airplanes-mlat's
# disabled loop), the writer skips the atomic-rename if the proposed
# content equals the current file content, ignoring decided_at= (which
# is by convention a per-activation timestamp every caller refreshes).
# Net effects: mtime stays at the time of the last *material* change,
# inotify consumers (e.g. systemd .path units) don't fire on no-op
# re-runs. AIRPLANES_WRITE_STATE_FORCE=1 disables this and always
# atomically replaces the target.
#
# Readers MUST NOT `source` this file — values are unquoted; arbitrary
# string content (e.g. user-supplied MLAT_USER) could contain shell
# metacharacters. Parse line-by-line with KEY=VALUE split on first `=`.
#
# Usage:
#   airplanes_write_state /run/airplanes-mlat/state \
#       service=airplanes-mlat \
#       state=disabled \
#       reason=mlat_enabled_false \
#       decided_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
#       mlat_enabled=false \
#       mlat_user=
#
# Returns 0 on success, 1 on validation failure or write error
# (target file is left unchanged on either). Returns 0 with target
# unchanged when the dedupe path skips the rename.

# Print $1's content with decided_at= lines filtered out. Used by the
# dedupe path so a fresh timestamp on an otherwise-identical decision
# doesn't force a rename. The `|| [[ -n "$line" ]]` tail catches an
# existing target that's missing its final newline — without it the
# loop would silently drop the last line and a proposed write that
# removed a tail field could falsely dedupe against the truncated
# remainder. (The writer's own output always ends in \n, so this only
# matters for files left behind by an interrupted write or external
# tampering.)
_airplanes_write_state_canonical() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            decided_at=*) continue ;;
        esac
        printf '%s\n' "$line"
    done < "$1"
}

airplanes_write_state() {
    local target="$1"; shift
    local tmp
    tmp="$(mktemp "${target}.XXXXXX")" || return 1
    local kv key value rc=0

    {
        printf 'schema_version=1\n'
        for kv in "$@"; do
            case "$kv" in
                *=*) ;;
                *)
                    printf 'state-writer: arg %q is not KEY=VALUE\n' "$kv" >&2
                    rc=1
                    break
                    ;;
            esac
            key="${kv%%=*}"
            value="${kv#*=}"
            if [[ "$key" == "schema_version" ]]; then
                printf 'state-writer: caller-supplied schema_version is rejected\n' >&2
                rc=1
                break
            fi
            if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                printf 'state-writer: invalid key %q\n' "$key" >&2
                rc=1
                break
            fi
            case "$value" in
                *$'\n'*|*$'\r'*)
                    printf 'state-writer: value for %s contains CR/LF; refusing to write\n' "$key" >&2
                    rc=1
                    break
                    ;;
            esac
            printf '%s=%s\n' "$key" "$value"
        done
    } > "$tmp" || rc=1

    if (( rc != 0 )); then
        rm -f "$tmp"
        return 1
    fi

    # Dedupe path: same decision as already on disk → skip the rename.
    # The mode-preserving chmod is also skipped — the existing file's
    # mode reflects an earlier successful write that already set 0644.
    if [[ "${AIRPLANES_WRITE_STATE_FORCE:-}" != "1" ]] \
        && [[ -f "$target" && -r "$target" ]] \
        && [[ "$(_airplanes_write_state_canonical "$tmp")" \
            == "$(_airplanes_write_state_canonical "$target")" ]]; then
        rm -f "$tmp"
        return 0
    fi

    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    return 0
}
