#!/usr/bin/env bash

# Caps the response at 128 KiB via curl --max-filesize so a misbehaving
# server cannot fill /tmp on a disk-constrained feeder. The well-formed
# responses for the known endpoints (/status, /config/sync, /diagnostics)
# are all well under 1 KiB; the cap is loose-fitting.
post_json() {
    local path="$1"
    local body="$2"
    local response_file="$3"
    printf '%s' "$body" | curl --silent --show-error \
        --connect-timeout 10 --max-time 30 --max-filesize 131072 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data-binary @- \
        --output "$response_file" \
        --write-out '%{http_code}' \
        "$WEBSITE_URL$path"
}

# post_json_bearer <token> <path> <body> <response_file>
#
# Same shape as post_json, but adds an "Authorization: Bearer <token>"
# header. The token is written to a 0600 tempfile and passed to curl via
# --config so it never lands in argv (which /proc/<pid>/cmdline and `ps`
# expose). The tempfile is registered in TMP_FILES so common.sh's EXIT
# trap removes it when the caller exits.
#
# Caps the response at 128 KiB via curl --max-filesize so a misbehaving
# server cannot fill /tmp.
#
# Returns curl's exit code; echoes the HTTP status to stdout (or empty
# on transport failure).
post_json_bearer() {
    local token="$1"
    local path="$2"
    local body="$3"
    local response_file="$4"

    local cfg rc
    cfg="$(mktemp -t apl-feed-curlcfg.XXXXXX)" || return 1
    chmod 0600 "$cfg" || { rm -f "$cfg"; return 1; }
    # Primary cleanup is the explicit `rm -f "$cfg"` at function return.
    # TMP_FILES is only a safety net for DIRECT callers — i.e., not the
    # `status=$(post_json_bearer ...)` pattern every current caller uses,
    # because bash resets EXIT traps in command-substitution subshells
    # AND TMP_FILES mutations don't propagate out. Direct callers get
    # the EXIT-trap reap for signal-kills between mktemp and the rm
    # below; $() callers only get the explicit rm. Residual leak window
    # for $() callers is the few microseconds between mktemp and the rm
    # — accepted.
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
        rm -f "$cfg"
        return 1
    fi

    printf '%s' "$body" | curl --silent --show-error \
        --connect-timeout 10 --max-time 30 --max-filesize 131072 \
        --request POST \
        --header 'Content-Type: application/json' \
        --config "$cfg" \
        --data-binary @- \
        --output "$response_file" \
        --write-out '%{http_code}' \
        "$WEBSITE_URL$path"
    rc=$?
    rm -f "$cfg"
    return "$rc"
}

body_preview() {
    local file="$1"
    head -c 200 "$file" || true
}

status_probe_version() {
    local uuid="$1"
    local secret="$2"
    local response_file status curl_rc version body token
    response_file="$(mktemp)"
    # Body carries only the UUID; auth is in the Bearer header.
    body="$(printf '{"uuid":"%s"}' "$uuid")"
    token="$(apl_auth_token "$uuid" "$secret")"
    set +e
    status="$(post_json_bearer "$token" '/api/feeders/status' "$body" "$response_file")"
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
