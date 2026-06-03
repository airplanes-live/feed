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
            -h|--help) usage_claim_register; exit 0 ;;
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
                # dead-not-failed unit.
                echo "ERROR: curl rc=$curl_rc (DNS/connect/timeout) - network unreachable" >&2
                return 75
                ;;
            *)
                # Catch-all for non-transient curl failures (rc=3 malformed
                # URL, rc=51/60 SSL cert verify, rc=58 missing client cert,
                # rc=1 unsupported protocol, ...). These are config errors
                # that retry can't fix; keep exit 2 so the unit ends in
                # `failed` and stays visible in `systemctl --failed`.
                echo "ERROR: curl rc=$curl_rc - $WEBSITE_URL/api/feeders/secret unreachable" >&2
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
                    chown_claim_state "$pending"
                    chmod 640 "$pending"
                    mv "$pending" "$final"
                fi
                # The secret is on disk; run the claim-landed side effects
                # (stop the retry timer, nudge config-sync) before any later
                # failure (write_version_file errno, echo EPIPE, etc.) could
                # abort under `set -e` and leave the retry timer firing
                # indefinitely against a now-claimed feeder.
                claim_secret_landed_side_effects
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
        case "$1" in -h|--help) usage_claim_show; exit 0 ;; esac
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
        echo "Secret version: $version"
    fi
}

claim_rotate_abort() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in -h|--help) usage_claim_rotate; exit 0 ;; esac
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
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage_claim_rotate
        exit 0
    fi
    if [[ "${1:-}" == "--abort" ]]; then
        shift
        claim_rotate_abort "$@"
        return $?
    fi

    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in -h|--help) usage_claim_rotate; exit 0 ;; esac
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
    # reset). The secret is read from stdin (TTY prompts; pipes work
    # too) so the value never lands in argv or shell history.
    #
    # No feeder-daemon restart: neither airplanes-feed nor airplanes-mlat
    # reads the claim secret — only apl-feed itself does, and the next
    # CLI invocation picks up the file change immediately. The only
    # systemd touch is stopping the image-side airplanes-claim.timer
    # post-write so the now-claimed feeder stops accumulating condition-
    # skip noise in the service journal.
    #
    # Refuses to overwrite an existing different secret unless --force is
    # passed; a no-op when the supplied secret already matches the local
    # one.
    local opt_rc force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_claim_set; exit 0 ;;
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
        echo "(dry-run; would save secret to $final)"
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
        # local secret bytes haven't functionally changed.
        write_secret_file "$final" "$secret"
        claim_secret_landed_side_effects
        echo "Local claim secret already matches — no change."
        return 0
    fi

    write_secret_file "$final" "$secret"
    # Secret is on disk; run the claim-landed side effects (stop the retry
    # timer, nudge config-sync) before any later step (rm, echo EPIPE) could
    # abort under `set -e`.
    claim_secret_landed_side_effects

    # Local secret no longer matches whatever the version file claimed.
    # Drop the version file so `claim show` / `backup` can't pair a
    # stale version with the fresh secret. The next `status` call will
    # write the server-confirmed version back.
    rm -f "$version_path"

    echo "Claim secret saved."
    # The website's hash is already the new value (this command is run
    # AFTER the website mints the secret), so the next outbound `status`
    # or `rotate` from the feeder authenticates fine. No daemon restart
    # — neither airplanes-feed nor airplanes-mlat reads this file.
    echo "Done. The feeder will use the new secret on its next contact with the website."
}


# claim_status [--json]
#
# Read-only probe of the feeder's account-claim status against
# /api/feeders/status. Distinguishes "registered with the backend" from
# "claimed by a user account" (owner_present). Writes nothing — no
# version-mirror update — so it runs unprivileged: the on-device webconfig
# invokes it as the airplanes-webconfig user (the airplanes-feed group
# grants read access to the claim secret). Emits a single result every
# time; --json produces a stable schema-v1 object, otherwise a human line.
claim_status() {
    local opt_rc json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_claim_status; exit 0 ;;
            --json) json=1; shift; continue ;;
        esac
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for claim status: $1" ;;
        esac
    done
    require_jq

    local result uuid final secret

    # Local state first — these answers need no network call.
    if ! uuid="$(read_uuid 2>/dev/null)"; then
        _claim_status_emit no_identity "$json"
        return 0
    fi
    final="$(secret_final_path)"
    if [[ ! -f "$final" ]]; then
        _claim_status_emit unregistered "$json"
        return 0
    fi
    if [[ ! -r "$final" ]]; then
        # Present but unreadable (permissions) — distinct from malformed.
        # Re-registering won't fix a perms problem, so don't suggest it.
        _claim_status_emit error "$json"
        return 2
    fi
    if ! secret="$(read_secret_file "$final" 2>/dev/null)"; then
        # Present but empty / non-canonical — a local corruption, distinct
        # from "no secret". UI action: re-register.
        _claim_status_emit secret_invalid "$json"
        return 0
    fi

    claim_status_probe "$uuid" "$secret"
    case "$CLAIM_PROBE_OUTCOME" in
        authenticated)
            case "$CLAIM_PROBE_OWNER_PRESENT" in
                true)  result=claimed ;;
                false) result=unclaimed ;;
                # An authenticated reply always carries a boolean
                # owner_present; anything else is a contract fault, not
                # an "unclaimed" feeder.
                *)     result=error ;;
            esac
            ;;
        minimal)          result=secret_mismatch ;;
        registered_false) result=server_unregistered ;;
        blocked)          result=blocked ;;
        rate_limited)     result=rate_limited ;;
        unreachable)      result=unreachable ;;
        *)                result=error ;;
    esac
    _claim_status_emit "$result" "$json"
    case "$result" in
        unreachable|error) return 2 ;;
        *) return 0 ;;
    esac
}

# _claim_status_emit <result> <json-flag>
# Renders <result> as schema-v1 JSON (json=1) or a human line. Reads the
# CLAIM_PROBE_* globals for server-derived fields; for the local-only
# results (no_identity/unregistered/secret_invalid) those are empty, which
# the JSON nullifies.
_claim_status_emit() {
    local result="$1" json="$2"
    if (( json )); then
        jq -nc \
            --arg result "$result" \
            --arg registered "${CLAIM_PROBE_REGISTERED:-}" \
            --arg owner_present "${CLAIM_PROBE_OWNER_PRESENT:-}" \
            --arg version "${CLAIM_PROBE_VERSION:-}" \
            --arg reset_until "${CLAIM_PROBE_RESET_UNTIL:-}" \
            --arg last_seen_at "${CLAIM_PROBE_LAST_SEEN_AT:-}" \
            --arg last_seen_age "${CLAIM_PROBE_LAST_SEEN_AGE:-}" \
            --arg retry_after "${CLAIM_PROBE_RETRY_AFTER:-}" \
            --arg detail "${CLAIM_PROBE_DETAIL:-}" \
            '
            def nullempty: if . == "" then null else . end;
            def boolish: if . == "true" then true elif . == "false" then false else null end;
            def numberish: if . == "" then null else (tonumber? // null) end;
            {
              schema_version: 1,
              result: $result,
              registered: ($registered | boolish),
              owner_present: ($owner_present | boolish),
              version: ($version | numberish),
              reset_until: ($reset_until | nullempty),
              last_seen_at: ($last_seen_at | nullempty),
              last_seen_age_seconds: ($last_seen_age | numberish),
              retry_after_seconds: ($retry_after | numberish),
              detail: ($detail | nullempty)
            }'
        return
    fi
    _claim_status_human "$result"
}

# _claim_status_human <result> — one or two readable lines per result.
_claim_status_human() {
    local result="$1"
    case "$result" in
        claimed)
            echo "Claimed: yes — this feeder is linked to an airplanes.live account." ;;
        unclaimed)
            echo "Claimed: no — registered, but not yet linked to an account."
            echo "Claim it at: $(claim_page_url)" ;;
        secret_mismatch)
            echo "The claim secret on this feeder did not authenticate with airplanes.live."
            echo "Re-register: sudo apl-feed claim register" ;;
        server_unregistered)
            echo "airplanes.live has no record of this feeder's claim secret."
            echo "Register: sudo apl-feed claim register" ;;
        unregistered)
            echo "No claim secret on this feeder yet."
            echo "Register: sudo apl-feed claim register" ;;
        secret_invalid)
            echo "The local claim secret is missing or malformed."
            echo "Re-register: sudo apl-feed claim register" ;;
        no_identity)
            echo "This device has no Feeder ID yet." ;;
        blocked)
            echo "This feeder is blocked by an administrator." ;;
        rate_limited)
            echo "airplanes.live is rate-limiting status checks; try again shortly." ;;
        unreachable)
            echo "Could not reach airplanes.live to check claim status." ;;
        *)
            echo "Claim status unavailable." ;;
    esac
}

usage_claim_status() {
    cat <<'USAGE'
Usage: apl-feed claim status [--json]

Reports whether this feeder is registered with airplanes.live and whether a
user account has claimed it. Contacts the website read-only and writes
nothing. --json emits a machine-readable object instead of the summary.
USAGE
}

usage_claim() {
    cat <<'USAGE'
Usage: apl-feed claim <subcommand> [options]

Subcommands:
  register    Generate and register the claim secret with airplanes.live
  show        Print the local claim secret and the claim page URL
  status      Show registration + account-claim status (--json available)
  rotate      Rotate the claim secret (--abort cancels a pending rotation)
  set         Save a claim secret minted by the website (reads stdin)

Run 'apl-feed claim <subcommand> --help' for details.
USAGE
}

usage_claim_register() {
    cat <<'USAGE'
Usage: apl-feed claim register

Generates a claim secret (when none exists yet) and registers it with
airplanes.live, then prints the secret and the claim page URL. Safe to
re-run: an already-registered feeder re-confirms its existing secret.
USAGE
}

usage_claim_show() {
    cat <<'USAGE'
Usage: apl-feed claim show

Prints the locally stored claim secret, its version (when known), and the
claim page URL. Does not contact the website.
USAGE
}

usage_claim_rotate() {
    cat <<'USAGE'
Usage:
  apl-feed claim rotate
  apl-feed claim rotate --abort

Rotates the claim secret with airplanes.live, replacing the local secret
on success. --abort cancels a pending (interrupted) rotation, keeping the
current secret as long as the server still accepts it.
USAGE
}

usage_claim_set() {
    cat <<'USAGE'
Usage: apl-feed claim set [--force]

Reads a claim secret from stdin (or prompts on a TTY) and saves it
locally. The feeder uses the new secret on its next contact with the
website — no daemon restart, since neither airplanes-feed nor
airplanes-mlat consumes the claim secret. --force overwrites a different
secret already saved on this feeder.
USAGE
}

dispatch_claim() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || usage_error usage_claim
    if [[ "$sub" == "-h" || "$sub" == "--help" ]]; then
        usage_claim
        return 0
    fi
    shift || true
    case "$sub" in
        register) claim_register "$@" ;;
        show) claim_show "$@" ;;
        status) claim_status "$@" ;;
        rotate) claim_rotate "$@" ;;
        set) claim_set "$@" ;;
        *) usage_error usage_claim "unknown claim subcommand: $sub" ;;
    esac
}
