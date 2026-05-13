#!/usr/bin/env bash
# airplanes-diagnostics.sh — collect feeder diagnostics and POST them to
# the airplanes.live backend. Invoked every 5 min by airplanes-diagnostics.timer.
#
# Exit codes
#   0   success, REPORT_STATUS=false (deliberate skip), not-yet-claimed,
#       or transient HTTP/transport failure (logged; no systemd backoff)
#   64  REPORT_STATUS has an unrecognized value — systemd marks the unit
#       failed so `apl-feed status` and `systemctl status` surface the
#       config error to the operator
#
# The script omits any field it cannot read rather than failing. The server
# drops unknown / out-of-bounds fields, so the wire schema is forgiving.

set -uo pipefail

SCRIPT_NAME="airplanes-diagnostics"
EXIT_OK=0
EXIT_BAD_CONFIG=64

LAST_SUCCESS_FILE="${AIRPLANES_DIAGNOSTICS_LAST_SUCCESS:-/var/lib/airplanes/diagnostics-last-success}"
INSTALL_DIR="${AIRPLANES_DIAGNOSTICS_INSTALL_DIR:-}"

_resolve_install_dir() {
    if [[ -n "$INSTALL_DIR" ]]; then
        printf '%s' "$INSTALL_DIR"
        return
    fi
    local self_dir
    self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s' "$self_dir"
}

_INSTALL_DIR="$(_resolve_install_dir)"

# Source helpers from apl-feed/. In production these live at
# /usr/local/share/airplanes/apl-feed/. In the source tree they're at
# feed/scripts/apl-feed/. Both resolutions land at the same directory
# relative to this script.
for _candidate in \
    "$_INSTALL_DIR/apl-feed/common.sh" \
    "$_INSTALL_DIR/../scripts/apl-feed/common.sh"; do
    if [[ -r "$_candidate" ]]; then
        _COMMON_SH="$_candidate"
        _HTTP_SH="$(dirname "$_candidate")/http.sh"
        break
    fi
done

if [[ -z "${_COMMON_SH:-}" ]] || [[ ! -r "${_HTTP_SH:-}" ]]; then
    printf '%s level=error status=fatal reason=helpers_missing install_dir=%s\n' \
        "$SCRIPT_NAME" "$_INSTALL_DIR" >&2
    exit "$EXIT_BAD_CONFIG"
fi

# shellcheck source=apl-feed/common.sh
source "$_COMMON_SH"
# shellcheck source=apl-feed/http.sh
source "$_HTTP_SH"

# common.sh unconditionally sets ROOT='/' on source. Reapply the override
# after sourcing so callers can re-root the script's filesystem reads
# (useful for tests / chroot smokes).
ROOT="${AIRPLANES_DIAGNOSTICS_ROOT:-/}"

log() {
    local level="$1"; shift
    printf '%s level=%s %s\n' "$SCRIPT_NAME" "$level" "$*" >&2
}

# parse_report_status RAW
#   echoes one of: enabled, disabled, invalid, empty
#   "empty" means the key was not set in feed.env (treated as enabled).
parse_report_status() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        printf '%s' 'empty'
        return
    fi
    local lower
    lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    # strip leading/trailing whitespace
    lower="${lower#"${lower%%[![:space:]]*}"}"
    lower="${lower%"${lower##*[![:space:]]}"}"
    case "$lower" in
        true|yes|1|on) printf '%s' 'enabled' ;;
        false|no|0|off) printf '%s' 'disabled' ;;
        *) printf '%s' 'invalid' ;;
    esac
}

# Run a probe with a 3s timeout, return the captured stdout. Failures
# (timeout, nonzero exit, command-not-found) produce empty stdout and
# return 1. Stderr is discarded.
probe() {
    if command -v "${1%% *}" >/dev/null 2>&1 || [[ "$1" == /* ]]; then
        :
    else
        return 1
    fi
    local out rc=0
    out="$(timeout 3s "$@" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        return 1
    fi
    printf '%s' "$out"
}

# Read /proc/uptime; print integer seconds or empty on failure.
collect_uptime_seconds() {
    local raw
    raw="$(awk '{print int($1)}' "$(root_path /proc/uptime)" 2>/dev/null)" || return 1
    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$raw"
}

# Read /proc/loadavg into LOAD_1M LOAD_5M LOAD_15M (caller-supplied vars).
collect_loadavg() {
    local line
    line="$(awk '{print $1, $2, $3}' "$(root_path /proc/loadavg)" 2>/dev/null)" || return 1
    read -r LOAD_1M LOAD_5M LOAD_15M <<<"$line"
    [[ "$LOAD_1M" =~ ^[0-9.]+$ && "$LOAD_5M" =~ ^[0-9.]+$ && "$LOAD_15M" =~ ^[0-9.]+$ ]] || return 1
}

# Iterate /sys/class/thermal/thermal_zone*/type looking for a CPU zone;
# read the sibling temp file. Print degrees Celsius (float, 1 decimal).
collect_cpu_temp_c() {
    local base
    base="$(root_path /sys/class/thermal)"
    [[ -d "$base" ]] || return 1
    local type_file zone_dir type_value temp_mc
    for type_file in "$base"/thermal_zone*/type; do
        [[ -r "$type_file" ]] || continue
        type_value="$(<"$type_file")"
        case "$type_value" in
            cpu-thermal|cpu_thermal|x86_pkg_temp|coretemp) ;;
            *) continue ;;
        esac
        zone_dir="$(dirname "$type_file")"
        [[ -r "$zone_dir/temp" ]] || continue
        temp_mc="$(<"$zone_dir/temp")"
        [[ "$temp_mc" =~ ^-?[0-9]+$ ]] || continue
        awk -v mc="$temp_mc" 'BEGIN { printf "%.1f", mc / 1000 }'
        return 0
    done
    return 1
}

# Read /proc/meminfo. Sets MEM_TOTAL_BYTES + MEM_USED_PERCENT.
# Falls back to MemFree + Buffers + Cached when MemAvailable is missing.
collect_memory() {
    local mem_total_kb mem_avail_kb mem_free_kb buffers_kb cached_kb
    local file
    file="$(root_path /proc/meminfo)"
    [[ -r "$file" ]] || return 1
    mem_total_kb="$(awk '/^MemTotal:/{print $2; exit}' "$file" 2>/dev/null || true)"
    mem_avail_kb="$(awk '/^MemAvailable:/{print $2; exit}' "$file" 2>/dev/null || true)"
    if [[ -z "$mem_avail_kb" ]]; then
        mem_free_kb="$(awk '/^MemFree:/{print $2; exit}' "$file" 2>/dev/null || true)"
        buffers_kb="$(awk '/^Buffers:/{print $2; exit}' "$file" 2>/dev/null || true)"
        cached_kb="$(awk '/^Cached:/{print $2; exit}' "$file" 2>/dev/null || true)"
        if [[ "$mem_free_kb" =~ ^[0-9]+$ ]]; then
            mem_avail_kb=$(( mem_free_kb + ${buffers_kb:-0} + ${cached_kb:-0} ))
        fi
    fi
    [[ "$mem_total_kb" =~ ^[0-9]+$ && "$mem_avail_kb" =~ ^[0-9]+$ ]] || return 1
    (( mem_total_kb > 0 )) || return 1
    MEM_TOTAL_BYTES=$(( mem_total_kb * 1024 ))
    MEM_USED_PERCENT="$(awk -v t="$mem_total_kb" -v a="$mem_avail_kb" \
        'BEGIN { if (t == 0) { print "" } else { printf "%.1f", (1 - a / t) * 100 } }')"
    [[ -n "$MEM_USED_PERCENT" ]] || return 1
}

# `df -B1 --output=size,used /` is the GNU long-form. Sets DISK_TOTAL_BYTES
# + DISK_USED_PERCENT.
collect_disk() {
    local line size used
    line="$(timeout 3s df -B1 --output=size,used "$(root_path /)" 2>/dev/null | awk 'NR==2 {print $1, $2}')" || return 1
    [[ -n "$line" ]] || return 1
    read -r size used <<<"$line"
    [[ "$size" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]] || return 1
    (( size > 0 )) || return 1
    DISK_TOTAL_BYTES="$size"
    DISK_USED_PERCENT="$(awk -v s="$size" -v u="$used" 'BEGIN { printf "%.1f", (u / s) * 100 }')"
}

# Default-route iface classification. Sets NET_CONNECTION_TYPE and
# (only when wifi) NET_WIFI_RSSI_DBM.
collect_network() {
    NET_CONNECTION_TYPE='unknown'
    NET_WIFI_RSSI_DBM=''
    command -v ip >/dev/null 2>&1 || return 0

    local iface=''
    if ip -j route show default >/dev/null 2>&1; then
        iface="$(timeout 3s ip -j route show default 2>/dev/null \
            | jq -r '.[0].dev // empty' 2>/dev/null)"
    fi
    if [[ -z "$iface" ]]; then
        # Fallback for older iproute2 without -j. Parse: "default via ... dev IFACE ..."
        iface="$(timeout 3s ip route show default 2>/dev/null \
            | awk '$1 == "default" { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
    fi
    [[ -n "$iface" ]] || return 0
    # Allowlist iface to ASCII alnum + dash; never log raw.
    if [[ ! "$iface" =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 0
    fi

    local sys_iface
    sys_iface="$(root_path /sys/class/net/$iface/wireless)"
    if [[ -d "$sys_iface" ]]; then
        NET_CONNECTION_TYPE='wifi'
        if command -v iw >/dev/null 2>&1; then
            local rssi
            rssi="$(timeout 3s iw dev "$iface" link 2>/dev/null \
                | awk '/signal:/ { print $2; exit }')"
            if [[ "$rssi" =~ ^-?[0-9]+$ ]]; then
                NET_WIFI_RSSI_DBM="$rssi"
            fi
        fi
    else
        NET_CONNECTION_TYPE='ethernet'
    fi
}

# vcgencmd get_throttled bit decode. Pi documentation:
#   bit 0  undervoltage_now        bit 16 undervoltage_ever
#   bit 1  freq_capped_now         bit 17 freq_capped_ever
#   bit 2  throttled_now           bit 18 throttled_ever
#   bit 3  soft_temp_limit_now     bit 19 soft_temp_limit_ever
# Sets pi_health_* globals. Returns 0 on success, 1 if vcgencmd absent or
# its output unparseable.
collect_pi_throttle() {
    command -v vcgencmd >/dev/null 2>&1 || return 1
    local raw value
    raw="$(timeout 3s vcgencmd get_throttled 2>/dev/null)" || return 1
    # raw is like "throttled=0x50005"
    value="${raw#throttled=}"
    [[ "$value" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
    local n=$(( value ))
    pi_undervoltage_now=$(( (n >> 0) & 1 ))
    pi_freq_capped_now=$(( (n >> 1) & 1 ))
    pi_throttled_now=$(( (n >> 2) & 1 ))
    pi_soft_temp_limit_now=$(( (n >> 3) & 1 ))
    pi_undervoltage_ever=$(( (n >> 16) & 1 ))
    pi_freq_capped_ever=$(( (n >> 17) & 1 ))
    pi_throttled_ever=$(( (n >> 18) & 1 ))
    pi_soft_temp_limit_ever=$(( (n >> 19) & 1 ))
}

# timedatectl show -p NTPSynchronized --value -> "yes" / "no" / ""
collect_pi_ntp_sync() {
    command -v timedatectl >/dev/null 2>&1 || return 1
    local raw
    raw="$(timeout 3s timedatectl show -p NTPSynchronized --value 2>/dev/null)" || return 1
    case "$raw" in
        yes) printf 'true' ;;
        no) printf 'false' ;;
        *) return 1 ;;
    esac
}

# Resolve a service's version. Priority:
#   1. Install-time file at $IPATH/<file>_version (written by update-builds.sh)
#   2. Best-effort `<binary> --version | head -1` (3s timeout)
# Returns empty on failure.
get_service_version() {
    local service="$1"
    local ipath
    ipath="$(root_path /usr/local/share/airplanes)"
    local version_file=''
    case "$service" in
        airplanes-feed) version_file="$ipath/readsb_version" ;;
        airplanes-mlat) version_file="$ipath/mlat_version" ;;
    esac
    if [[ -n "$version_file" && -r "$version_file" ]]; then
        local v
        v="$(head -n 1 "$version_file" 2>/dev/null | tr -d '[:cntrl:]')"
        if [[ -n "$v" ]]; then
            printf '%s' "$v"
            return 0
        fi
    fi
    # Fallback: try a binary on PATH. Bounded list — no shell injection vector.
    local bin=''
    case "$service" in
        dump978-fa) bin='dump978-fa' ;;
    esac
    [[ -n "$bin" ]] || return 1
    command -v "$bin" >/dev/null 2>&1 || return 1
    local raw
    raw="$(timeout 3s "$bin" --version 2>/dev/null | head -n 1 | tr -d '[:cntrl:]')" || return 1
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

# Build a single service object as JSON (or print "null" if the unit is
# load_state=not-found / systemctl unavailable / probe failed).
build_service_json() {
    local name="$1"
    command -v systemctl >/dev/null 2>&1 || { printf 'null'; return; }
    local show_out
    show_out="$(timeout 3s systemctl show "$name" \
        --property=LoadState,UnitFileState,ActiveState,SubState,NRestarts 2>/dev/null)" \
        || { printf 'null'; return; }
    local load_state unit_file_state active_state sub_state nrestarts
    load_state="$(awk -F= '/^LoadState=/{print $2; exit}' <<<"$show_out")"
    unit_file_state="$(awk -F= '/^UnitFileState=/{print $2; exit}' <<<"$show_out")"
    active_state="$(awk -F= '/^ActiveState=/{print $2; exit}' <<<"$show_out")"
    sub_state="$(awk -F= '/^SubState=/{print $2; exit}' <<<"$show_out")"
    nrestarts="$(awk -F= '/^NRestarts=/{print $2; exit}' <<<"$show_out")"
    if [[ -z "$load_state" || "$load_state" == "not-found" ]]; then
        printf 'null'
        return
    fi
    [[ "$nrestarts" =~ ^[0-9]+$ ]] || nrestarts=0
    local version
    version="$(get_service_version "$name" || true)"
    jq -nc \
        --arg name "$name" \
        --arg load_state "${load_state:-}" \
        --arg unit_file_state "${unit_file_state:-}" \
        --arg active_state "${active_state:-}" \
        --arg sub_state "${sub_state:-}" \
        --argjson restart_count_total "$nrestarts" \
        --arg version "${version:-}" \
        '{name: $name,
          load_state: $load_state,
          unit_file_state: $unit_file_state,
          active_state: $active_state,
          sub_state: $sub_state,
          restart_count_total: $restart_count_total,
          version: $version}
         | with_entries(select(.value != null and .value != ""))'
}

# Build the pi_health block as JSON, or print "null" if neither sub-probe
# produced data. Sub-probes are independent — a missing/broken
# `timedatectl` doesn't suppress vcgencmd throttle data and vice versa.
build_pi_health_json() {
    local throttle_json='null' ntp_json='null'
    local pi_undervoltage_now=0 pi_freq_capped_now=0 pi_throttled_now=0 pi_soft_temp_limit_now=0
    local pi_undervoltage_ever=0 pi_freq_capped_ever=0 pi_throttled_ever=0 pi_soft_temp_limit_ever=0
    if command -v vcgencmd >/dev/null 2>&1 && collect_pi_throttle; then
        throttle_json="$(jq -nc \
            --argjson uv_now "$pi_undervoltage_now" \
            --argjson fc_now "$pi_freq_capped_now" \
            --argjson th_now "$pi_throttled_now" \
            --argjson st_now "$pi_soft_temp_limit_now" \
            --argjson uv_ever "$pi_undervoltage_ever" \
            --argjson fc_ever "$pi_freq_capped_ever" \
            --argjson th_ever "$pi_throttled_ever" \
            --argjson st_ever "$pi_soft_temp_limit_ever" \
            '{undervoltage_now: ($uv_now == 1),
              freq_capped_now: ($fc_now == 1),
              throttled_now: ($th_now == 1),
              soft_temp_limit_now: ($st_now == 1),
              undervoltage_ever: ($uv_ever == 1),
              freq_capped_ever: ($fc_ever == 1),
              throttled_ever: ($th_ever == 1),
              soft_temp_limit_ever: ($st_ever == 1)}')"
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        local ntp
        if ntp="$(collect_pi_ntp_sync)"; then
            ntp_json="$ntp"
        fi
    fi
    if [[ "$throttle_json" == 'null' && "$ntp_json" == 'null' ]]; then
        printf 'null'
        return
    fi
    jq -nc \
        --argjson throttle "$throttle_json" \
        --argjson ntp "$ntp_json" \
        '{throttle: $throttle, ntp_synchronized: $ntp}'
}

# nullable_num VALUE — echoes the value if non-empty, otherwise "null".
# Used with `jq --argjson` so missing numerics become JSON null and the
# `del(.. | nulls?)` pass strips them from the payload.
nullable_num() {
    if [[ -n "${1:-}" ]]; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}

# Read /etc/os-release safely. We can't `source` it (rule: never source
# user-controlled config in helpers); parse with sed instead.
get_os_release_field() {
    local key="$1"
    local file
    file="$(root_path /etc/os-release)"
    [[ -r "$file" ]] || return 1
    local raw
    raw="$(sed -n -e "s/^${key}=\"\\(.*\\)\"\$/\\1/p" \
                  -e "s/^${key}='\\(.*\\)'\$/\\1/p" \
                  -e "s/^${key}=\\([^#[:space:]\"']*\\).*\$/\\1/p" \
                  "$file" 2>/dev/null | head -n 1)"
    [[ -n "$raw" ]] || return 1
    # Strip control chars; cap to 128 chars for the wire schema's string rule.
    raw="$(printf '%s' "$raw" | tr -d '[:cntrl:]' | cut -c1-128)"
    printf '%s' "$raw"
}

get_feed_scripts_version() {
    local file
    file="$(root_path /usr/local/share/airplanes/.version)"
    [[ -r "$file" ]] || return 1
    local raw
    raw="$(head -n 1 "$file" 2>/dev/null | tr -d '[:cntrl:]' | cut -c1-128)"
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

get_image_release() {
    local file
    file="$(root_path /etc/airplanes/release-channel)"
    [[ -r "$file" ]] || return 1
    local raw
    raw="$(head -n 1 "$file" 2>/dev/null | tr -d '[:cntrl:]' | cut -c1-128)"
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

touch_last_success() {
    local path="$LAST_SUCCESS_FILE"
    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || true
    # touch failure is non-fatal after a successful POST — log and continue.
    if ! touch "$path" 2>/dev/null; then
        log warn "status=touch_failed path=$path"
    fi
}

main() {
    # 1. Resolve REPORT_STATUS toggle. feed_env_get returns nonzero when
    # the key is absent — handle both branches uniformly.
    local report_status_raw
    report_status_raw="$(feed_env_get REPORT_STATUS 2>/dev/null || true)"
    local toggle
    toggle="$(parse_report_status "$report_status_raw")"
    case "$toggle" in
        invalid)
            log error "status=bad_config key=REPORT_STATUS value=${report_status_raw}"
            exit "$EXIT_BAD_CONFIG"
            ;;
        disabled)
            log info "status=disabled"
            exit "$EXIT_OK"
            ;;
        enabled|empty) ;;
    esac

    # 2. Read identity. Either piece missing means the feeder isn't claimed
    # yet; the timer will fire again in 5 min once claim has run.
    local uuid secret
    uuid="$(read_uuid 2>/dev/null)" || {
        log info "status=not_configured reason=no_uuid"
        exit "$EXIT_OK"
    }
    if ! uuid="$(canonicalize_uuid "$uuid" 2>/dev/null)" || [[ -z "$uuid" ]]; then
        log info "status=not_configured reason=bad_uuid"
        exit "$EXIT_OK"
    fi
    secret="$(read_secret_file "$(secret_final_path)" 2>/dev/null)" || {
        log info "status=not_configured reason=no_secret"
        exit "$EXIT_OK"
    }
    if ! validate_secret "$secret"; then
        log info "status=not_configured reason=bad_secret"
        exit "$EXIT_OK"
    fi

    # 3. Collect. Each variable is empty on probe failure; nullable_num /
    # `--arg` with empty + `del(.. | nulls?)` removes them from the
    # payload before send.
    local uptime_seconds LOAD_1M='' LOAD_5M='' LOAD_15M='' cpu_temp_c=''
    local MEM_TOTAL_BYTES='' MEM_USED_PERCENT=''
    local DISK_TOTAL_BYTES='' DISK_USED_PERCENT=''
    local NET_CONNECTION_TYPE='unknown' NET_WIFI_RSSI_DBM=''
    uptime_seconds="$(collect_uptime_seconds || true)"
    collect_loadavg || true
    cpu_temp_c="$(collect_cpu_temp_c || true)"
    collect_memory || true
    collect_disk || true
    collect_network || true

    local svc_feed svc_mlat svc_978
    svc_feed="$(build_service_json airplanes-feed)"
    svc_mlat="$(build_service_json airplanes-mlat)"
    svc_978="$(build_service_json dump978-fa)"

    local pi_health_json
    pi_health_json="$(build_pi_health_json)"

    local feed_scripts_version os_pretty_name os_id os_version_id kernel architecture image_release
    feed_scripts_version="$(get_feed_scripts_version || true)"
    os_pretty_name="$(get_os_release_field PRETTY_NAME || true)"
    os_id="$(get_os_release_field ID || true)"
    os_version_id="$(get_os_release_field VERSION_ID || true)"
    kernel="$(uname -r 2>/dev/null | tr -d '[:cntrl:]' | cut -c1-128)"
    architecture="$(uname -m 2>/dev/null | tr -d '[:cntrl:]' | cut -c1-128)"
    image_release="$(get_image_release || true)"

    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    # 4. Build the payload. jq's `del(.. | nulls?)` recursively drops
    # null values, so omitted optional fields disappear from the JSON.
    # Services array is filtered to drop nulls (missing units).
    local payload
    payload="$(jq -nc \
        --arg ts "$ts" \
        --arg uuid "$uuid" \
        --argjson uptime_seconds "$(nullable_num "$uptime_seconds")" \
        --argjson load_1m "$(nullable_num "$LOAD_1M")" \
        --argjson load_5m "$(nullable_num "$LOAD_5M")" \
        --argjson load_15m "$(nullable_num "$LOAD_15M")" \
        --argjson cpu_temp_c "$(nullable_num "$cpu_temp_c")" \
        --argjson mem_used_pct "$(nullable_num "$MEM_USED_PERCENT")" \
        --argjson mem_total_bytes "$(nullable_num "$MEM_TOTAL_BYTES")" \
        --argjson disk_used_pct "$(nullable_num "$DISK_USED_PERCENT")" \
        --argjson disk_total_bytes "$(nullable_num "$DISK_TOTAL_BYTES")" \
        --arg net_connection_type "${NET_CONNECTION_TYPE:-unknown}" \
        --argjson wifi_rssi "$(nullable_num "$NET_WIFI_RSSI_DBM")" \
        --argjson svc_feed "$svc_feed" \
        --argjson svc_mlat "$svc_mlat" \
        --argjson svc_978 "$svc_978" \
        --argjson pi_health "$pi_health_json" \
        --arg feed_scripts "${feed_scripts_version:-}" \
        --arg os_pretty_name "${os_pretty_name:-}" \
        --arg os_id "${os_id:-}" \
        --arg os_version_id "${os_version_id:-}" \
        --arg kernel "${kernel:-}" \
        --arg architecture "${architecture:-}" \
        --arg image_release "${image_release:-}" \
        '{
            schema_version: 1,
            ts: $ts,
            uuid: $uuid,
            system: {
                uptime_seconds: $uptime_seconds,
                cpu: {
                    load_1m: $load_1m,
                    load_5m: $load_5m,
                    load_15m: $load_15m,
                    temperature_celsius: $cpu_temp_c
                },
                memory: {
                    used_percent: $mem_used_pct,
                    total_bytes: $mem_total_bytes
                },
                disk: {
                    used_percent: $disk_used_pct,
                    total_bytes: $disk_total_bytes
                }
            },
            network: {
                connection_type: $net_connection_type,
                wifi_rssi_dbm: $wifi_rssi
            },
            services: [$svc_feed, $svc_mlat, $svc_978] | map(select(. != null)),
            versions: {
                feed_scripts: $feed_scripts,
                os_pretty_name: $os_pretty_name,
                os_id: $os_id,
                os_version_id: $os_version_id,
                kernel: $kernel,
                architecture: $architecture,
                image_release: $image_release
            },
            pi_health: $pi_health
        }
        | def _prune:
            if type == "object" then
                with_entries(.value |= _prune)
                | with_entries(select(.value != null and .value != ""))
            elif type == "array" then
                map(_prune) | map(select(. != null))
            else . end;
          _prune
        ')"
    # The inline _prune def avoids jq 1.5 packagings that omit `walk`
    # (Debian Buster). Post-order recursion: drops null and empty-string
    # entries from objects, null entries from arrays.

    # 5. POST. Bearer = alv1.<uuid>.<secret>. The bearer goes into a 0600
    # curl --config file (not argv) so the token can't be inspected via
    # `ps`.
    local response_file token status curl_rc
    response_file="$(new_tmp_file)"
    token="alv1.${uuid}.${secret}"

    set +e
    status="$(post_json_bearer "$token" '/api/feeders/diagnostics' "$payload" "$response_file")"
    curl_rc=$?
    set -e
    # Wipe the token before any further work — it's no longer needed.
    token=''

    if (( curl_rc != 0 )); then
        log warn "status=transport_error curl_rc=$curl_rc"
        exit "$EXIT_OK"
    fi

    case "$status" in
        2*)
            touch_last_success
            log info "status=ok http=$status"
            ;;
        4*)
            local body_err
            body_err="$(parse_field_from "$response_file" '.error')"
            log warn "status=client_error http=$status error=${body_err:-unknown}"
            ;;
        5*)
            log warn "status=server_error http=$status"
            ;;
        *)
            log warn "status=unexpected http=$status"
            ;;
    esac
    exit "$EXIT_OK"
}

# Source guard: only run main when executed directly, not when a test
# sources this file to exercise the helper functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
