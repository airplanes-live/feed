#!/usr/bin/env bash

# State reader. Defensive — if the lib is missing (mid-update transient),
# fall back to a stub that always returns 1 so the MLAT path degrades to
# systemd-only rendering. The path is BASH_SOURCE-relative so it
# resolves identically in source tree (scripts/apl-feed/.. -> scripts/lib)
# and production install (/usr/local/share/airplanes/apl-feed/.. ->
# /usr/local/share/airplanes/lib).
_status_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_state_reader="$_status_dir/../lib/state-reader.sh"
if [[ -r "$_state_reader" ]]; then
    # shellcheck source=../lib/state-reader.sh
    source "$_state_reader"
else
    airplanes_read_state() { return 1; }
fi
unset _status_dir _state_reader

STATUS_OUTPUT_JSON=0
STATUS_CHECKS_FILE=''
STATUS_FAIL_COUNT=0
STATUS_WARN_COUNT=0
STATUS_FEEDER_UUID=''
STATUS_CLAIM_REGISTERED=''
STATUS_CLAIM_VERSION=''
STATUS_OWNER_PRESENT=''
STATUS_LAST_SEEN_AT=''
STATUS_LAST_SEEN_AGE_SECONDS=''
STATUS_WEBSITE_FEED_STATE=''

status_init() {
    STATUS_CHECKS_FILE="$(new_tmp_file)"
    STATUS_FAIL_COUNT=0
    STATUS_WARN_COUNT=0
    STATUS_FEEDER_UUID=''
    STATUS_CLAIM_REGISTERED=''
    STATUS_CLAIM_VERSION=''
    STATUS_OWNER_PRESENT=''
    STATUS_LAST_SEEN_AT=''
    STATUS_LAST_SEEN_AGE_SECONDS=''
    STATUS_WEBSITE_FEED_STATE=''
}

status_line() {
    local state="$1"
    local label="$2"
    local detail="$3"
    local marker
    case "$state" in
        ok) marker='OK' ;;
        warn) marker='CHECK'; STATUS_WARN_COUNT=$(( STATUS_WARN_COUNT + 1 )) ;;
        fail) marker='FIX'; STATUS_FAIL_COUNT=$(( STATUS_FAIL_COUNT + 1 )) ;;
        *) marker='INFO' ;;
    esac

    if [[ -n "$STATUS_CHECKS_FILE" ]]; then
        jq -nc \
            --arg state "$state" \
            --arg label "$label" \
            --arg detail "$detail" \
            '{state:$state,label:$label,detail:$detail}' \
            >> "$STATUS_CHECKS_FILE"
    fi

    if (( ! STATUS_OUTPUT_JSON )); then
        printf '%-5s %-20s %s\n' "$marker" "$label" "$detail"
    fi
}

status_overall() {
    if (( STATUS_FAIL_COUNT > 0 )); then
        printf '%s' 'fail'
    elif (( STATUS_WARN_COUNT > 0 )); then
        printf '%s' 'warn'
    else
        printf '%s' 'ok'
    fi
}

status_finish() {
    local overall result_text
    overall="$(status_overall)"

    if (( STATUS_OUTPUT_JSON )); then
        jq -s \
            --arg overall "$overall" \
            --arg feeder_uuid "$STATUS_FEEDER_UUID" \
            --arg claim_registered "$STATUS_CLAIM_REGISTERED" \
            --arg claim_version "$STATUS_CLAIM_VERSION" \
            --arg owner_present "$STATUS_OWNER_PRESENT" \
            --arg last_seen_at "$STATUS_LAST_SEEN_AT" \
            --arg last_seen_age_seconds "$STATUS_LAST_SEEN_AGE_SECONDS" \
            --arg website_feed_state "$STATUS_WEBSITE_FEED_STATE" \
            '
            def nullempty: if . == "" then null else . end;
            def boolish:
              if . == "" then null
              elif . == "true" then true
              elif . == "false" then false
              else null end;
            def numberish: if . == "" then null else tonumber end;
            {
              schema_version: 1,
              overall: $overall,
              feeder_uuid: ($feeder_uuid | nullempty),
              claim: {
                registered: ($claim_registered | boolish),
                version: ($claim_version | numberish),
                owner_present: ($owner_present | boolish)
              },
              website: {
                feed_state: ($website_feed_state | nullempty),
                last_seen_at: ($last_seen_at | nullempty),
                last_seen_age_seconds: ($last_seen_age_seconds | numberish)
              },
              checks: .
            }' \
            "$STATUS_CHECKS_FILE"
        return
    fi

    case "$overall" in
        ok) result_text='feeding looks healthy' ;;
        warn) result_text='some checks need attention' ;;
        *) result_text='action needed before the feed looks healthy' ;;
    esac
    echo
    echo "Result: $result_text"
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

# _render_systemd_state <unit> <label> <active_state>
# Renders status_line output for the not-active cases (failed, inactive,
# deactivating, masked, unrecognized). Shared between mlat_status_line
# and any future state-file consumer that needs the same fall-through.
# Note: ActiveState=inactive can mean either user-stopped or masked;
# masked units report ActiveState=inactive AND is-enabled=masked, so
# we check is-enabled separately.
_render_systemd_state() {
    local unit="$1" label="$2" active_state="$3"
    local enabled
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    if [[ "$enabled" == "masked" ]]; then
        status_line fail "$label" "masked"
        return
    fi
    case "$active_state" in
        failed)
            local exit_code
            exit_code="$(systemctl show --property=ExecMainStatus --value "$unit" 2>/dev/null || true)"
            status_line fail "$label" "failed${exit_code:+ (exit $exit_code)}"
            ;;
        inactive|deactivating|'')
            status_line fail "$label" "not running"
            ;;
        *)
            status_line fail "$label" "not running ($active_state)"
            ;;
    esac
}

# mlat_status_line — replaces the old mlat_disabled_by_config + the
# matching service_status_line call in feed_status. Reads the daemon's
# published decision from /run/airplanes-mlat/state when the unit is
# active or transitioning; falls through to systemd-derived rendering
# otherwise. Special-cases failed-with-exit-64 (the strict misconfig
# fail from airplanes-mlat.sh — today only fires for an invalid
# MLAT_PRIVATE value) to surface the actionable message via the state
# file's reason key.
mlat_status_line() {
    local label="MLAT service"
    local unit="airplanes-mlat.service"
    if ! command -v systemctl >/dev/null 2>&1; then
        status_line warn "$label" "systemctl unavailable"
        return
    fi
    local active_state
    active_state="$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null || true)"
    local state_file
    state_file="$(root_path /run/airplanes-mlat/state)"

    case "$active_state" in
        active|activating|reloading)
            local decision reason
            if decision="$(airplanes_read_state "$state_file" state)" \
                && reason="$(airplanes_read_state "$state_file" reason)"; then
                _render_mlat_decision "$active_state" "$decision" "$reason"
                return
            fi
            # State file unavailable / unparseable. Daemon is alive but
            # we can't tell what it decided.
            if [[ "$active_state" == "active" ]]; then
                status_line ok "$label" "running"
            else
                status_line warn "$label" "starting up ($active_state)"
            fi
            ;;
        failed)
            local exit_code
            exit_code="$(systemctl show --property=ExecMainStatus --value "$unit" 2>/dev/null || true)"
            if [[ "$exit_code" == "64" ]]; then
                # Strict misconfig fail. State file persists across the
                # failed terminal state via RuntimeDirectoryPreserve=yes;
                # surface its reason as the actionable cause.
                local reason
                if reason="$(airplanes_read_state "$state_file" reason)" && [[ -n "$reason" ]]; then
                    _render_mlat_misconfig_reason "$reason"
                    return
                fi
                status_line fail "$label" "failed (exit 64; check feed.env MLAT config)"
                return
            fi
            _render_systemd_state "$unit" "$label" "$active_state"
            ;;
        *)
            _render_systemd_state "$unit" "$label" "$active_state"
            ;;
    esac
}

_render_mlat_decision() {
    local active_state="$1" decision="$2" reason="$3"
    local label="MLAT service"
    case "$decision" in
        enabled)
            if [[ "$active_state" == "active" ]]; then
                status_line ok "$label" "running"
            else
                status_line warn "$label" "starting up ($active_state)"
            fi
            ;;
        disabled)
            local detail
            case "$reason" in
                mlat_enabled_false) detail="disabled by config (MLAT_ENABLED=false)" ;;
                latitude_zero)      detail="disabled by config (LATITUDE=0)" ;;
                longitude_zero)     detail="disabled by config (LONGITUDE=0)" ;;
                *)                  detail="disabled by config ($reason)" ;;
            esac
            status_line ok "$label" "$detail"
            ;;
        misconfigured)
            _render_mlat_misconfig_reason "$reason"
            ;;
        *)
            # Forward-compat: an unknown decision token from a future
            # schema would surface as a warn rather than a crash.
            status_line warn "$label" "decision: $decision ($reason)"
            ;;
    esac
}

_render_mlat_misconfig_reason() {
    local reason="$1"
    local label="MLAT service"
    case "$reason" in
        mlat_private_invalid) status_line fail "$label" "MLAT_PRIVATE must be 'true' or 'false' in feed.env" ;;
        *)                    status_line fail "$label" "misconfigured ($reason)" ;;
    esac
}

# Read the daemon's published privacy posture from /run/airplanes-mlat/state.
# Daemon-state-file rule: never fall back to feed.env. If the state file
# is unavailable (daemon down, partial install) we emit no privacy line
# at all rather than re-deriving — mlat_status_line already covers the
# "daemon down" actionable signal.
mlat_privacy_status_line() {
    local state_file mlat_private
    state_file="$(root_path /run/airplanes-mlat/state)"
    if ! mlat_private="$(airplanes_read_state "$state_file" mlat_private)"; then
        return 0
    fi
    case "$mlat_private" in
        true)  status_line ok "MLAT name privacy" "private (--privacy; name hidden on map)" ;;
        false) status_line ok "MLAT name privacy" "public (name shown on map)" ;;
        '')    return 0 ;;
        *)     status_line warn "MLAT name privacy" "unknown value: $mlat_private" ;;
    esac
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

website_feed_status_line() {
    local age_text
    if [[ -z "$STATUS_LAST_SEEN_AT" ]]; then
        STATUS_WEBSITE_FEED_STATE='not_seen'
        status_line warn "Website feed" "not seen yet"
        return
    fi
    if [[ "$STATUS_LAST_SEEN_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
        age_text="$(human_duration_ago "$STATUS_LAST_SEEN_AGE_SECONDS")"
        if (( STATUS_LAST_SEEN_AGE_SECONDS <= 900 )); then
            STATUS_WEBSITE_FEED_STATE='recent'
            status_line ok "Website feed" "last data seen $age_text"
        else
            STATUS_WEBSITE_FEED_STATE='stale'
            status_line warn "Website feed" "last data seen $age_text"
        fi
    else
        STATUS_WEBSITE_FEED_STATE='unknown'
        status_line warn "Website feed" "last data time unavailable"
    fi
}

claim_registration_status_line() {
    require_jq

    local uuid final pending secret response_file body status curl_rc
    local registered version owner_present reset_until error preview
    local last_seen_present last_seen_at last_seen_age

    if ! uuid="$(read_uuid 2>/dev/null)"; then
        status_line fail "Feeder ID" "missing or invalid"
        return
    fi
    STATUS_FEEDER_UUID="$uuid"
    status_line ok "Feeder ID" "$uuid"

    final="$(secret_final_path)"
    pending="$(secret_pending_path)"
    if [[ ! -f "$final" ]]; then
        status_line warn "Claim secret" "not present; run sudo apl-feed claim register"
        STATUS_CLAIM_REGISTERED='false'
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
            STATUS_CLAIM_REGISTERED="$registered"
            if [[ "$registered" != "true" ]]; then
                status_line warn "Website claim" "not registered; run sudo apl-feed claim register"
                return
            fi
            if [[ -n "$version" ]]; then
                STATUS_CLAIM_VERSION="$version"
                STATUS_OWNER_PRESENT="$owner_present"
                write_version_file "$version"
                if [[ "$owner_present" == "true" ]]; then
                    status_line ok "Website claim" "registered and claimed (v$version)"
                else
                    status_line ok "Website claim" "registered, not yet claimed (v$version)"
                fi
                if [[ -n "$reset_until" && "$reset_until" != "null" ]]; then
                    status_line warn "Claim reset" "locked until $reset_until"
                fi
                last_seen_present="$(json_has_key "$response_file" 'last_seen_at')"
                if [[ "$last_seen_present" == "true" ]]; then
                    last_seen_at="$(parse_field_from "$response_file" '.last_seen_at')"
                    last_seen_age="$(parse_field_from "$response_file" '.last_seen_age_seconds')"
                    STATUS_LAST_SEEN_AT="$last_seen_at"
                    STATUS_LAST_SEEN_AGE_SECONDS="$last_seen_age"
                    website_feed_status_line
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
    STATUS_OUTPUT_JSON=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                STATUS_OUTPUT_JSON=1
                shift
                ;;
            *)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for status: $1" ;;
                esac
                ;;
        esac
    done

    require_jq
    status_init
    if (( ! STATUS_OUTPUT_JSON )); then
        echo "airplanes.live feed check"
        echo
    fi
    service_status_line airplanes-feed "Feed service"
    mlat_status_line
    mlat_privacy_status_line
    receiver_status_line
    airplanes_link_status_line
    claim_registration_status_line
    status_finish
}
