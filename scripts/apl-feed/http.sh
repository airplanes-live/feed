#!/usr/bin/env bash

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

# post_json_bearer <token> <path> <body> <response_file>
#
# Same shape as post_json, but adds an "Authorization: Bearer <token>"
# header. The token is written to a 0600 tempfile and passed to curl via
# --config so it never lands in argv (which /proc/<pid>/cmdline and `ps`
# expose). The tempfile is registered in TMP_FILES so common.sh's EXIT
# trap removes it when the caller exits.
#
# Returns curl's exit code; echoes the HTTP status to stdout (or empty
# on transport failure).
post_json_bearer() {
    local token="$1"
    local path="$2"
    local body="$3"
    local response_file="$4"

    local cfg
    cfg="$(mktemp -t apl-feed-curlcfg.XXXXXX)" || return 1
    chmod 0600 "$cfg" || { rm -f "$cfg"; return 1; }
    TMP_FILES+=("$cfg")
    # `curl --config` reads `key = "value"` lines; backslash-escape any
    # embedded backslashes or double quotes in the token before substitution.
    local escaped="${token//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    # Fail loud (not unauthenticated) if the config write fails — curl with
    # an empty --config would still issue the POST without the Authorization
    # header, which the backend would reject as `malformed_authorization`
    # rather than the actual local I/O error.
    if ! printf 'header = "Authorization: Bearer %s"\n' "$escaped" > "$cfg"; then
        return 1
    fi

    printf '%s' "$body" | curl --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        --request POST \
        --header 'Content-Type: application/json' \
        --config "$cfg" \
        --data-binary @- \
        --output "$response_file" \
        --write-out '%{http_code}' \
        "$SERVER_URL$path"
}

body_preview() {
    local file="$1"
    head -c 200 "$file" || true
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
