#!/usr/bin/env bats

# Tests for scripts/airplanes-diagnostics.sh — the feeder diagnostics
# push script invoked every 5 min by airplanes-diagnostics.timer.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO_ROOT/scripts/airplanes-diagnostics.sh"

    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    COMMAND_LOG="$ROOT_DIR/cmd.log"
    BODY_LOG="$ROOT_DIR/body.log"
    HEADER_LOG="$ROOT_DIR/header.log"
    mkdir -p "$STUB_DIR" "$ROOT_DIR/var/lib"

    # curl stub: records argv, dumps --config file contents (the bearer
    # header), captures stdin (the request body), writes a synthetic
    # response, and exits with $CURL_STATUS / $CURL_RC. The token must
    # NEVER appear in argv — only inside the --config file.
    cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
prev=''
output_file=''
for arg in "$@"; do
    if [[ "$prev" == "--config" && -r "$arg" ]]; then
        cat "$arg" >> "$HEADER_LOG"
    fi
    if [[ "$prev" == "--output" ]]; then
        output_file="$arg"
    fi
    prev="$arg"
done
# Drain stdin (the JSON body) so callers can inspect what was sent.
cat > "$BODY_LOG"
if [[ -n "$output_file" ]]; then
    printf '%s' "${CURL_RESPONSE:-{\"ok\":true\}}" > "$output_file"
fi
printf '%s' "${CURL_STATUS:-200}"
exit "${CURL_RC:-0}"
SH
    chmod +x "$STUB_DIR/curl"

    # systemctl stub: returns canned output for `systemctl show ...`.
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "show airplanes-feed "*) cat <<'P'
LoadState=loaded
UnitFileState=enabled
ActiveState=active
SubState=running
NRestarts=2
P
        ;;
    "show airplanes-mlat "*) cat <<'P'
LoadState=loaded
UnitFileState=enabled
ActiveState=active
SubState=running
NRestarts=0
P
        ;;
    "show dump978-fa "*)
        cat <<'P'
LoadState=not-found
UnitFileState=
ActiveState=inactive
SubState=dead
NRestarts=0
P
        ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"

    # df stub: produces predictable bytes output for `df -B1 --output=size,used <path>`.
    cat > "$STUB_DIR/df" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '       Size       Used'
printf '%s\n' ' 34359738368 5368709120'
SH
    chmod +x "$STUB_DIR/df"

    # ip stub: respond to `ip -j route show default` with a JSON array.
    cat > "$STUB_DIR/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "-j route show default") printf '[{"dst":"default","dev":"eth0"}]\n' ;;
    "route show default") printf 'default via 192.168.1.1 dev eth0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/ip"

    # iw stub: emits a wifi link snippet (only used by wifi tests).
    cat > "$STUB_DIR/iw" <<'SH'
#!/usr/bin/env bash
printf 'signal: -58 dBm\n'
exit 0
SH
    chmod +x "$STUB_DIR/iw"

    # uname stub
    cat > "$STUB_DIR/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -r) printf '6.6.20+rpt-rpi-2712\n' ;;
    -m) printf 'aarch64\n' ;;
    *) printf 'Linux\n' ;;
esac
SH
    chmod +x "$STUB_DIR/uname"

    # timeout stub: just exec the command (no real timeout in tests).
    cat > "$STUB_DIR/timeout" <<'SH'
#!/usr/bin/env bash
shift  # drop the duration arg
exec "$@"
SH
    chmod +x "$STUB_DIR/timeout"

    # /proc and /sys synthesis under ROOT_DIR — the script's ROOT override
    # routes /proc/uptime → $ROOT_DIR/proc/uptime, etc.
    mkdir -p "$ROOT_DIR/proc" "$ROOT_DIR/sys/class/net/eth0" \
             "$ROOT_DIR/sys/class/thermal/thermal_zone0" "$ROOT_DIR/etc/airplanes" \
             "$ROOT_DIR/usr/local/share/airplanes"
    printf '12345.67 9999.99\n' > "$ROOT_DIR/proc/uptime"
    printf '0.42 0.38 0.41 1/100 12345\n' > "$ROOT_DIR/proc/loadavg"
    cat > "$ROOT_DIR/proc/meminfo" <<'MEM'
MemTotal:        4194304 kB
MemFree:          524288 kB
MemAvailable:    2785280 kB
Buffers:          131072 kB
Cached:           786432 kB
MEM
    printf 'cpu-thermal\n' > "$ROOT_DIR/sys/class/thermal/thermal_zone0/type"
    printf '52300\n' > "$ROOT_DIR/sys/class/thermal/thermal_zone0/temp"
    cat > "$ROOT_DIR/etc/os-release" <<'OSR'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
ID=debian
OSR
    printf '0.4.2\n' > "$ROOT_DIR/usr/local/share/airplanes/.version"
    printf '0a1b2c3d4e5f6a7b8c9d\n' > "$ROOT_DIR/usr/local/share/airplanes/readsb_version"
    printf 'feedcafe00112233\n' > "$ROOT_DIR/usr/local/share/airplanes/mlat_version"

    # Claim state
    printf '11111111-2222-3333-4444-555555555555\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    chmod 0644 "$ROOT_DIR/etc/airplanes/feeder-id"
    printf 'ABCDEFGHIJKLMNOP\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    printf 'REPORT_STATUS=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"

    LAST_SUCCESS="$ROOT_DIR/var/lib/airplanes/diagnostics-last-success"
    mkdir -p "$(dirname "$LAST_SUCCESS")"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

run_script() {
    run env -i \
        PATH="$STUB_DIR:/usr/bin:/bin" \
        HOME="$ROOT_DIR" \
        AIRPLANES_DIAGNOSTICS_ROOT="$ROOT_DIR" \
        AIRPLANES_DIAGNOSTICS_LAST_SUCCESS="$LAST_SUCCESS" \
        APL_FEED_SERVER_URL='http://127.0.0.1:0' \
        COMMAND_LOG="$COMMAND_LOG" \
        BODY_LOG="$BODY_LOG" \
        HEADER_LOG="$HEADER_LOG" \
        CURL_STATUS="${CURL_STATUS:-200}" \
        CURL_RC="${CURL_RC:-0}" \
        CURL_RESPONSE="${CURL_RESPONSE:-}" \
        bash "$SCRIPT"
}

# ---- toggle parsing ----

@test "REPORT_STATUS unset (commented) treats as enabled (default)" {
    printf '\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]  # curl was called
}

@test "REPORT_STATUS=true treats as enabled and POSTs" {
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
}

@test "REPORT_STATUS=yes treats as enabled" {
    printf 'REPORT_STATUS=yes\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
}

@test "REPORT_STATUS=1 treats as enabled" {
    printf 'REPORT_STATUS=1\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
}

@test "REPORT_STATUS=on treats as enabled" {
    printf 'REPORT_STATUS=on\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
}

@test "REPORT_STATUS=false treats as disabled and skips POST" {
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ ! -f "$COMMAND_LOG" ]
    [ ! -f "$LAST_SUCCESS" ]
}

@test "REPORT_STATUS=off treats as disabled" {
    printf 'REPORT_STATUS=off\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ ! -f "$COMMAND_LOG" ]
}

@test "REPORT_STATUS=False (capital F) treats as disabled (case-insensitive)" {
    printf 'REPORT_STATUS=False\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ ! -f "$COMMAND_LOG" ]
}

@test "REPORT_STATUS=foo (garbage) exits 64 with bad_config log" {
    printf 'REPORT_STATUS=foo\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 64 ]
    [[ "$output" == *"status=bad_config"* ]]
    [[ "$output" == *"REPORT_STATUS"* ]]
    [ ! -f "$COMMAND_LOG" ]
}

# ---- unclaimed feeder ----

@test "missing UUID file exits 0 silently (not yet claimed)" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"
    run_script
    [ "$status" -eq 0 ]
    [ ! -f "$COMMAND_LOG" ]
    [[ "$output" == *"status=not_configured"* ]]
}

@test "missing claim secret exits 0 silently" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run_script
    [ "$status" -eq 0 ]
    [ ! -f "$COMMAND_LOG" ]
    [[ "$output" == *"status=not_configured"* ]]
}

@test "invalid claim secret exits 0 silently" {
    printf 'not-a-valid-secret\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run_script
    [ "$status" -eq 0 ]
    [ ! -f "$COMMAND_LOG" ]
}

# ---- bearer token handling ----

@test "bearer token does NOT appear in curl argv" {
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
    # The canonical secret + UUID would form alv1.11111111-...-555555555555.ABCDEFGHIJKLMNOP
    ! grep -q 'ABCDEFGHIJKLMNOP' "$COMMAND_LOG"
    ! grep -q 'alv1\.' "$COMMAND_LOG"
}

@test "bearer is written to --config file with alv1.<uuid>.<secret> format" {
    run_script
    [ "$status" -eq 0 ]
    [ -f "$HEADER_LOG" ]
    grep -q 'Authorization: Bearer alv1\.11111111-2222-3333-4444-555555555555\.ABCDEFGHIJKLMNOP' "$HEADER_LOG"
}

# ---- payload shape ----

@test "POST body is valid JSON with schema_version=1" {
    run_script
    [ "$status" -eq 0 ]
    [ -s "$BODY_LOG" ]
    run jq -e '.schema_version == 1' "$BODY_LOG"
    [ "$status" -eq 0 ]
}

@test "POST body contains canonical lowercase UUID" {
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.uuid' "$BODY_LOG"
    [ "$output" = '11111111-2222-3333-4444-555555555555' ]
}

@test "POST body system block reflects probed values" {
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.system.uptime_seconds' "$BODY_LOG"
    [ "$output" = '12345' ]
    run jq -er '.system.cpu.load_1m' "$BODY_LOG"
    [ "$output" = '0.42' ]
    run jq -er '.system.cpu.temperature_celsius' "$BODY_LOG"
    [ "$output" = '52.3' ]
}

@test "POST body services array filters out load_state=not-found units" {
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services | length' "$BODY_LOG"
    [ "$output" = '2' ]
    run jq -er '[.services[].name] | sort | join(",")' "$BODY_LOG"
    [ "$output" = 'airplanes-feed,airplanes-mlat' ]
}

@test "POST body service version is read from install-time readsb_version file" {
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services[] | select(.name=="airplanes-feed") | .version' "$BODY_LOG"
    [ "$output" = '0a1b2c3d4e5f6a7b8c9d' ]
}

@test "POST body versions block reflects /etc/os-release and uname" {
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.versions.os_pretty_name' "$BODY_LOG"
    [ "$output" = 'Debian GNU/Linux 12 (bookworm)' ]
    run jq -er '.versions.kernel' "$BODY_LOG"
    [ "$output" = '6.6.20+rpt-rpi-2712' ]
    run jq -er '.versions.architecture' "$BODY_LOG"
    [ "$output" = 'aarch64' ]
}

@test "POST body network.connection_type=ethernet when default route is on eth0" {
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.network.connection_type' "$BODY_LOG"
    [ "$output" = 'ethernet' ]
    run jq '.network.wifi_rssi_dbm // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body picks up wifi RSSI when default route is on a wifi iface" {
    # Re-create the iface tree as a wifi interface
    mkdir -p "$ROOT_DIR/sys/class/net/wlan0/wireless"
    cat > "$STUB_DIR/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "-j route show default") printf '[{"dst":"default","dev":"wlan0"}]\n' ;;
    "route show default") printf 'default via 192.168.1.1 dev wlan0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/ip"
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.network.connection_type' "$BODY_LOG"
    [ "$output" = 'wifi' ]
    run jq -er '.network.wifi_rssi_dbm' "$BODY_LOG"
    [ "$output" = '-58' ]
}

@test "POST body omits pi_health when vcgencmd is absent" {
    run_script
    [ "$status" -eq 0 ]
    run jq '.pi_health // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body pi_health bit decode for vcgencmd=0x50005" {
    cat > "$STUB_DIR/vcgencmd" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "get_throttled" ]] && printf 'throttled=0x50005\n'
SH
    chmod +x "$STUB_DIR/vcgencmd"
    cat > "$STUB_DIR/timedatectl" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "show" ]] && printf 'yes\n'
SH
    chmod +x "$STUB_DIR/timedatectl"
    run_script
    [ "$status" -eq 0 ]
    # bits 0, 2, 16, 18 set: undervoltage_now, throttled_now,
    # undervoltage_ever, throttled_ever — all true.
    run jq -er '.pi_health.throttle.undervoltage_now' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_health.throttle.throttled_now' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_health.throttle.undervoltage_ever' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_health.throttle.throttled_ever' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_health.throttle.freq_capped_now' "$BODY_LOG"
    [ "$output" = 'false' ]
    run jq -er '.pi_health.throttle.soft_temp_limit_ever' "$BODY_LOG"
    [ "$output" = 'false' ]
    run jq -er '.pi_health.ntp_synchronized' "$BODY_LOG"
    [ "$output" = 'true' ]
}

# ---- response handling ----

@test "HTTP 2xx touches last-success file" {
    run_script
    [ "$status" -eq 0 ]
    [ -f "$LAST_SUCCESS" ]
}

@test "HTTP 4xx logs structured error but exits 0 (no systemd backoff)" {
    CURL_STATUS=400 CURL_RESPONSE='{"error":"schema_version_unknown"}' run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=client_error"* ]]
    [[ "$output" == *"http=400"* ]]
    [ ! -f "$LAST_SUCCESS" ]
}

@test "HTTP 5xx logs server_error and exits 0" {
    CURL_STATUS=503 run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=server_error"* ]]
    [ ! -f "$LAST_SUCCESS" ]
}

@test "transport error (curl rc != 0) logs and exits 0" {
    CURL_RC=7 run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=transport_error"* ]]
    [[ "$output" == *"curl_rc=7"* ]]
    [ ! -f "$LAST_SUCCESS" ]
}

# ---- probe failures degrade gracefully ----

@test "missing /etc/os-release causes versions fields to be omitted, payload still sent" {
    rm -f "$ROOT_DIR/etc/os-release"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$BODY_LOG" ]
    run jq '.versions.os_pretty_name // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "missing thermal zone omits temperature_celsius, payload still sent" {
    rm -rf "$ROOT_DIR/sys/class/thermal"
    run_script
    [ "$status" -eq 0 ]
    run jq '.system.cpu.temperature_celsius // empty' "$BODY_LOG"
    [ -z "$output" ]
}
