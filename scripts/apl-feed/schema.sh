#!/usr/bin/env bash
# `apl-feed schema` — emits the canonical feed.env schema used by webconfig
# to filter GET responses and pre-populate forms.
#
# Output (stdout, single line of JSON):
#   {"version":1,"writable_keys":[...],"readable_keys":[...]}
#
# Consumers: image/webconfig on boot (caches), then via SIGHUP after an
# update. Stable JSON shape — the version field is for future-incompat
# evolution.

usage_schema() {
    cat <<'USAGE'
Usage: apl-feed schema

Prints the canonical feed.env schema (writable and readable keys) as a
single line of JSON. Used by webconfig to filter responses and build forms.
USAGE
}

apl_feed_schema_cli() {
    # Help must work without jq installed — handle it before require_jq.
    local _arg
    for _arg in "$@"; do
        case "$_arg" in -h|--help) usage_schema; exit 0 ;; esac
    done

    require_jq

    while (( $# > 0 )); do
        local opt_rc
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift; continue ;;
            2) shift 2; continue ;;
        esac
        case "$1" in
            --json) shift ;;
            -h|--help) usage_schema; exit 0 ;;
            *) die "unknown flag for schema: $1" ;;
        esac
    done

    local writable readable
    writable="$(printf '%s\n' "${APL_FEED_WRITABLE_KEYS[@]}" | jq -R . | jq -sc .)"
    readable="$(printf '%s\n' "${APL_FEED_READABLE_KEYS[@]}" | jq -R . | jq -sc .)"
    jq -nc \
        --argjson w "$writable" \
        --argjson r "$readable" \
        '{version:1, writable_keys:$w, readable_keys:$r}'
}
