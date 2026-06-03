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
STATUS_RECEIVER_INPUT_IP=''
STATUS_RECEIVER_INPUT_PORT=''
STATUS_RECEIVER_INPUT_STATE=''
STATUS_RECEIVER_ACTIVITY_STATE=''
STATUS_RECEIVER_ACTIVITY_BYTES=''
STATUS_CLAIM_REGISTERED=''
STATUS_CLAIM_VERSION=''
STATUS_OWNER_PRESENT=''
STATUS_LAST_SEEN_AT=''
STATUS_LAST_SEEN_AGE_SECONDS=''
STATUS_SERVER_RECEPTION_STATE=''
STATUS_DIAGNOSTICS_TOGGLE=''
STATUS_DIAGNOSTICS_LAST_PUSH_AGE_SECONDS=''
STATUS_CONFIG_SYNC_TOGGLE=''
STATUS_CONFIG_SYNC_LAST_SYNC_AGE_SECONDS=''

status_init() {
    STATUS_CHECKS_FILE="$(new_tmp_file)"
    STATUS_FAIL_COUNT=0
    STATUS_WARN_COUNT=0
    STATUS_FEEDER_UUID=''
    STATUS_RECEIVER_INPUT_IP=''
    STATUS_RECEIVER_INPUT_PORT=''
    STATUS_RECEIVER_INPUT_STATE=''
    STATUS_RECEIVER_ACTIVITY_STATE=''
    STATUS_RECEIVER_ACTIVITY_BYTES=''
    STATUS_CLAIM_REGISTERED=''
    STATUS_CLAIM_VERSION=''
    STATUS_OWNER_PRESENT=''
    STATUS_LAST_SEEN_AT=''
    STATUS_LAST_SEEN_AGE_SECONDS=''
    STATUS_SERVER_RECEPTION_STATE=''
    STATUS_DIAGNOSTICS_TOGGLE=''
    STATUS_DIAGNOSTICS_LAST_PUSH_AGE_SECONDS=''
    STATUS_CONFIG_SYNC_TOGGLE=''
    STATUS_CONFIG_SYNC_LAST_SYNC_AGE_SECONDS=''
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
        # `label` is a jq 1.6 keyword (used for label/break flow), so using
        # it as a jq variable name fails to compile on Pi OS bullseye and
        # bookworm. jq 1.7+ accepts it. The output JSON key is still
        # `label`; only the jq variable is renamed.
        jq -nc \
            --arg state "$state" \
            --arg label_text "$label" \
            --arg detail "$detail" \
            '{state:$state,label:$label_text,detail:$detail}' \
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
            --arg receiver_input_state "$STATUS_RECEIVER_INPUT_STATE" \
            --arg receiver_activity_state "$STATUS_RECEIVER_ACTIVITY_STATE" \
            --arg receiver_activity_bytes "$STATUS_RECEIVER_ACTIVITY_BYTES" \
            --arg claim_registered "$STATUS_CLAIM_REGISTERED" \
            --arg claim_version "$STATUS_CLAIM_VERSION" \
            --arg owner_present "$STATUS_OWNER_PRESENT" \
            --arg last_seen_at "$STATUS_LAST_SEEN_AT" \
            --arg last_seen_age_seconds "$STATUS_LAST_SEEN_AGE_SECONDS" \
            --arg reception_state "$STATUS_SERVER_RECEPTION_STATE" \
            --arg diagnostics_toggle "$STATUS_DIAGNOSTICS_TOGGLE" \
            --arg diagnostics_last_push_age "$STATUS_DIAGNOSTICS_LAST_PUSH_AGE_SECONDS" \
            --arg config_sync_toggle "$STATUS_CONFIG_SYNC_TOGGLE" \
            --arg config_sync_last_sync_age "$STATUS_CONFIG_SYNC_LAST_SYNC_AGE_SECONDS" \
            '
            def nullempty: if . == "" then null else . end;
            def boolish:
              if . == "" then null
              elif . == "true" then true
              elif . == "false" then false
              else null end;
            def numberish: if . == "" then null else tonumber end;
            {
              schema_version: 3,
              overall: $overall,
              feeder_uuid: ($feeder_uuid | nullempty),
              receiver: {
                input_state: ($receiver_input_state | nullempty),
                activity_state: ($receiver_activity_state | nullempty),
                activity_bytes: ($receiver_activity_bytes | numberish)
              },
              claim: {
                registered: ($claim_registered | boolish),
                version: ($claim_version | numberish),
                owner_present: ($owner_present | boolish)
              },
              website: {
                reception_state: ($reception_state | nullempty),
                last_seen_at: ($last_seen_at | nullempty),
                last_seen_age_seconds: ($last_seen_age_seconds | numberish)
              },
              diagnostics: {
                report_status: ($diagnostics_toggle | nullempty),
                last_push_age_seconds: ($diagnostics_last_push_age | numberish)
              },
              config_sync: {
                remote_config: ($config_sync_toggle | nullempty),
                last_sync_age_seconds: ($config_sync_last_sync_age | numberish)
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

# _mlat_privacy_suffix — read the daemon's published privacy posture
# from /run/airplanes-mlat/state and render the inline suffix appended
# to a "running" MLAT line. Empty string when the state file is
# unreadable, the value is missing, or the value is unrecognised (an
# unknown value is surfaced separately via _mlat_privacy_unknown_value
# so forward-schema visibility isn't lost when the suffix is folded in).
_mlat_privacy_suffix() {
    local state_file mlat_private
    state_file="$(root_path /run/airplanes-mlat/state)"
    if ! mlat_private="$(airplanes_read_state "$state_file" mlat_private 2>/dev/null)"; then
        return 0
    fi
    case "$mlat_private" in
        true)  printf ' (name: private)' ;;
        false) printf ' (name: public)' ;;
    esac
}

# _mlat_privacy_unknown_value — if the state file's mlat_private key
# carries a token we don't recognise, return it for the caller to
# surface as a warn line. Empty when absent or recognised.
_mlat_privacy_unknown_value() {
    local state_file mlat_private
    state_file="$(root_path /run/airplanes-mlat/state)"
    if ! mlat_private="$(airplanes_read_state "$state_file" mlat_private 2>/dev/null)"; then
        return 0
    fi
    case "$mlat_private" in
        ''|true|false) return 0 ;;
        *) printf '%s' "$mlat_private" ;;
    esac
}

_render_mlat_decision() {
    local active_state="$1" decision="$2" reason="$3"
    local label="MLAT service"
    case "$decision" in
        enabled)
            if [[ "$active_state" == "active" ]]; then
                status_line ok "$label" "running$(_mlat_privacy_suffix)"
                local unknown
                unknown="$(_mlat_privacy_unknown_value)"
                if [[ -n "$unknown" ]]; then
                    status_line warn "MLAT name privacy" "unknown value: $unknown"
                fi
            else
                status_line warn "$label" "starting up ($active_state)"
            fi
            ;;
        disabled)
            local detail
            case "$reason" in
                mlat_enabled_false) detail="disabled by config (MLAT_ENABLED=false)" ;;
                geo_not_configured) detail="disabled by config (location not set)" ;;
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
        altitude_empty)       status_line fail "$label" "ALTITUDE is empty (set the antenna altitude, e.g. ALTITUDE=120m)" ;;
        *)                    status_line fail "$label" "misconfigured ($reason)" ;;
    esac
}

receiver_status_line() {
    local input input_ip input_port
    input="$(feed_env_get INPUT || true)"
    : "${input:=127.0.0.1:30005}"
    input_ip="${input%:*}"
    input_port="${input##*:}"

    STATUS_RECEIVER_INPUT_IP="$input_ip"
    STATUS_RECEIVER_INPUT_PORT="$input_port"

    if [[ -z "$input_ip" || -z "$input_port" || "$input_ip" == "$input_port" ]]; then
        STATUS_RECEIVER_INPUT_STATE='warn'
        status_line warn "Receiver input" "could not parse INPUT from $(feed_env_path)"
        return
    fi
    if ! command -v nc >/dev/null 2>&1; then
        STATUS_RECEIVER_INPUT_STATE='warn'
        status_line warn "Receiver input" "nc unavailable; expected input is $input"
        return
    fi
    if timeout 3 nc -z "$input_ip" "$input_port" >/dev/null 2>&1; then
        STATUS_RECEIVER_INPUT_STATE='ok'
        status_line ok "Receiver input" "connected at $input"
    else
        STATUS_RECEIVER_INPUT_STATE='fail'
        status_line fail "Receiver input" "no data source reachable at $input"
    fi
}

# receiver_activity_status_line — protocol-agnostic byte sniff of the
# INPUT socket. Answers "is the source emitting data right now?", not
# "how many aircraft" (Beast is binary; INPUT is consumed as beast_in
# in airplanes-feed.sh, so a BaseStation MSG parser would silently warn
# on the default-feeder happy path).
#
# `head -c N` early-exits as soon as any bytes arrive (sub-second on a
# healthy feeder) by closing the pipe and SIGPIPE'ing nc; `timeout`
# caps the no-data case. Both produce a non-zero pipeline by design,
# so the helper is wrapped in `set +o pipefail` and the rc is
# deliberately not checked — $bytes is the only signal.
receiver_activity_status_line() {
    local label="Receiver activity"
    local timeout_secs="${RECEIVER_ACTIVITY_TIMEOUT:-2}"
    local sample_bytes="${RECEIVER_ACTIVITY_SAMPLE_BYTES:-256}"

    if [[ "$STATUS_RECEIVER_INPUT_STATE" != "ok" ]]; then
        # Anything other than a clean reachable input on the line above
        # has already been reported (fail = unreachable, warn = malformed
        # INPUT or nc unavailable). An activity probe against unresolved
        # or unreachable input only adds a misleading second line.
        return
    fi
    if [[ -z "${STATUS_RECEIVER_INPUT_IP:-}" || -z "${STATUS_RECEIVER_INPUT_PORT:-}" ]]; then
        STATUS_RECEIVER_ACTIVITY_STATE='warn'
        status_line warn "$label" "INPUT not resolved"
        return
    fi
    if ! command -v nc >/dev/null 2>&1; then
        STATUS_RECEIVER_ACTIVITY_STATE='warn'
        status_line warn "$label" "nc unavailable"
        return
    fi

    local bytes pipefail_was_set=0
    if [[ -o pipefail ]]; then pipefail_was_set=1; fi
    set +o pipefail
    bytes="$(timeout "$timeout_secs" nc "$STATUS_RECEIVER_INPUT_IP" "$STATUS_RECEIVER_INPUT_PORT" 2>/dev/null \
        | head -c "$sample_bytes" \
        | wc -c \
        | tr -d ' ')"
    if (( pipefail_was_set )); then set -o pipefail; fi
    : "${bytes:=0}"

    STATUS_RECEIVER_ACTIVITY_BYTES="$bytes"
    if (( bytes > 0 )); then
        STATUS_RECEIVER_ACTIVITY_STATE='ok'
        status_line ok "$label" "data flowing (${bytes}b in ${timeout_secs}s sample)"
    else
        STATUS_RECEIVER_ACTIVITY_STATE='warn'
        status_line warn "$label" "no data (last ${timeout_secs}s)"
    fi
}

# adsb_uplink_status_line — checks for an established outbound TCP
# socket to the ADS-B aggregator ports. TARGET in airplanes-feed.sh
# binds to feed.airplanes.live:30004 with failover to
# feed2.airplanes.live:64004; either established peer socket means the
# feed binary has wired its uplink. MLAT (:31090) is intentionally
# excluded — the MLAT service line already speaks for that path; a
# MLAT-only connection used to flip this check to ok and hid an
# ADS-B-down state.
#
# Matches the PEER address:port (last column of `ss -tn`) so a local
# listener on :30004 / :64004 (a different process binding the same port
# locally) can't false-positive. `ss -tn state established` already
# filters by state; the netstat fallback enforces ESTABLISHED itself.
adsb_uplink_status_line() {
    local label="ADS-B uplink"
    local peer_ports
    if command -v ss >/dev/null 2>&1; then
        # ss output: State Recv-Q Send-Q Local-Address:Port Peer-Address:Port
        # The peer address:port is the LAST whitespace-separated field.
        peer_ports="$(ss -tn state established 2>/dev/null | awk 'NR>1 {print $NF}' || true)"
    elif command -v netstat >/dev/null 2>&1; then
        # netstat -t -n output (Linux): Proto Recv-Q Send-Q Local-Address Foreign-Address State
        # Filter to ESTABLISHED, then take the foreign address:port (5th field).
        peer_ports="$(netstat -t -n 2>/dev/null | awk '$NF=="ESTABLISHED" {print $5}' || true)"
    else
        status_line warn "$label" "ss/netstat unavailable"
        return
    fi

    if printf '%s\n' "$peer_ports" | grep -Eq ':(30004|64004)$'; then
        status_line ok "$label" "connected"
    else
        status_line warn "$label" "no connection found yet"
    fi
}

# server_reception_status_line — renders the server-side data-reception
# signal from STATUS_LAST_SEEN_AT / STATUS_LAST_SEEN_AGE_SECONDS, which
# claim_registration_status_line populates from POST /api/feeders/status.
#
# Tier thresholds reflect the aether → Redis snapshot → feeder_sync cron
# pipeline that powers Feeder.last_seen on the website side
# (FEEDER_SYNC_REDIS_URL cron runs every 5 min — see the website's
# project settings). Healthy feeders therefore see last_seen_age in the
# 0–~5 min range; the ok ceiling absorbs one cron interval plus slack:
#
#   ≤ 480 s   (8 min)  → ok    currently receiving
#   480-1200 s (≤20m)  → warn  lagging
#   > 1200 s            → fail  not receiving
server_reception_status_line() {
    local label="Server reception"
    local age_text
    if [[ -z "$STATUS_LAST_SEEN_AT" ]]; then
        STATUS_SERVER_RECEPTION_STATE='not_seen'
        status_line warn "$label" "not seen yet (server confirms reception ~5–8 min after first connect)"
        return
    fi
    if [[ "$STATUS_LAST_SEEN_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
        age_text="$(human_duration_ago "$STATUS_LAST_SEEN_AGE_SECONDS")"
        if (( STATUS_LAST_SEEN_AGE_SECONDS <= 480 )); then
            STATUS_SERVER_RECEPTION_STATE='recent'
            status_line ok "$label" "currently receiving (last data seen $age_text)"
        elif (( STATUS_LAST_SEEN_AGE_SECONDS <= 1200 )); then
            STATUS_SERVER_RECEPTION_STATE='lagging'
            status_line warn "$label" "lagging (last data seen $age_text)"
        else
            STATUS_SERVER_RECEPTION_STATE='stale'
            status_line fail "$label" "not receiving (last data seen $age_text)"
        fi
    else
        STATUS_SERVER_RECEPTION_STATE='unknown'
        status_line warn "$label" "last data time unavailable"
    fi
}

claim_registration_status_line() {
    require_jq

    local uuid final pending secret

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

    # Probe POST /api/feeders/status via the shared helper (http.sh) so
    # this renderer and `apl-feed claim status` never drift on the wire
    # shape. The helper carries its outcome in CLAIM_PROBE_*; we render
    # from those and own the version-mirror write here.
    claim_status_probe "$uuid" "$secret"
    case "$CLAIM_PROBE_OUTCOME" in
        unreachable)
            status_line warn "Website claim" "unreachable ($CLAIM_PROBE_DETAIL)"
            ;;
        registered_false)
            STATUS_CLAIM_REGISTERED="$CLAIM_PROBE_REGISTERED"
            status_line warn "Website claim" "not registered; run sudo apl-feed claim register"
            ;;
        authenticated)
            STATUS_CLAIM_REGISTERED='true'
            STATUS_CLAIM_VERSION="$CLAIM_PROBE_VERSION"
            STATUS_OWNER_PRESENT="$CLAIM_PROBE_OWNER_PRESENT"
            write_version_file "$CLAIM_PROBE_VERSION"
            # Claim-secret version is internal bookkeeping; exposed
            # via --json (.claim.version) and the local mirror file
            # ($IPATH/feeder-claim-secret.version) for tooling.
            # Omitting it from the human line keeps the output
            # readable — a `v1`-vs-`vN` number tells operators
            # nothing actionable.
            if [[ "$CLAIM_PROBE_OWNER_PRESENT" == "true" ]]; then
                status_line ok "Website claim" "registered and claimed"
            else
                status_line ok "Website claim" "registered, not yet claimed"
            fi
            if [[ -n "$CLAIM_PROBE_RESET_UNTIL" && "$CLAIM_PROBE_RESET_UNTIL" != "null" ]]; then
                status_line warn "Claim reset" "locked until $CLAIM_PROBE_RESET_UNTIL"
            fi
            if [[ "$CLAIM_PROBE_LAST_SEEN_PRESENT" == "true" ]]; then
                STATUS_LAST_SEEN_AT="$CLAIM_PROBE_LAST_SEEN_AT"
                STATUS_LAST_SEEN_AGE_SECONDS="$CLAIM_PROBE_LAST_SEEN_AGE"
                server_reception_status_line
            fi
            ;;
        minimal)
            STATUS_CLAIM_REGISTERED='true'
            status_line warn "Website claim" "registered, but local secret did not authenticate"
            ;;
        blocked)
            status_line fail "Website claim" "${CLAIM_PROBE_ERROR:-blocked}: $CLAIM_PROBE_DETAIL"
            ;;
        rate_limited)
            status_line warn "Website claim" "rate-limited: $CLAIM_PROBE_DETAIL"
            ;;
        *)
            status_line warn "Website claim" "unexpected HTTP $CLAIM_PROBE_HTTP: $CLAIM_PROBE_DETAIL"
            ;;
    esac
}

# diagnostics_status_line — render the airplanes-diagnostics push state.
# Reads the REPORT_STATUS toggle from feed.env, then consults the systemd
# unit (if a bad config caused an exit-64 failure on the last run) and
# the mtime of /var/lib/airplanes-diagnostics/diagnostics-last-success.
diagnostics_status_line() {
    local label="Diagnostics push"
    local unit="airplanes-diagnostics.service"
    local last_success_file
    last_success_file="$(root_path /var/lib/airplanes-diagnostics/diagnostics-last-success)"

    local raw lower
    raw="$(feed_env_get REPORT_STATUS 2>/dev/null || true)"
    lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    lower="${lower#"${lower%%[![:space:]]*}"}"
    lower="${lower%"${lower##*[![:space:]]}"}"

    local toggle
    case "$lower" in
        '') toggle='enabled_default' ;;
        true|yes|1|on) toggle='enabled' ;;
        false|no|0|off) toggle='disabled' ;;
        *) toggle='invalid' ;;
    esac
    STATUS_DIAGNOSTICS_TOGGLE="$toggle"

    if [[ "$toggle" == "invalid" ]]; then
        status_line fail "$label" "REPORT_STATUS=$raw invalid; expected true/false"
        return
    fi
    if [[ "$toggle" == "disabled" ]]; then
        status_line ok "$label" "disabled by config (REPORT_STATUS=false)"
        return
    fi

    local toggle_text
    if [[ "$toggle" == "enabled_default" ]]; then
        toggle_text='enabled (default)'
    else
        toggle_text='enabled'
    fi

    # Surface a failed unit-with-exit-64 explicitly. The script exits 64
    # on unrecognized REPORT_STATUS — captured above by toggle=invalid,
    # so this branch covers future bad-config exit codes we may add.
    if command -v systemctl >/dev/null 2>&1; then
        local active_state
        active_state="$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null || true)"
        if [[ "$active_state" == "failed" ]]; then
            local exit_code
            exit_code="$(systemctl show --property=ExecMainStatus --value "$unit" 2>/dev/null || true)"
            status_line fail "$label" "$toggle_text — unit failed${exit_code:+ (exit $exit_code)}; check journalctl -u $unit"
            return
        fi
    fi

    if [[ ! -f "$last_success_file" ]]; then
        status_line warn "$label" "$toggle_text, no successful push observed yet"
        return
    fi
    local mtime now age
    mtime="$(stat -c %Y "$last_success_file" 2>/dev/null || true)"
    now="$(date +%s 2>/dev/null || true)"
    if [[ ! "$mtime" =~ ^[0-9]+$ ]] || [[ ! "$now" =~ ^[0-9]+$ ]]; then
        status_line warn "$label" "$toggle_text, last push time unavailable"
        return
    fi
    age=$(( now - mtime ))
    if (( age < 0 )); then age=0; fi
    STATUS_DIAGNOSTICS_LAST_PUSH_AGE_SECONDS="$age"
    local age_text
    age_text="$(human_duration_ago "$age")"
    # Cadence: OnUnitActiveSec=10min + RandomizedDelaySec=30s + systemd's
    # default AccuracySec=1min coalescing → worst-case ~11.5 min per tick.
    # "One missed tick stays OK" => 2 × 11.5 min = 23 min between successful
    # pushes; add TimeoutStartSec=90s for a slow recovery run and round up
    # to 25 min for safety margin. Beyond that, one tick has clearly been
    # lost (warn ≤ 60 min) — past 60 min it's stale.
    if (( age <= 1500 )); then
        status_line ok "$label" "$toggle_text, last push $age_text"
    elif (( age <= 3600 )); then
        status_line warn "$label" "$toggle_text, last push $age_text"
    else
        status_line warn "$label" "$toggle_text, last push $age_text (stale)"
    fi
}

# config_sync_status_line — render the airplanes-config-sync remote-config
# state. Reads the REMOTE_CONFIG_ENABLED opt-in from feed.env, then consults
# the systemd unit (exit-64 hard-config failures) and the mtime of
# /var/lib/airplanes-config-sync/config-sync-last-success. The sentinel is
# touched on every successful sync (owned or unowned heartbeat), so it tracks
# liveness regardless of whether the feeder is account-claimed.
config_sync_status_line() {
    local label="Remote config"
    local unit="airplanes-config-sync.service"
    local last_success_file
    last_success_file="$(root_path /var/lib/airplanes-config-sync/config-sync-last-success)"

    local raw lower
    raw="$(feed_env_get REMOTE_CONFIG_ENABLED 2>/dev/null || true)"
    lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    lower="${lower#"${lower%%[![:space:]]*}"}"
    lower="${lower%"${lower##*[![:space:]]}"}"

    # Opt-in: absence/empty means "not consented" (off), not a default-on.
    local toggle
    case "$lower" in
        '') toggle='disabled' ;;
        true|yes|1|on) toggle='enabled' ;;
        false|no|0|off) toggle='disabled' ;;
        *) toggle='invalid' ;;
    esac
    STATUS_CONFIG_SYNC_TOGGLE="$toggle"

    if [[ "$toggle" == "invalid" ]]; then
        status_line fail "$label" "REMOTE_CONFIG_ENABLED=$raw invalid; expected true/false"
        return
    fi
    if [[ "$toggle" == "disabled" ]]; then
        status_line ok "$label" "off (remote config not enabled)"
        return
    fi

    # Surface a failed unit. config sync exits 64 on a hard config error
    # (invalid REMOTE_CONFIG_ENABLED, missing feeder-id / claim secret).
    if command -v systemctl >/dev/null 2>&1; then
        local active_state
        active_state="$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null || true)"
        if [[ "$active_state" == "failed" ]]; then
            local exit_code
            exit_code="$(systemctl show --property=ExecMainStatus --value "$unit" 2>/dev/null || true)"
            status_line fail "$label" "enabled — unit failed${exit_code:+ (exit $exit_code)}; check journalctl -u $unit"
            return
        fi
    fi

    if [[ ! -f "$last_success_file" ]]; then
        status_line warn "$label" "enabled, no successful sync observed yet"
        return
    fi
    local mtime now age
    mtime="$(stat -c %Y "$last_success_file" 2>/dev/null || true)"
    now="$(date +%s 2>/dev/null || true)"
    if [[ ! "$mtime" =~ ^[0-9]+$ ]] || [[ ! "$now" =~ ^[0-9]+$ ]]; then
        status_line warn "$label" "enabled, last sync time unavailable"
        return
    fi
    age=$(( now - mtime ))
    if (( age < 0 )); then age=0; fi
    STATUS_CONFIG_SYNC_LAST_SYNC_AGE_SECONDS="$age"
    local age_text
    age_text="$(human_duration_ago "$age")"
    # Cadence: OnUnitActiveSec=60s + RandomizedDelaySec=30s + systemd's default
    # AccuracySec=1min coalescing → worst-case ~2.5 min per tick. The sentinel
    # is touched on every successful sync, so a couple of missed ticks stays OK
    # (≤ 5 min); past that a tick has clearly been lost (warn ≤ 30 min); beyond
    # 30 min it's stale.
    if (( age <= 300 )); then
        status_line ok "$label" "enabled, last sync $age_text"
    elif (( age <= 1800 )); then
        status_line warn "$label" "enabled, last sync $age_text"
    else
        status_line warn "$label" "enabled, last sync $age_text (stale)"
    fi
}

usage_status() {
    cat <<'USAGE'
Usage: apl-feed status [--json]

Runs the feeder health checks (receiver input, feed/MLAT services, ADS-B
uplink, website claim/reception, diagnostics) and prints a summary.
--json emits a machine-readable report instead of the human summary.
USAGE
}

feed_status() {
    local opt_rc
    STATUS_OUTPUT_JSON=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_status; exit 0 ;;
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
    # Order models the ADS-B data path top-to-bottom: source → mover →
    # outbound socket, then identity (gates the server-side ack query),
    # then the server-side reception ack, then MLAT (parallel feed) and
    # diagnostics (telemetry side-channel) below.
    receiver_status_line
    receiver_activity_status_line
    service_status_line airplanes-feed "Feed service"
    adsb_uplink_status_line
    claim_registration_status_line
    mlat_status_line
    diagnostics_status_line
    config_sync_status_line
    status_finish
}
