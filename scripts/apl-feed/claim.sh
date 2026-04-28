#!/usr/bin/env bash

claim_page_url() {
    printf '%s/feeder/claim' "${SERVER_URL%/}"
}

print_claim_instructions() {
    local uuid="$1"
    local secret="$2"
    echo
    echo "Your feeder claim secret is ready."
    echo "Feeder ID:    $uuid"
    echo "Claim secret: $(display_secret "$secret")"
    echo
    echo "Use it to claim the feeder at:"
    claim_page_url
    echo
}

claim_register() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            *)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for claim register: $1" ;;
                esac
                ;;
        esac
    done

    require_jq

    local uuid final pending secret reveal_secret response_file deadline backoff
    local status curl_rc error preview version sleep_for reset_until body now
    uuid="$(read_uuid)"
    final="$(secret_final_path)"
    pending="$(secret_pending_path)"
    reveal_secret=0

    if [[ -f "$final" ]]; then
        secret="$(read_secret_file "$final")"
    elif [[ -f "$pending" ]]; then
        secret="$(read_secret_file "$pending")"
        reveal_secret=1
    else
        secret="$(generate_secret)"
        validate_secret "$secret" || die "generated invalid secret"
        reveal_secret=1
        if (( ! DRY_RUN )); then
            write_secret_file "$pending" "$secret"
        fi
    fi

    echo "Feeder ID: $uuid"
    if (( DRY_RUN )); then
        echo "SECRET: $secret"
        echo "(dry-run; would POST to $SERVER_URL/api/feeders/secret)"
        exit 0
    fi

    response_file="$(new_tmp_file)"
    deadline=$(( $(date +%s) + MAX_RETRY_TIME ))
    backoff=1

    while true; do
        body="$(printf '{"uuid":"%s","current_secret":null,"new_secret":"%s"}' "$uuid" "$secret")"
        set +e
        status="$(post_json '/api/feeders/secret' "$body" "$response_file")"
        curl_rc=$?
        set -e

        case "$curl_rc" in
            0) ;;
            6|7|28)
                echo "ERROR: curl rc=$curl_rc (DNS/connect/timeout) - network unreachable" >&2
                return 2
                ;;
            *)
                echo "ERROR: curl rc=$curl_rc - $SERVER_URL/api/feeders/secret unreachable" >&2
                return 2
                ;;
        esac

        error="$(parse_field_from "$response_file" '.error')"
        preview="$(body_preview "$response_file")"

        case "$status" in
            200|201)
                version="$(parse_field_from "$response_file" '.version')"
                : "${version:=1}"
                if [[ -f "$pending" ]]; then
                    mv "$pending" "$final"
                    chmod 600 "$final"
                fi
                write_version_file "$version"
                echo "SUCCESS ($status, version $version)"
                echo "Secret persisted to $final"
                if (( reveal_secret )); then
                    print_claim_instructions "$uuid" "$secret"
                fi
                return 0
                ;;
            400)
                echo "ERROR: 400 bad request - $preview" >&2
                return 1
                ;;
            409)
                case "$error" in
                    legacy_unclaimed)
                        echo "ERROR: 409 legacy_unclaimed - pre-secret-era row needs the website reinstall flow ($preview)" >&2
                        return 4
                        ;;
                    rotation_rejected)
                        echo "ERROR: 409 rotation_rejected - server hash mismatched current_secret; local state has diverged" >&2
                        return 1
                        ;;
                    *)
                        echo "ERROR: 409 with unknown error=${error:-<missing>} - $preview" >&2
                        return 1
                        ;;
                esac
                ;;
            423)
                case "$error" in
                    feeder_blocked)
                        echo "ERROR: 423 feeder_blocked - admin block, no retry ($preview)" >&2
                        return 1
                        ;;
                    reset_locked)
                        reset_until="$(parse_field_from "$response_file" '.reset_until')"
                        [[ -n "$reset_until" ]] || die "423 reset_locked without reset_until field"
                        sleep_for="$(seconds_until_iso "$reset_until")"
                        echo "INFO: 423 reset_locked until $reset_until; sleeping ${sleep_for}s" >&2
                        ;;
                    *)
                        echo "ERROR: 423 with unknown error=${error:-<missing>} - $preview" >&2
                        return 1
                        ;;
                esac
                ;;
            429)
                sleep_for="$(parse_field_from "$response_file" '.retry_after')"
                : "${sleep_for:=5}"
                echo "INFO: 429 rate-limited; sleeping ${sleep_for}s (server retry_after)" >&2
                ;;
            404)
                echo "ERROR: 404 from API - endpoint disabled or wrong server URL ($SERVER_URL) - $preview" >&2
                return 1
                ;;
            5*)
                sleep_for="$backoff"
                backoff=$(( backoff * 2 ))
                (( backoff > 60 )) && backoff=60
                echo "INFO: $status server error; backing off ${sleep_for}s" >&2
                ;;
            *)
                echo "ERROR: unexpected status $status - $preview" >&2
                return 1
                ;;
        esac

        now="$(date +%s)"
        if (( now + sleep_for > deadline )); then
            echo "ERROR: exceeded --max-retry-time=${MAX_RETRY_TIME}s on status $status" >&2
            return 3
        fi
        sleep "$sleep_for"
    done
}

claim_show() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for claim show: $1" ;;
        esac
    done

    local uuid final secret version
    uuid="$(read_uuid)"
    final="$(secret_final_path)"
    [[ -f "$final" ]] || die "no active claim secret at $final"
    secret="$(read_secret_file "$final")"

    echo "Feeder ID: $uuid"
    echo "Claim secret: $(display_secret "$secret")"
    echo "Claim page: $(claim_page_url)"
    if version="$(read_version_file 2>/dev/null)"; then
        echo "Version: $version"
    fi
}

claim_rotate_abort() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for claim rotate --abort: $1" ;;
        esac
    done

    require_jq

    local uuid final pending active pending_secret active_version pending_version
    uuid="$(read_uuid)"
    final="$(secret_final_path)"
    pending="$(secret_pending_path)"
    [[ -f "$pending" ]] || { echo "No pending rotation to abort."; return 0; }
    [[ -f "$final" ]] || die "no active claim secret; refusing to delete pending rotation"
    active="$(read_secret_file "$final")"
    pending_secret="$(read_secret_file "$pending")"

    if pending_version="$(status_probe_version "$uuid" "$pending_secret" 2>/dev/null)"; then
        echo "Pending secret already authenticates with server (version $pending_version); refusing to abort." >&2
        return 1
    fi

    if active_version="$(status_probe_version "$uuid" "$active" 2>/dev/null)"; then
        rm -f "$pending"
        write_version_file "$active_version"
        echo "Pending rotation aborted. Active secret is still accepted by the server (version $active_version)."
        return 0
    fi

    echo "Could not confirm the active secret with the server; refusing to delete pending rotation." >&2
    return 1
}

claim_rotate() {
    if [[ "${1:-}" == "--abort" ]]; then
        shift
        claim_rotate_abort "$@"
        return $?
    fi

    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for claim rotate: $1" ;;
        esac
    done

    require_jq

    local uuid final pending current next response_file deadline backoff
    local body status curl_rc error preview version sleep_for reset_until accepted_version now
    uuid="$(read_uuid)"
    final="$(secret_final_path)"
    pending="$(secret_pending_path)"
    [[ -f "$final" ]] || die "no active claim secret at $final"
    current="$(read_secret_file "$final")"

    if [[ -f "$pending" ]]; then
        next="$(read_secret_file "$pending")"
        echo "Resuming pending rotation."
    else
        next="$(generate_secret)"
        validate_secret "$next" || die "generated invalid secret"
        write_secret_file "$pending" "$next"
    fi

    response_file="$(new_tmp_file)"
    deadline=$(( $(date +%s) + MAX_RETRY_TIME ))
    backoff=1

    while true; do
        body="$(printf '{"uuid":"%s","current_secret":"%s","new_secret":"%s"}' "$uuid" "$current" "$next")"
        set +e
        status="$(post_json '/api/feeders/secret' "$body" "$response_file")"
        curl_rc=$?
        set -e

        case "$curl_rc" in
            0) ;;
            6|7|28)
                echo "ERROR: curl rc=$curl_rc (DNS/connect/timeout) - pending rotation left in place" >&2
                return 2
                ;;
            *)
                echo "ERROR: curl rc=$curl_rc - pending rotation left in place" >&2
                return 2
                ;;
        esac

        error="$(parse_field_from "$response_file" '.error')"
        preview="$(body_preview "$response_file")"

        case "$status" in
            200)
                version="$(parse_field_from "$response_file" '.version')"
                : "${version:=1}"
                mv "$pending" "$final"
                chmod 600 "$final"
                write_version_file "$version"
                echo "Rotation complete (v$version)."
                return 0
                ;;
            409)
                if accepted_version="$(status_probe_version "$uuid" "$next" 2>/dev/null)"; then
                    mv "$pending" "$final"
                    chmod 600 "$final"
                    write_version_file "$accepted_version"
                    echo "Rotation finalized (v$accepted_version) after a previous transient failure."
                    return 0
                fi
                echo "ERROR: 409 ${error:-rotation_rejected} - pending rotation left in place. Run 'apl-feed status' or 'apl-feed claim rotate --abort'." >&2
                return 1
                ;;
            423)
                case "$error" in
                    reset_locked)
                        reset_until="$(parse_field_from "$response_file" '.reset_until')"
                        [[ -n "$reset_until" ]] || die "423 reset_locked without reset_until field"
                        sleep_for="$(seconds_until_iso "$reset_until")"
                        echo "INFO: 423 reset_locked until $reset_until; sleeping ${sleep_for}s" >&2
                        ;;
                    *)
                        echo "ERROR: 423 ${error:-blocked} - pending rotation left in place ($preview)" >&2
                        return 1
                        ;;
                esac
                ;;
            429)
                sleep_for="$(parse_field_from "$response_file" '.retry_after')"
                : "${sleep_for:=5}"
                echo "INFO: 429 rate-limited; sleeping ${sleep_for}s (server retry_after)" >&2
                ;;
            5*)
                sleep_for="$backoff"
                backoff=$(( backoff * 2 ))
                (( backoff > 60 )) && backoff=60
                echo "INFO: $status server error; backing off ${sleep_for}s" >&2
                ;;
            *)
                echo "ERROR: unexpected status $status - pending rotation left in place ($preview)" >&2
                return 1
                ;;
        esac

        now="$(date +%s)"
        if (( now + sleep_for > deadline )); then
            echo "ERROR: exceeded --max-retry-time=${MAX_RETRY_TIME}s on status $status; pending rotation left in place" >&2
            return 3
        fi
        sleep "$sleep_for"
    done
}

dispatch_claim() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "claim requires a subcommand"
    shift || true
    case "$sub" in
        register) claim_register "$@" ;;
        show) claim_show "$@" ;;
        rotate) claim_rotate "$@" ;;
        -h|--help) usage ;;
        *) die "unknown claim subcommand: $sub" ;;
    esac
}
