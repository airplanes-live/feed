#!/usr/bin/env bash
# Runtime state reader. Consumers (apl-feed status, render-status, the
# webconfig snapshot endpoint) call airplanes_read_state to extract a
# single key from a state file written by airplanes_write_state.
#
# Format: see scripts/lib/state-writer.sh. schema_version=1 must be
# present on the first line; other versions return 1 (caller treats
# as "decision unknown").
#
# Reader MUST NOT `source` the file — values are unquoted and may
# contain shell metacharacters. Parse line-by-line.
#
# Usage:
#   if reason="$(airplanes_read_state /run/airplanes/mlat/state reason)"; then
#       printf 'reason=%s\n' "$reason"
#   else
#       printf 'state file unavailable or unparseable\n'
#   fi
#
# Returns 0 with the value on stdout if the key is present.
# Returns 1 (no stdout) if:
#   - file doesn't exist or isn't a regular file
#   - file is unreadable
#   - schema_version != 1 on the first line
#   - key not found in file
#   - value contains \r (corrupt file — writer never emits CR)
#   - key arg doesn't match the writer's key constraint
#     ([A-Za-z_][A-Za-z0-9_]*)

airplanes_read_state() {
    local file="$1"
    local key="$2"
    [[ -f "$file" && -r "$file" ]] || return 1
    if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        return 1
    fi
    local first=1 line value
    # Single-pass: one open, validate schema on first line, then scan.
    # Avoids generation-mix if a writer renames the file between two
    # opens. Caller still trusts the writer's mktemp+rename atomicity.
    while IFS= read -r line; do
        if (( first )); then
            first=0
            [[ "$line" == 'schema_version=1' ]] || return 1
            continue
        fi
        case "$line" in
            "${key}="*)
                value="${line#"${key}="}"
                case "$value" in
                    *$'\r'*) return 1 ;;
                esac
                printf '%s' "$value"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}
