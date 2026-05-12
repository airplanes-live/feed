#!/usr/bin/env bash
# `apl-feed apply` — JSON adapter around the feed-env-apply library.
#
# Reads a JSON payload on stdin shaped as `{"updates": {"KEY": "value", ...}}`,
# calls apl_feed_apply with the pairs, prints a structured JSON response,
# exits with the contract codes documented below.
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
#   {"status":"no_change", "changed":[]}
#   {"status":"rejected", "errors":{"KEY":"reason",...}}
#   {"status":"lock_timeout", "message":"could not acquire lock after Ns"}
#   {"status":"filesystem_error", "message":"..."}
#   {"status":"parse_error", "message":"..."}
#   {"status":"usage_error", "message":"..."}

apl_feed_apply_cli() {
    require_jq

    local feed_env lock_path skip_restart=0 lock_timeout=""
    feed_env="$(root_path '/etc/airplanes/feed.env')"
    lock_path="$(root_path '/run/airplanes/feed-env.lock')"

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
                [[ $# -ge 2 ]] || die "--lock-timeout requires SECS"
                lock_timeout="$2"
                shift 2
                ;;
            --json) shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown flag for apply: $1" ;;
        esac
    done

    # Re-resolve in case --root changed ROOT after the initial expansion.
    feed_env="$(root_path '/etc/airplanes/feed.env')"
    lock_path="$(root_path '/run/airplanes/feed-env.lock')"

    local payload
    if ! payload="$(cat)"; then
        _apl_feed_apply_emit_error parse_error "stdin read failed"
        return 5
    fi
    if [[ -z "${payload//[[:space:]]/}" ]]; then
        payload='{"updates":{}}'
    fi

    # Validate JSON shape and pull out flat KEY=value pairs.
    local -a pairs=()
    local err
    if ! err="$(jq -e 'type=="object" and (.updates|type=="object")' <<<"$payload" 2>&1)"; then
        _apl_feed_apply_emit_error parse_error "payload must be an object with an \"updates\" object"
        return 5
    fi
    # Reject non-string values up front — Go side sends strings; anything
    # else is a client bug we want to flag, not coerce.
    local non_string
    non_string="$(jq -r '.updates | to_entries | map(select(.value|type!="string")) | length' <<<"$payload")"
    if [[ "$non_string" != "0" ]]; then
        _apl_feed_apply_emit_error parse_error "updates values must be strings"
        return 5
    fi
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pairs+=("$line")
    done < <(jq -r '.updates | to_entries[] | "\(.key)=\(.value)"' <<<"$payload")

    local -a apply_args=()
    (( skip_restart == 1 )) && apply_args+=(--no-restart)
    [[ -n "$lock_timeout" ]] && apply_args+=(--lock-timeout "$lock_timeout")
    apply_args+=(--feed-env "$feed_env" --lock-file "$lock_path")
    apply_args+=("${pairs[@]}")

    local rc=0
    apl_feed_apply "${apply_args[@]}" || rc=$?

    case "$APL_APPLY_STATUS" in
        applied)
            jq -nc \
                --argjson changed "$(_apl_feed_apply_array_json APL_APPLY_CHANGED)" \
                --argjson pending "$(_apl_feed_apply_array_json APL_APPLY_PENDING_RESTART)" \
                '{status:"applied", changed:$changed, pending_restart:$pending}'
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
