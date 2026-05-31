#!/usr/bin/env bash
# `apl-feed apply` — JSON adapter around the feed-env-apply library.
#
# Reads a JSON payload on stdin. Two value shapes are accepted per key:
#
#   {"updates": {"KEY": "bare-string-value", ...}}
#
#   {"updates": {"KEY": {"value": "...",
#                        "edited_at": "RFC 3339 UTC",
#                        "edited_by": "feeder|website|legacy"}, ...}}
#
# The object form is only accepted for sidecar-tracked keys (LATITUDE,
# LONGITUDE, ALTITUDE, MLAT_USER, MLAT_ENABLED, MLAT_PRIVATE). For those
# keys, the object's edited_at/edited_by tuple is written into
# /etc/airplanes/feed.meta.json under the same atomic lock as feed.env.
# Bare-string writes to tracked keys default-stamp edited_by=feeder,
# edited_at=now() when the value actually changes.
#
# Exit codes:
#   0 - applied (write succeeded; pending_restart may be non-empty) or no_change
#   2 - rejected (validation failure; nothing written)
#   3 - filesystem_error
#   4 - lock_timeout
#   5 - usage_error / parse_error
#
# JSON response shapes:
#   {"status":"applied", "changed":[...], "pending_restart":[]}
#       (may also include "pending_meta_warning":"..." when the sidecar
#        write failed but feed.env was updated)
#   {"status":"no_change", "changed":[]}
#   {"status":"rejected", "errors":{"KEY":"reason",...}}
#   {"status":"lock_timeout", "message":"could not acquire lock after Ns"}
#   {"status":"filesystem_error", "message":"..."}
#   {"status":"parse_error", "message":"..."}
#   {"status":"usage_error", "message":"..."}

usage_apply() {
    cat <<'USAGE'
Usage: apl-feed apply [--no-restart] [--lock-timeout SECS]

Reads a JSON payload of config updates on stdin and applies them to
feed.env via the canonical writer, emitting a JSON result. --no-restart
suppresses the post-apply service restart; --lock-timeout caps how long to
wait for the feed.env lock.
USAGE
}

apl_feed_apply_cli() {
    # Help must work without jq installed — handle it before require_jq.
    local _arg
    for _arg in "$@"; do
        case "$_arg" in -h|--help) usage_apply; exit 0 ;; esac
    done

    require_jq

    local feed_env lock_path skip_restart=0 lock_timeout=""
    feed_env="$(root_path '/etc/airplanes/feed.env')"
    lock_path="$(feed_env_lock_path)"

    while (( $# > 0 )); do
        local opt_rc
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift; continue ;;
            2) shift 2; continue ;;
        esac
        case "$1" in
            --no-restart) skip_restart=1; shift ;;
            --lock-timeout)
                if [[ $# -lt 2 ]]; then
                    _apl_feed_apply_emit_error usage_error "--lock-timeout requires SECS"
                    return 5
                fi
                lock_timeout="$2"
                shift 2
                ;;
            --json) shift ;;
            -h|--help) usage_apply; exit 0 ;;
            *)
                _apl_feed_apply_emit_error usage_error "unknown flag for apply: $1"
                return 5
                ;;
        esac
    done

    # Re-resolve in case --root changed ROOT after the initial expansion.
    feed_env="$(root_path '/etc/airplanes/feed.env')"
    lock_path="$(feed_env_lock_path)"

    local payload
    if ! payload="$(cat)"; then
        _apl_feed_apply_emit_error parse_error "stdin read failed"
        return 5
    fi
    if [[ -z "${payload//[[:space:]]/}" ]]; then
        payload='{"updates":{}}'
    fi

    # Validate JSON shape and pull out flat KEY=value pairs.
    #
    # Every jq invocation is wrapped in `if ! result="$(jq ...)"` so a
    # jq failure under apl-feed.sh's `set -euo pipefail` returns a
    # structured parse_error envelope instead of a bash abort. The schema
    # check is a single jq call that returns "ok" or the first violation
    # message — keeps the validator readable and the failure path uniform.
    #
    # Two value shapes are accepted per key in .updates:
    #   string                                                 (existing)
    #   {value: string, edited_at: string, edited_by: string}  (new)
    # The object form is only meaningful for sidecar-tracked keys; the
    # library rejects metadata on non-tracked keys with status=rejected,
    # not parse_error. The shape check here is purely structural.
    local -a pairs=()
    local schema_check
    if ! schema_check="$(jq -r '
        if (type != "object") then "payload must be an object"
        elif (.updates | type != "object") then "payload.updates must be an object"
        else
          ([.updates | to_entries[] | (
            if (.value | type) == "string" then empty
            elif (.value | type) == "object" then
              if (.value.value | type) != "string" then "\(.key): .value must be a string"
              elif (.value.edited_at | type) != "string" then "\(.key): .edited_at must be a string"
              elif (.value.edited_by | type) != "string" then "\(.key): .edited_by must be a string"
              elif ([.value.edited_by] | inside(["feeder","website","legacy"]) | not) then "\(.key): .edited_by must be feeder/website/legacy"
              elif ((.value.edited_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?Z$")) | not) then "\(.key): .edited_at must be RFC 3339 UTC (max 6 fractional digits)"
              else empty end
            else "\(.key): value must be a string or {value,edited_at,edited_by}"
            end
          )] | if length == 0 then "ok" else .[0] end)
        end' <<<"$payload" 2>/dev/null)"; then
        _apl_feed_apply_emit_error parse_error "payload validation failed"
        return 5
    fi
    if [[ "$schema_check" != "ok" ]]; then
        _apl_feed_apply_emit_error parse_error "$schema_check"
        return 5
    fi
    # Defense-in-depth: refuse any KEY containing characters that would
    # escape the bash "KEY=value" line protocol used by the inner library.
    # Without this, a payload key like "GAIN=42.5\nMLAT_USER" would split
    # into two pairs after the jq -r conversion, and a key containing NUL
    # would silently collapse (Bash strips NUL from command substitution).
    # The library's writable-key whitelist would still reject the malformed
    # halves, but rejecting structurally-broken keys here keeps the
    # parse_error envelope honest.
    local bad_key
    if ! bad_key="$(jq -r '
        [.updates | to_entries[].key |
          select(test("[^A-Za-z0-9_]"))][0] // ""' <<<"$payload" 2>/dev/null)"; then
        _apl_feed_apply_emit_error parse_error "key validation failed"
        return 5
    fi
    if [[ -n "$bad_key" ]]; then
        _apl_feed_apply_emit_error parse_error "key contains forbidden character (only [A-Za-z0-9_] allowed): $bad_key"
        return 5
    fi
    # Defense-in-depth: refuse any value containing LF / CR / NUL before
    # converting to KEY=value pairs. `jq -r | read` would otherwise split
    # an embedded newline into a fake second pair (and Bash silently
    # strips NUL from `read`'s line buffer). Per-key validators run after
    # this; this guard exists so they cannot be bypassed.
    local has_bad_byte
    if ! has_bad_byte="$(jq -r '
        [.updates | to_entries[] |
          (if (.value | type) == "string" then .value else .value.value end) |
          select(test("[\\x00\\r\\n]"))] | length' <<<"$payload" 2>/dev/null)"; then
        _apl_feed_apply_emit_error parse_error "byte-scan failed"
        return 5
    fi
    if [[ "$has_bad_byte" != "0" ]]; then
        _apl_feed_apply_emit_error parse_error "updates values must not contain CR / LF / NUL"
        return 5
    fi
    local pairs_blob
    if ! pairs_blob="$(jq -r '
        .updates | to_entries[] |
        if (.value | type) == "string" then "\(.key)=\(.value)"
        else "\(.key)=\(.value.value)" end' <<<"$payload" 2>/dev/null)"; then
        _apl_feed_apply_emit_error parse_error "pair extraction failed"
        return 5
    fi
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pairs+=("$line")
    done <<< "$pairs_blob"

    # Extract per-field metadata for object-form entries into the two
    # parallel input maps that apl_feed_apply snapshots at function entry.
    # The library does its own tracked-key / edited_by-enum / edited_at
    # validation against the values we pass through here.
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
    local meta_blob
    if ! meta_blob="$(jq -r '
        .updates | to_entries[] |
        select((.value | type) == "object") |
        "\(.key)\t\(.value.edited_at)\t\(.value.edited_by)"' <<<"$payload" 2>/dev/null)"; then
        _apl_feed_apply_emit_error parse_error "metadata extraction failed"
        return 5
    fi
    local meta_key meta_at meta_by
    while IFS=$'\t' read -r meta_key meta_at meta_by; do
        [[ -z "$meta_key" ]] && continue
        APL_APPLY_INCOMING_META_EDITED_AT[$meta_key]="$meta_at"
        APL_APPLY_INCOMING_META_EDITED_BY[$meta_key]="$meta_by"
    done <<< "$meta_blob"

    # Auto-bootstrap canonical feed.env from /boot/airplanes-config.txt
    # when running on a bridged-legacy box (airplanes-feeder installed,
    # no canonical feed.env yet). The new Go webconfig is the only
    # consumer of this CLI in production today and ships only on the new
    # image (which has feed.env at build time), so this is defensive
    # against future use of `apl-feed apply --json` from a runtime that
    # touches a bridged-legacy filesystem.
    feed_env_ensure_canonical_for_write

    local -a apply_args=()
    # Implicit --no-restart when writing to a non-host rootfs. webconfig
    # invokes `apl-feed apply --json` from the host with ROOT=/, so the
    # restart fan-out fires on a real save. A scratch invocation like
    # `apl-feed apply --root /mnt --json` must NOT touch host services.
    if (( skip_restart == 1 )) || [[ "$ROOT" != "/" ]]; then
        apply_args+=(--no-restart)
    fi
    # Implicit --no-audit when writing to a non-host rootfs: a scratch
    # rootfs save is not an event worth logging to the host's journal.
    # Audit gating is independent of restart gating — a deliberate
    # --no-restart on the host (e.g., import.sh first-run) still audits.
    if [[ "$ROOT" != "/" ]]; then
        apply_args+=(--no-audit)
    fi
    [[ -n "$lock_timeout" ]] && apply_args+=(--lock-timeout "$lock_timeout")
    apply_args+=(--feed-env "$feed_env" --lock-file "$lock_path")
    apply_args+=(--meta-file "$(root_path '/etc/airplanes/feed.meta.json')")
    apply_args+=("${pairs[@]}")

    local rc=0
    apl_feed_apply "${apply_args[@]}" || rc=$?

    case "$APL_APPLY_STATUS" in
        applied)
            jq -nc \
                --argjson changed "$(_apl_feed_apply_array_json APL_APPLY_CHANGED)" \
                --argjson pending "$(_apl_feed_apply_array_json APL_APPLY_PENDING_RESTART)" \
                --arg meta_warn "${APL_APPLY_PENDING_META_WARNING:-}" \
                '{status:"applied", changed:$changed, pending_restart:$pending} +
                 (if $meta_warn != "" then {pending_meta_warning:$meta_warn} else {} end)'
            return 0
            ;;
        no_change)
            jq -nc '{status:"no_change", changed:[]}'
            return 0
            ;;
        rejected)
            jq -nc \
                --argjson errors "$(_apl_feed_apply_errors_json)" \
                '{status:"rejected", errors:$errors}'
            return 2
            ;;
        lock_timeout)
            jq -nc --arg msg "$APL_APPLY_ERROR_MESSAGE" \
                '{status:"lock_timeout", message:$msg}'
            return 4
            ;;
        filesystem_error)
            jq -nc --arg msg "$APL_APPLY_ERROR_MESSAGE" \
                '{status:"filesystem_error", message:$msg}'
            return 3
            ;;
        usage_error|*)
            jq -nc --arg msg "${APL_APPLY_ERROR_MESSAGE:-unknown apply status}" \
                '{status:"usage_error", message:$msg}'
            return 5
            ;;
    esac
    return $rc
}

_apl_feed_apply_emit_error() {
    local status="$1" message="$2"
    jq -nc --arg s "$status" --arg m "$message" '{status:$s, message:$m}'
}

_apl_feed_apply_array_json() {
    local -n arr_ref="$1"
    if (( ${#arr_ref[@]} == 0 )); then
        printf '[]'
        return
    fi
    printf '%s\n' "${arr_ref[@]}" | jq -R . | jq -sc .
}

_apl_feed_apply_errors_json() {
    if (( ${#APL_APPLY_ERRORS[@]} == 0 )); then
        printf '{}'
        return
    fi
    local key
    local pairs=()
    for key in "${!APL_APPLY_ERRORS[@]}"; do
        pairs+=("$(jq -nc --arg k "$key" --arg v "${APL_APPLY_ERRORS[$key]}" '{($k):$v}')")
    done
    printf '%s\n' "${pairs[@]}" | jq -sc 'add // {}'
}
