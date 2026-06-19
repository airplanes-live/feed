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

# post_gzip_bearer <token> <path> <gzip_file> <response_file>
#
# Like post_json_bearer, but uploads a PRE-gzipped request body read from a file
# and sets Content-Encoding: gzip so the server gunzips it. Compression and the
# size check stay in the caller (airplanes-stats.sh needs the compressed size
# for its outline-drop fallback), so this helper owns only transport. The bearer
# goes into a 0600 curl --config file (not argv), same as post_json_bearer.
# --max-time is larger than the JSON helpers' because the raw-snapshot upload is
# bigger than the sub-KiB control bodies. Response capped at 128 KiB.
#
# Returns curl's exit code; echoes the HTTP status to stdout (empty on transport
# failure).
post_gzip_bearer() {
    local token="$1"
    local path="$2"
    local gzip_file="$3"
    local response_file="$4"

    local cfg rc
    cfg="$(mktemp -t apl-feed-curlcfg.XXXXXX)" || return 1
    chmod 0600 "$cfg" || { rm -f "$cfg"; return 1; }
    # Same cleanup contract as post_json_bearer: explicit rm at return, with
    # TMP_FILES as the EXIT-trap safety net for direct (non-$()) callers.
    TMP_FILES+=("$cfg")
    local escaped="${token//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    if ! printf 'header = "Authorization: Bearer %s"\n' "$escaped" > "$cfg"; then
        rm -f "$cfg"
        return 1
    fi

    curl --silent --show-error \
        --connect-timeout 10 --max-time 60 --max-filesize 131072 \
        --request POST \
        --header 'Content-Type: application/json' \
        --header 'Content-Encoding: gzip' \
        --config "$cfg" \
        --data-binary @"$gzip_file" \
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

# claim_status_probe <uuid> <secret>
#
# Single source of truth for probing POST /api/feeders/status and parsing
# its response. Both `apl-feed status` (claim_registration_status_line)
# and `apl-feed claim status` consume the CLAIM_PROBE_* output globals, so
# the two never drift on the wire shape. Builds a Bearer token from the
# uuid + secret, POSTs, and classifies the reply. Always returns 0 — the
# outcome travels in CLAIM_PROBE_OUTCOME so callers under `set -e` are not
# aborted by a non-2xx reply. Does NOT touch the on-disk version mirror;
# a caller that wants that side effect calls write_version_file itself.
#
# Outputs (reset on every call; empty when not applicable):
#   CLAIM_PROBE_OUTCOME   unreachable|registered_false|authenticated|minimal|blocked|rate_limited|http_error
#   CLAIM_PROBE_HTTP      numeric HTTP status ("" on transport failure)
#   CLAIM_PROBE_REGISTERED   raw .registered ("true"/"false"/"")
#   CLAIM_PROBE_OWNER_PRESENT raw .owner_present ("true"/"false"/"")
#   CLAIM_PROBE_VERSION   raw .version
#   CLAIM_PROBE_RESET_UNTIL  raw .reset_until
#   CLAIM_PROBE_CLAIMABLE  raw .claimable ("true"/"false"; "" when the
#                          server predates the field — render as today)
#   CLAIM_PROBE_CLAIM_UNAVAILABLE_REASON  raw .claim_unavailable_reason
#                          (not_seen_feeding|reset_locked|claim_blocked;
#                          "" when null/absent)
#   CLAIM_PROBE_LAST_SEEN_PRESENT  "true" when the last_seen_at key exists
#                                  (distinct from a present-but-null value)
#   CLAIM_PROBE_LAST_SEEN_AT  raw .last_seen_at ("" when null or key absent)
#   CLAIM_PROBE_LAST_SEEN_AGE raw .last_seen_age_seconds
#   CLAIM_PROBE_RETRY_AFTER   raw .retry_after (429 only)
#   CLAIM_PROBE_ERROR     raw .error (non-200 diagnostics)
#   CLAIM_PROBE_DETAIL    short body preview (diagnostics)
#
# CLAIM_PROBE_* are consumed by sibling apl-feed modules (claim.sh,
# status.sh), not within this file (SC2034 is disabled repo-wide).
claim_status_probe() {
    local uuid="$1" secret="$2"
    CLAIM_PROBE_OUTCOME=''
    CLAIM_PROBE_HTTP=''
    CLAIM_PROBE_REGISTERED=''
    CLAIM_PROBE_OWNER_PRESENT=''
    CLAIM_PROBE_VERSION=''
    CLAIM_PROBE_RESET_UNTIL=''
    CLAIM_PROBE_CLAIMABLE=''
    CLAIM_PROBE_CLAIM_UNAVAILABLE_REASON=''
    CLAIM_PROBE_LAST_SEEN_PRESENT=''
    CLAIM_PROBE_LAST_SEEN_AT=''
    CLAIM_PROBE_LAST_SEEN_AGE=''
    CLAIM_PROBE_RETRY_AFTER=''
    CLAIM_PROBE_ERROR=''
    CLAIM_PROBE_DETAIL=''

    local response_file status curl_rc body token
    response_file="$(mktemp)"
    # Body carries only the UUID; auth is in the Bearer header.
    body="$(printf '{"uuid":"%s"}' "$uuid")"
    # Honor the always-returns-0 contract: bad uuid/secret inputs would
    # otherwise abort under set -e via the failing command substitution.
    if ! token="$(apl_auth_token "$uuid" "$secret")"; then
        CLAIM_PROBE_OUTCOME='error'
        CLAIM_PROBE_DETAIL='invalid auth token inputs'
        rm -f "$response_file"
        return 0
    fi
    set +e
    status="$(post_json_bearer "$token" '/api/feeders/status' "$body" "$response_file")"
    curl_rc=$?
    set -e
    CLAIM_PROBE_HTTP="$status"
    if [[ "$curl_rc" -ne 0 ]]; then
        CLAIM_PROBE_OUTCOME='unreachable'
        CLAIM_PROBE_DETAIL="curl rc=$curl_rc"
        rm -f "$response_file"
        return 0
    fi
    CLAIM_PROBE_ERROR="$(parse_field_from "$response_file" '.error')"
    CLAIM_PROBE_DETAIL="$(body_preview "$response_file")"
    case "$status" in
        200)
            # A 200 must carry a JSON object; an HTML error page or a
            # truncated body is a contract fault, not "unregistered".
            if ! jq -e . "$response_file" >/dev/null 2>&1; then
                CLAIM_PROBE_OUTCOME='http_error'
                rm -f "$response_file"
                return 0
            fi
            CLAIM_PROBE_REGISTERED="$(parse_field_from "$response_file" '.registered')"
            case "$CLAIM_PROBE_REGISTERED" in
                true) ;;
                false)
                    CLAIM_PROBE_OUTCOME='registered_false'
                    rm -f "$response_file"
                    return 0
                    ;;
                *)
                    # `registered` missing or non-boolean on a valid-JSON
                    # 200: a contract fault, surfaced as an error rather
                    # than a (false) claim state.
                    CLAIM_PROBE_OUTCOME='http_error'
                    rm -f "$response_file"
                    return 0
                    ;;
            esac
            CLAIM_PROBE_VERSION="$(parse_field_from "$response_file" '.version')"
            CLAIM_PROBE_OWNER_PRESENT="$(parse_field_from "$response_file" '.owner_present')"
            CLAIM_PROBE_RESET_UNTIL="$(parse_field_from "$response_file" '.reset_until')"
            # The authenticated reply carries a version; a minimal reply
            # (wrong/superseded local secret) is registered:true with no
            # version — surfaced distinctly so the UI says "re-register"
            # rather than "claimed".
            if [[ -n "$CLAIM_PROBE_VERSION" ]]; then
                CLAIM_PROBE_OUTCOME='authenticated'
                # Absent and null both collapse to "" = unknown (older
                # server) — callers then render exactly as before the
                # field existed.
                CLAIM_PROBE_CLAIMABLE="$(parse_field_from "$response_file" '.claimable')"
                CLAIM_PROBE_CLAIM_UNAVAILABLE_REASON="$(parse_field_from "$response_file" '.claim_unavailable_reason')"
                CLAIM_PROBE_LAST_SEEN_PRESENT="$(json_has_key "$response_file" 'last_seen_at')"
                if [[ "$CLAIM_PROBE_LAST_SEEN_PRESENT" == "true" ]]; then
                    CLAIM_PROBE_LAST_SEEN_AT="$(parse_field_from "$response_file" '.last_seen_at')"
                    CLAIM_PROBE_LAST_SEEN_AGE="$(parse_field_from "$response_file" '.last_seen_age_seconds')"
                fi
            else
                CLAIM_PROBE_OUTCOME='minimal'
            fi
            ;;
        423)
            CLAIM_PROBE_OUTCOME='blocked'
            ;;
        429)
            CLAIM_PROBE_OUTCOME='rate_limited'
            CLAIM_PROBE_RETRY_AFTER="$(parse_field_from "$response_file" '.retry_after')"
            ;;
        *)
            CLAIM_PROBE_OUTCOME='http_error'
            ;;
    esac
    rm -f "$response_file"
    return 0
}
