#!/usr/bin/env bash

ROOT='/'
# shellcheck disable=SC2034  # SERVER_URL/MAX_RETRY_TIME/DRY_RUN/FORCE are read by sibling modules sourced from apl-feed.sh
SERVER_URL="${APL_FEED_SERVER_URL:-https://airplanes.live}"
# shellcheck disable=SC2034
MAX_RETRY_TIME="${APL_FEED_MAX_RETRY_TIME:-60}"
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034
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
  apl-feed status [--json]
  apl-feed claim register
  apl-feed claim show
  apl-feed claim rotate
  apl-feed claim rotate --abort
  apl-feed backup <file>
  apl-feed restore <file>
  apl-feed restore --check <file>

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
    if [[ -f "$(root_path '/boot/airplanes-config.txt')" && -x "$(root_path '/usr/bin/airplanes-feeder')" ]]; then
        root_path '/boot/airplanes-config.txt'
        return
    fi
    root_path '/etc/airplanes/feed.env'
}

feed_env_paths() {
    if [[ -f "$(root_path '/boot/airplanes-config.txt')" && -x "$(root_path '/usr/bin/airplanes-feeder')" ]]; then
        root_path '/boot/airplanes-config.txt'
        printf '\n'
        root_path '/boot/airplanes-env'
        printf '\n'
        return
    fi
    feed_env_path
    printf '\n'
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
    local path output
    output="$(
        while IFS= read -r path; do
            [[ -f "$path" ]] || continue
            sed -n \
                -e "s/^${key}=\"\\(.*\\)\"[[:space:]]*$/\\1/p" \
                -e "s/^${key}='\\(.*\\)'[[:space:]]*$/\\1/p" \
                -e "s/^${key}=\\([^#[:space:]]*\\).*$/\\1/p" \
                "$path"
        done < <(feed_env_paths)
    )"
    [[ -n "$output" ]] || return 1
    printf '%s\n' "$output" | tail -n 1
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
            # shellcheck disable=SC2034  # consumed by http.sh/claim.sh after parse
            SERVER_URL="$2"
            return 2
            ;;
        --max-retry-time)
            [[ $# -ge 2 ]] || die "--max-retry-time requires N"
            # shellcheck disable=SC2034  # consumed by claim.sh after parse
            MAX_RETRY_TIME="$2"
            return 2
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

json_has_key() {
    local file="$1"
    local key="$2"
    jq -r --arg key "$key" 'has($key)' < "$file" 2>/dev/null || true
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

human_duration_ago() {
    local seconds="$1"
    local days hours minutes
    [[ "$seconds" =~ ^[0-9]+$ ]] || { printf '%s' "$seconds"; return; }
    if (( seconds < 60 )); then
        printf '%ss ago' "$seconds"
    elif (( seconds < 3600 )); then
        printf '%sm ago' $(( seconds / 60 ))
    elif (( seconds < 86400 )); then
        hours=$(( seconds / 3600 ))
        minutes=$(( (seconds % 3600) / 60 ))
        if (( minutes > 0 )); then
            printf '%sh %sm ago' "$hours" "$minutes"
        else
            printf '%sh ago' "$hours"
        fi
    else
        days=$(( seconds / 86400 ))
        hours=$(( (seconds % 86400) / 3600 ))
        if (( hours > 0 )); then
            printf '%sd %sh ago' "$days" "$hours"
        else
            printf '%sd ago' "$days"
        fi
    fi
}
