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
