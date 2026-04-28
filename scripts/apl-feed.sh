#!/usr/bin/env bash
# apl-feed - feeder-side management CLI for airplanes.live.
#
# The airplanes-feed service sends data. This CLI manages local feeder
# identity, backups, and website claiming.

set -euo pipefail

ROOT='/'
SERVER_URL="${APL_FEED_SERVER_URL:-https://airplanes.live}"
MAX_RETRY_TIME="${APL_FEED_MAX_RETRY_TIME:-60}"
DRY_RUN=0
FORCE=0
TMP_FILES=()

cleanup_tmp_files() {
    if ((${#TMP_FILES[@]})); then
        rm -f "${TMP_FILES[@]}"
    fi
}
trap cleanup_tmp_files EXIT

new_tmp_file() {
    local file
    file="$(mktemp)"
    TMP_FILES+=("$file")
    printf '%s' "$file"
}

usage() {
    cat <<'USAGE'
Usage:
  apl-feed status
  apl-feed claim register
  apl-feed claim show
  apl-feed claim rotate
  apl-feed claim rotate --abort
  apl-feed backup <file>
  apl-feed restore <file>

Options:
  --force             For restore: overwrite differing local state.
  -h, --help          Show this message.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

root_path() {
    local path="$1"
    if [[ "$ROOT" == "/" ]]; then
        printf '%s' "$path"
    else
        printf '%s%s' "${ROOT%/}" "$path"
    fi
}

uuid_file_primary() {
    root_path '/usr/local/share/airplanes/airplanes-uuid'
}

uuid_file_boot() {
    root_path '/boot/airplanes-uuid'
}

secret_dir() {
    root_path '/etc/airplanes'
}

secret_final_path() {
    root_path '/etc/airplanes/claim-secret'
}

secret_pending_path() {
    root_path '/etc/airplanes/claim-secret.pending'
}

secret_version_path() {
    root_path '/etc/airplanes/claim-secret.version'
}

feed_env_path() {
    root_path '/etc/airplanes/feed.env'
}

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required"
}

canonicalize_secret() {
    printf '%s' "$1" | tr -d '[:space:]-' | tr 'a-z' 'A-Z'
}

validate_secret() {
    local secret="$1"
    [[ "${#secret}" -eq 16 ]] || return 1
    [[ "$secret" =~ ^[A-Z0-9]{16}$ ]]
}

display_secret() {
    local secret="$1"
    printf '%s-%s-%s-%s' \
        "${secret:0:4}" "${secret:4:4}" "${secret:8:4}" "${secret:12:4}"
}

read_secret_file() {
    local path="$1"
    local raw secret
    [[ -f "$path" ]] || return 1
    read -r raw < "$path" || raw=''
    secret="$(canonicalize_secret "$raw")"
    validate_secret "$secret" || die "invalid secret format at $path"
    printf '%s' "$secret"
}

write_secret_file() {
    local path="$1"
    local secret="$2"
    local dir tmp
    validate_secret "$secret" || die "refusing to write invalid secret"
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="${path}.$$"
    umask 077
    printf '%s\n' "$secret" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$path"
}

write_version_file() {
    local version="$1"
    local path tmp
    [[ -n "$version" && "$version" != "null" ]] || return 0
    [[ "$version" =~ ^[0-9]+$ ]] || return 0
    path="$(secret_version_path)"
    mkdir -p "$(dirname "$path")"
    tmp="${path}.$$"
    printf '%s\n' "$version" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$path"
}

read_version_file() {
    local path version
    path="$(secret_version_path)"
    [[ -f "$path" ]] || return 1
    read -r version < "$path" || version=''
    [[ "$version" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$version"
}

feed_env_get() {
    local key="$1"
    local path
    path="$(feed_env_path)"
    [[ -f "$path" ]] || return 1
    sed -n \
        -e "s/^${key}=\"\\(.*\\)\"[[:space:]]*$/\\1/p" \
        -e "s/^${key}='\\(.*\\)'[[:space:]]*$/\\1/p" \
        -e "s/^${key}=\\([^#[:space:]]*\\).*$/\\1/p" \
        "$path" | tail -n 1
}

read_uuid() {
    local path raw uuid
    path="$(uuid_file_primary)"
    if [[ ! -f "$path" ]]; then
        path="$(uuid_file_boot)"
    fi
    [[ -f "$path" ]] || die "no UUID file at $(uuid_file_primary) or $(uuid_file_boot)"
    raw="$(tr -d '\n\r{}' < "$path")"
    uuid="$(printf '%s' "$raw" | tr 'A-F' 'a-f')"
    if [[ ! "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        die "invalid UUID format at $path: $raw"
    fi
    printf '%s' "$uuid"
}

write_uuid() {
    local uuid="$1"
    local path dir tmp
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || die "refusing to write invalid UUID"
    path="$(uuid_file_primary)"
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="${path}.$$"
    printf '%s\n' "$uuid" > "$tmp"
    mv -f "$tmp" "$path"
}

generate_secret() (
    set +o pipefail
    LC_ALL=C tr -dc 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' </dev/urandom 2>/dev/null | head -c 16
)

parse_common_option() {
    case "${1:-}" in
        --root)
            [[ $# -ge 2 ]] || die "--root requires PATH"
            ROOT="$2"
            return 2
            ;;
        --server-url)
            [[ $# -ge 2 ]] || die "--server-url requires URL"
            SERVER_URL="$2"
            return 2
            ;;
        --max-retry-time)
            [[ $# -ge 2 ]] || die "--max-retry-time requires N"
            MAX_RETRY_TIME="$2"
            return 2
            ;;
        --dry-run)
            DRY_RUN=1
            return 1
            ;;
        --force)
            FORCE=1
            return 1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            return 0
            ;;
    esac
}

parse_field_from() {
    local file="$1"
    local expr="$2"
    jq -r "$expr | if . == null then empty else . end" < "$file" 2>/dev/null || true
}

seconds_until_iso() {
    local iso="$1"
    local target_epoch now delta
    target_epoch="$(date -d "$iso" -u +%s 2>/dev/null || true)"
    if [[ -z "$target_epoch" ]]; then
        echo 0
        return
    fi
    now="$(date -u +%s)"
    delta=$(( target_epoch - now ))
    if (( delta < 0 )); then
        echo 0
    else
        echo "$delta"
    fi
}

post_json() {
    local path="$1"
    local body="$2"
    local response_file="$3"
    printf '%s' "$body" | curl --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data-binary @- \
        --output "$response_file" \
        --write-out '%{http_code}' \
        "$SERVER_URL$path"
}

body_preview() {
    local file="$1"
    head -c 200 "$file" || true
}

sleep_or_timeout() {
    local status="$1"
    local sleep_for="$2"
    local deadline="$3"
    local now
    now="$(date +%s)"
    if (( now + sleep_for > deadline )); then
        echo "ERROR: exceeded --max-retry-time=${MAX_RETRY_TIME}s on status $status" >&2
        return 3
    fi
    sleep "$sleep_for"
}

status_probe_version() {
    local uuid="$1"
    local secret="$2"
    local response_file status curl_rc version body
    response_file="$(mktemp)"
    body="$(printf '{"uuid":"%s","current_secret":"%s"}' "$uuid" "$secret")"
    set +e
    status="$(post_json '/api/feeders/status' "$body" "$response_file")"
    curl_rc=$?
    set -e
    if [[ "$curl_rc" -ne 0 || "$status" != "200" ]]; then
        rm -f "$response_file"
        return 1
    fi
    version="$(parse_field_from "$response_file" '.version')"
    rm -f "$response_file"
    [[ -n "$version" && "$version" != "null" ]] || return 1
    printf '%s' "$version"
}

print_claim_instructions() {
    local uuid="$1"
    local secret="$2"
    echo
    echo "Your feeder claim secret is ready."
    echo "UUID:   $uuid"
    echo "Secret: $(display_secret "$secret")"
    echo
    echo "Save the secret now. You will need it to claim the feeder at:"
    echo "https://airplanes.live/feeder/claim"
}

claim_register() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for claim register: $1" ;;
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

    echo "UUID: $uuid"
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

    echo "UUID: $uuid"
    echo "Secret: $(display_secret "$secret")"
    if version="$(read_version_file 2>/dev/null)"; then
        echo "Version: $version"
    fi
}

status_line() {
    local state="$1"
    local label="$2"
    local detail="$3"
    local marker
    case "$state" in
        ok) marker='OK' ;;
        warn) marker='CHECK' ;;
        fail) marker='FIX' ;;
        *) marker='INFO' ;;
    esac
    printf '%-5s %-20s %s\n' "$marker" "$label" "$detail"
}

service_status_line() {
    local unit="$1"
    local label="$2"
    if ! command -v systemctl >/dev/null 2>&1; then
        status_line warn "$label" "systemctl unavailable"
        return
    fi
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        status_line ok "$label" "running"
        return
    fi
    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" == "masked" ]]; then
        status_line fail "$label" "masked"
        return
    fi
    status_line fail "$label" "not running"
}

mlat_disabled_by_config() {
    local user latitude longitude
    user="$(feed_env_get USER || true)"
    latitude="$(feed_env_get LATITUDE || true)"
    longitude="$(feed_env_get LONGITUDE || true)"
    [[ "$user" == "0" || "$latitude" == "0" || "$longitude" == "0" ]]
}

receiver_status_line() {
    local input input_ip input_port
    input="$(feed_env_get INPUT || true)"
    : "${input:=127.0.0.1:30005}"
    input_ip="${input%:*}"
    input_port="${input##*:}"

    if [[ -z "$input_ip" || -z "$input_port" || "$input_ip" == "$input_port" ]]; then
        status_line warn "Receiver input" "could not parse INPUT from $(feed_env_path)"
        return
    fi
    if ! command -v nc >/dev/null 2>&1; then
        status_line warn "Receiver input" "nc unavailable; expected input is $input"
        return
    fi
    if timeout 3 nc -z "$input_ip" "$input_port" >/dev/null 2>&1; then
        status_line ok "Receiver input" "connected at $input"
    else
        status_line fail "Receiver input" "no data source reachable at $input"
    fi
}

airplanes_link_status_line() {
    local output
    if command -v ss >/dev/null 2>&1; then
        output="$(ss -tn state established 2>/dev/null || true)"
    elif command -v netstat >/dev/null 2>&1; then
        output="$(netstat -t -n 2>/dev/null || true)"
    else
        status_line warn "Airplanes.live link" "ss/netstat unavailable"
        return
    fi

    if printf '%s\n' "$output" | grep -Eq ':(30004|31090)[[:space:]]'; then
        status_line ok "Airplanes.live link" "connected"
    else
        status_line warn "Airplanes.live link" "no connection found yet"
    fi
}

claim_registration_status_line() {
    require_jq

    local uuid final pending secret response_file body status curl_rc
    local registered version owner_present reset_until error preview

    if ! uuid="$(read_uuid 2>/dev/null)"; then
        status_line fail "Feeder ID" "missing or invalid"
        return
    fi
    status_line ok "Feeder ID" "$uuid"

    final="$(secret_final_path)"
    pending="$(secret_pending_path)"
    if [[ ! -f "$final" ]]; then
        status_line warn "Claim secret" "not present; run sudo apl-feed claim register"
        return
    fi
    if [[ ! -r "$final" ]]; then
        status_line warn "Claim secret" "not readable; rerun with sudo"
        return
    fi
    secret="$(read_secret_file "$final")"
    status_line ok "Claim secret" "present"
    if [[ -f "$pending" ]]; then
        status_line warn "Claim rotation" "pending rotation file exists"
    fi

    response_file="$(new_tmp_file)"
    body="$(printf '{"uuid":"%s","current_secret":"%s"}' "$uuid" "$secret")"
    set +e
    status="$(post_json '/api/feeders/status' "$body" "$response_file")"
    curl_rc=$?
    set -e
    if [[ "$curl_rc" -ne 0 ]]; then
        status_line warn "Website claim" "unreachable (curl rc=$curl_rc)"
        return
    fi

    error="$(parse_field_from "$response_file" '.error')"
    preview="$(body_preview "$response_file")"
    case "$status" in
        200)
            registered="$(parse_field_from "$response_file" '.registered')"
            version="$(parse_field_from "$response_file" '.version')"
            owner_present="$(parse_field_from "$response_file" '.owner_present')"
            reset_until="$(parse_field_from "$response_file" '.reset_until')"
            if [[ "$registered" != "true" ]]; then
                status_line warn "Website claim" "not registered; run sudo apl-feed claim register"
                return
            fi
            if [[ -n "$version" ]]; then
                write_version_file "$version"
                if [[ "$owner_present" == "true" ]]; then
                    status_line ok "Website claim" "registered and claimed (v$version)"
                else
                    status_line ok "Website claim" "registered, not yet claimed (v$version)"
                fi
                if [[ -n "$reset_until" && "$reset_until" != "null" ]]; then
                    status_line warn "Claim reset" "locked until $reset_until"
                fi
            else
                status_line warn "Website claim" "registered, but local secret did not authenticate"
            fi
            ;;
        423)
            status_line fail "Website claim" "${error:-blocked}: $preview"
            ;;
        429)
            status_line warn "Website claim" "rate-limited: $preview"
            ;;
        *)
            status_line warn "Website claim" "unexpected HTTP $status: $preview"
            ;;
    esac
}

feed_status() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for status: $1" ;;
        esac
    done

    echo "airplanes.live feed check"
    echo
    service_status_line airplanes-feed "Feed service"
    if mlat_disabled_by_config; then
        status_line ok "MLAT service" "disabled by config"
    else
        service_status_line airplanes-mlat "MLAT service"
    fi
    receiver_status_line
    airplanes_link_status_line
    claim_registration_status_line
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

config_backup() {
    local outfile=''
    local opt_rc version_read
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root|--server-url|--max-retry-time|--dry-run|--force|-h|--help)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for backup: $1" ;;
                esac
                ;;
            *)
                if [[ -n "$outfile" ]]; then
                    die "backup accepts exactly one file"
                fi
                outfile="$1"
                shift
                ;;
        esac
    done
    [[ -n "$outfile" ]] || die "backup requires a file"
    [[ ! -e "$outfile" ]] || die "$outfile already exists"
    require_jq

    local uuid secret version tmp
    uuid="$(read_uuid)"
    secret="$(read_secret_file "$(secret_final_path)")"
    version='null'
    if version_read="$(read_version_file 2>/dev/null)"; then
        version="$version_read"
    fi

    tmp="${outfile}.$$"
    umask 077
    if [[ "$version" == "null" ]]; then
        jq -n \
            --arg feeder_uuid "$uuid" \
            --arg secret "$secret" \
            '{schema_version:1, feeder_uuid:$feeder_uuid, claim:{secret:$secret, version:null}}' \
            > "$tmp"
    else
        jq -n \
            --arg feeder_uuid "$uuid" \
            --arg secret "$secret" \
            --argjson version "$version" \
            '{schema_version:1, feeder_uuid:$feeder_uuid, claim:{secret:$secret, version:$version}}' \
            > "$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$outfile"
    echo "Backed up feeder config to $outfile"
}

config_restore() {
    local infile=''
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root|--server-url|--max-retry-time|--dry-run|--force|-h|--help)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for restore: $1" ;;
                esac
                ;;
            *)
                if [[ -n "$infile" ]]; then
                    die "restore accepts exactly one file"
                fi
                infile="$1"
                shift
                ;;
        esac
    done
    [[ -n "$infile" ]] || die "restore requires a file"
    [[ -f "$infile" ]] || die "$infile does not exist"
    require_jq

    local schema uuid_raw uuid secret_raw secret version existing_uuid existing_secret
    schema="$(jq -r '.schema_version // empty' < "$infile")"
    [[ "$schema" == "1" ]] || die "unsupported config schema_version: ${schema:-<missing>}"
    uuid_raw="$(jq -r '.feeder_uuid // empty' < "$infile")"
    uuid="$(printf '%s' "$uuid_raw" | tr -d '{}[:space:]' | tr 'A-F' 'a-f')"
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || die "invalid feeder_uuid in restore file"
    secret_raw="$(jq -r '.claim.secret // empty' < "$infile")"
    secret="$(canonicalize_secret "$secret_raw")"
    validate_secret "$secret" || die "invalid claim.secret in restore file"
    version="$(jq -r '.claim.version // empty' < "$infile")"
    if [[ -n "$version" && ! "$version" =~ ^[0-9]+$ ]]; then
        die "invalid claim.version in restore file"
    fi

    if existing_uuid="$(read_uuid 2>/dev/null)"; then
        if [[ "$existing_uuid" != "$uuid" && "$FORCE" -ne 1 ]]; then
            die "local UUID differs; rerun with --force to overwrite"
        fi
    fi
    if [[ -f "$(secret_final_path)" ]]; then
        existing_secret="$(read_secret_file "$(secret_final_path)")"
        if [[ "$existing_secret" != "$secret" && "$FORCE" -ne 1 ]]; then
            die "local claim secret differs; rerun with --force to overwrite"
        fi
    fi

    write_uuid "$uuid"
    write_secret_file "$(secret_final_path)" "$secret"
    if [[ -n "$version" ]]; then
        write_version_file "$version"
    else
        rm -f "$(secret_version_path)"
    fi
    rm -f "$(secret_pending_path)"
    echo "Restored feeder config for UUID $uuid"
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
        backup)
            shift
            config_backup "$@"
            ;;
        restore)
            shift
            config_restore "$@"
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
