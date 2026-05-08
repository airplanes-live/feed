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
# (target file is left unchanged on either).

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

    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    return 0
}
