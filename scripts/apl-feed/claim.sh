#!/usr/bin/env bash

claim_page_url() {
    printf '%s/feeder/claim' "${WEBSITE_URL%/}"
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
        echo "(dry-run; would POST to $WEBSITE_URL/api/feeders/secret)"
        exit 0
    fi

    response_file="$(new_tmp_file)"
    deadline=$(( $(date +%s) + MAX_RETRY_TIME ))
    backoff=1

    while true; do
        # v2 wire shape: Authorization: Bearer alv1.<uuid>.<auth_secret> +
        # body {"new_secret":...}. For register there is no prior secret
        # to authenticate with — the bearer carries the same value being
        # registered ("tautology"). The server ignores the bearer secret
        # on the CREATE branch and stores hash(body.new_secret).
        body="$(printf '{"new_secret":"%s"}' "$secret")"
        local token
        token="$(apl_auth_token "$uuid" "$secret")"
        set +e
        status="$(post_json_bearer "$token" '/api/feeders/secret' "$body" "$response_file")"
        curl_rc=$?
        set -e

        case "$curl_rc" in
            0) ;;
            6|7|28)
                # Transient network conditions (DNS not yet resolvable, no
                # route, connect timeout). Exit 75 (EX_TEMPFAIL) so the
                # caller's systemd unit can map it via SuccessExitStatus=
                # and the timer's OnUnitActiveSec= re-arms cleanly off a
                # dead-not-failed unit. Exit 2 stays reserved for argv /
                # config errors that retry can't fix.
                echo "ERROR: curl rc=$curl_rc (DNS/connect/timeout) - network unreachable" >&2
                return 75
                ;;
            *)
                # Other curl failures (SSL handshake, recv error, etc.) are
                # also retry-worthy from the timer's perspective, so use 75
                # rather than 2.
                echo "ERROR: curl rc=$curl_rc - $WEBSITE_URL/api/feeders/secret unreachable" >&2
                return 75
                ;;
        esac

        error="$(parse_field_from "$response_file" '.error')"
        preview="$(body_preview "$response_file")"

        case "$status" in
            200|201)
                version="$(parse_field_from "$response_file" '.version')"
                : "${version:=1}"
                if [[ -f "$pending" ]]; then
                    chown_claim_state "$pending"
                    chmod 640 "$pending"
                    mv "$pending" "$final"
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
                echo "ERROR: 404 from API - endpoint disabled or wrong website URL ($WEBSITE_URL) - $preview" >&2
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
        # v2 wire shape: Authorization: Bearer alv1.<uuid>.<current> +
        # body {"new_secret": next}. Server verifies hash(current) against
        # the stored hash for the rotate path. The replay-after-network-
        # failure path (server already accepted next; client retries) is
        # preserved verbatim — server's NOOP_REPLAY check runs before the
        # rotate-current-check, so a stale bearer with the matching body
        # new_secret still returns 200.
        body="$(printf '{"new_secret":"%s"}' "$next")"
        local token
        token="$(apl_auth_token "$uuid" "$current")"
        set +e
        status="$(post_json_bearer "$token" '/api/feeders/secret' "$body" "$response_file")"
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
                chown_claim_state "$pending"
                chmod 640 "$pending"
                mv "$pending" "$final"
                write_version_file "$version"
                echo "Rotation complete (v$version)."
                return 0
                ;;
            409)
                if accepted_version="$(status_probe_version "$uuid" "$next" 2>/dev/null)"; then
                    chown_claim_state "$pending"
                    chmod 640 "$pending"
                    mv "$pending" "$final"
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

claim_set() {
    # Save a claim secret minted by the website (e.g. the same-IP claim
    # legacy bootstrap, the owner-side Reset secret flow, or a support
    # reset) and restart feeder services so the new value takes effect
    # immediately. The secret is read from stdin (TTY prompts; pipes work
    # too) so the value never lands in argv or shell history.
    #
    # Refuses to overwrite an existing different secret unless --force is
    # passed; a no-op when the supplied secret already matches the local
    # one.
    local opt_rc force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                # shellcheck disable=SC2034  # tracked locally; not exported
                force=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            *)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for claim set: $1" ;;
                esac
                ;;
        esac
    done

    local uuid raw secret final pending version_path existing existing_raw
    uuid="$(read_uuid)"
    final="$(secret_final_path)"
    pending="$(secret_pending_path)"
    version_path="$(secret_version_path)"

    if [[ -t 0 ]]; then
        echo "Paste the claim secret from your account dashboard." >&2
        echo "Format: ABCD-EFGH-IJKL-MNOP (hyphens and case are ignored)" >&2
        printf 'Secret: ' >&2
        IFS= read -r raw </dev/tty || true
    else
        # `cat` collects all of stdin; `$(...)` strips trailing newlines.
        # Using `read -r` here would reject a no-newline pipe (e.g.
        # `printf %s SECRET | apl-feed claim set`) even when the secret
        # arrived intact.
        raw="$(cat)"
    fi

    [[ -n "$raw" ]] || die "no input provided"

    secret="$(canonicalize_secret "$raw")"
    validate_secret "$secret" \
        || die "invalid claim secret format (expected 16 chars A-Z 0-9 after canonicalization)"

    # Read any existing final secret without dying on malformed contents:
    # `read_secret_file` calls `die` on garbage, but `claim set --force`
    # is the documented way to recover from a corrupted file, so the
    # check itself must be recoverable.
    existing=""
    if [[ -f "$final" ]] && IFS= read -r existing_raw < "$final" 2>/dev/null; then
        existing="$(canonicalize_secret "$existing_raw" 2>/dev/null || true)"
        validate_secret "$existing" 2>/dev/null || existing=""
    fi

    if [[ -f "$final" && -z "$existing" ]] && (( ! force )); then
        die "existing claim secret file is malformed or unreadable; re-run with --force to replace it"
    fi
    if [[ -n "$existing" && "$existing" != "$secret" ]] && (( ! force )); then
        die "a different claim secret is already saved on this feeder; re-run with --force to replace it"
    fi

    echo "Feeder ID: $uuid"
    if (( DRY_RUN )); then
        echo "(dry-run; would save secret + restart feeder services)"
        return 0
    fi

    # Drop any stale pending file from an interrupted prior rotation. The
    # supplied secret is the new authoritative value; any half-done
    # rotation state is moot.
    rm -f "$pending"

    if [[ -n "$existing" && "$existing" == "$secret" ]]; then
        # Same canonical value already on disk. Re-write to normalize byte
        # contents (lowercase / hyphenated raw input gets canonicalized)
        # and the file mode (0600). Don't drop the version file — the
        # local secret bytes haven't functionally changed. Don't restart
        # services either: nothing observable changed.
        write_secret_file "$final" "$secret"
        echo "Local claim secret already matches — no change."
        return 0
    fi

    write_secret_file "$final" "$secret"

    # Local secret no longer matches whatever the version file claimed.
    # Drop the version file so `claim show` / `backup` can't pair a
    # stale version with the fresh secret. The next `status` call will
    # write the server-confirmed version back.
    rm -f "$version_path"

    echo "Claim secret saved."
    # No daemon restart: neither airplanes-feed nor airplanes-mlat reads
    # the claim secret. Only this CLI does, and the next CLI invocation
    # picks up the file change immediately. The website's hash is already
    # the new value (this command is run AFTER the website mints the
    # secret), so the next outbound `status` or `rotate` from the feeder
    # authenticates fine.
    echo "Done. The feeder will use the new secret on its next contact with the website."
}


dispatch_claim() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "claim requires a subcommand"
    shift || true
    case "$sub" in
        register) claim_register "$@" ;;
        show) claim_show "$@" ;;
        rotate) claim_rotate "$@" ;;
        set) claim_set "$@" ;;
        -h|--help) usage ;;
        *) die "unknown claim subcommand: $sub" ;;
    esac
}
