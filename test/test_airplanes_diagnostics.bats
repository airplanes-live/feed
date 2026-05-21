#!/usr/bin/env bats

# Tests for scripts/airplanes-diagnostics.sh — the feeder diagnostics
# push script invoked every 10 min by airplanes-diagnostics.timer.

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
    INTENT_ACK="$ROOT_DIR/var/lib/airplanes/diagnostics-intent-acked"
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
        AIRPLANES_DIAGNOSTICS_INTENT_ACK_FILE="$INTENT_ACK" \
        APL_FEED_WEBSITE_URL="${APL_FEED_WEBSITE_URL:-http://127.0.0.1:0}" \
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

@test "REPORT_STATUS=false with no prior ack sends one-shot goodbye POST" {
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
    # Goodbye payload is the bare envelope — no system/services/versions
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'false' ]
    run jq -er '.schema_version' "$BODY_LOG"
    [ "$output" = '1' ]
    run jq -er '.uuid' "$BODY_LOG"
    [ "$output" = '11111111-2222-3333-4444-555555555555' ]
    run jq '.system // empty' "$BODY_LOG"
    [ -z "$output" ]
    run jq '.services // empty' "$BODY_LOG"
    [ -z "$output" ]
    run jq '.versions // empty' "$BODY_LOG"
    [ -z "$output" ]
    # Ack file recorded false
    [ -f "$INTENT_ACK" ]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'false' ]
    # Last-success only fires on full reports
    [ ! -f "$LAST_SUCCESS" ]
}

@test "REPORT_STATUS=off with no prior ack sends goodbye POST" {
    printf 'REPORT_STATUS=off\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'false' ]
}

@test "REPORT_STATUS=False (capital F) sends goodbye (case-insensitive)" {
    printf 'REPORT_STATUS=False\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'false' ]
}

@test "REPORT_STATUS=false with prior false-ack skips POST (already muted)" {
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$(dirname "$INTENT_ACK")"
    printf 'false\n2026-01-01T00:00:00Z\n' > "$INTENT_ACK"
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=disabled_acked"* ]]
    [ ! -f "$COMMAND_LOG" ]
    # Ack file untouched
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'false' ]
}

@test "REPORT_STATUS=false with stale false-ack (last-success newer) still sends goodbye" {
    # Simulate the race: a previous full POST succeeded (LAST_SUCCESS
    # touched after that 2xx), but the ack-true write that should have
    # followed failed, so the ack file still says "false" from an even
    # earlier transition. Now the operator disables; the goodbye must
    # still go out so the server doesn't keep thinking diagnostics is
    # enabled.
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$(dirname "$INTENT_ACK")"
    printf 'false\n2026-01-01T00:00:00Z\n' > "$INTENT_ACK"
    # Make the ack file older than the last-success file.
    touch -d '2026-01-01T00:00:00Z' "$INTENT_ACK"
    mkdir -p "$(dirname "$LAST_SUCCESS")"
    : > "$LAST_SUCCESS"  # touch with current time → newer than INTENT_ACK
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=intent_ack_stale"* ]]
    # Goodbye payload went out.
    [ -f "$COMMAND_LOG" ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'false' ]
    # And the ack was re-written to false (with a fresh timestamp).
    [ -f "$INTENT_ACK" ]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'false' ]
}

@test "REPORT_STATUS=true with prior false-ack sends full payload and refreshes ack to true" {
    printf 'REPORT_STATUS=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$(dirname "$INTENT_ACK")"
    printf 'false\n2026-01-01T00:00:00Z\n' > "$INTENT_ACK"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'true' ]
    # Full payload includes system block
    run jq -er '.system.uptime_seconds' "$BODY_LOG"
    [ "$output" = '12345' ]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'true' ]
    [ -f "$LAST_SUCCESS" ]
}

@test "REPORT_STATUS=true with prior true-ack still sends full payload and refreshes ack" {
    printf 'REPORT_STATUS=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$(dirname "$INTENT_ACK")"
    printf 'true\n2026-01-01T00:00:00Z\n' > "$INTENT_ACK"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'true' ]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'true' ]
}

@test "REPORT_STATUS=false with prior true-ack sends goodbye and writes false ack" {
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$(dirname "$INTENT_ACK")"
    printf 'true\n2026-01-01T00:00:00Z\n' > "$INTENT_ACK"
    run_script
    [ "$status" -eq 0 ]
    [ -f "$COMMAND_LOG" ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'false' ]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'false' ]
    [ ! -f "$LAST_SUCCESS" ]
}

@test "goodbye HTTP 5xx leaves ack file untouched (retried next tick)" {
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$(dirname "$INTENT_ACK")"
    printf 'true\n2026-01-01T00:00:00Z\n' > "$INTENT_ACK"
    CURL_STATUS=503 run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=server_error"* ]]
    [[ "$output" == *"mode=goodbye"* ]]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'true' ]
}

@test "goodbye 2xx then race-flip back to enabled aborts the false ack write" {
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$(dirname "$INTENT_ACK")"
    printf 'true\n2026-01-01T00:00:00Z\n' > "$INTENT_ACK"
    # The curl stub flips REPORT_STATUS back to true while servicing the
    # POST — i.e. the operator re-enabled during the round-trip. The
    # post-POST re-check should see "enabled" and abort the ack write so
    # the next tick reconverges to a full POST.
    cat > "$STUB_DIR/curl" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\$COMMAND_LOG"
prev=''
output_file=''
for arg in "\$@"; do
    if [[ "\$prev" == "--config" && -r "\$arg" ]]; then
        cat "\$arg" >> "\$HEADER_LOG"
    fi
    if [[ "\$prev" == "--output" ]]; then
        output_file="\$arg"
    fi
    prev="\$arg"
done
cat > "\$BODY_LOG"
if [[ -n "\$output_file" ]]; then
    printf '{"ok":true}' > "\$output_file"
fi
printf 'REPORT_STATUS=true\\n' > '$ROOT_DIR/etc/airplanes/feed.env'
printf '%s' "200"
exit 0
SH
    chmod +x "$STUB_DIR/curl"
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=goodbye_aborted"* ]]
    # POST went out (goodbye payload reached the wire) but ack was NOT
    # flipped to false — still records the prior true state.
    [ -f "$COMMAND_LOG" ]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'true' ]
}

@test "REPORT_STATUS=true with missing ack file sends full payload and writes true ack" {
    printf 'REPORT_STATUS=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    [ ! -f "$INTENT_ACK" ]
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'true' ]
    [ -f "$INTENT_ACK" ]
    run head -n 1 "$INTENT_ACK"
    [ "$output" = 'true' ]
}

@test "late REPORT_STATUS=false (set mid-run) skips the POST without exiting non-zero" {
    # Simulate the operator running `apl-feed diagnostics disable` between
    # the initial REPORT_STATUS read and the POST: the systemctl stub
    # rewrites feed.env on every call. By the time the collector reaches
    # the pre-POST re-check, REPORT_STATUS has flipped to false.
    cat > "$STUB_DIR/systemctl" <<SH
#!/usr/bin/env bash
printf 'REPORT_STATUS=false\n' > '$ROOT_DIR/etc/airplanes/feed.env'
case "\$*" in
    "show airplanes-feed "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-mlat "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show dump978-fa "*) printf 'LoadState=not-found\nUnitFileState=\nActiveState=inactive\nSubState=dead\nNRestarts=0\n' ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
    run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=disabled_during_run"* ]]
    [ ! -f "$COMMAND_LOG" ]
    [ ! -f "$LAST_SUCCESS" ]
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

@test "POST body for a full report carries diagnostics_enabled=true" {
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.diagnostics_enabled' "$BODY_LOG"
    [ "$output" = 'true' ]
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

@test "POST body includes readsb when its unit is installed" {
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "show airplanes-feed "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-mlat "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show readsb "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=1\n' ;;
    "show dump978-fa "*) printf 'LoadState=not-found\nUnitFileState=\nActiveState=inactive\nSubState=dead\nNRestarts=0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
    run_script
    [ "$status" -eq 0 ]
    run jq -er '[.services[].name] | sort | join(",")' "$BODY_LOG"
    [ "$output" = 'airplanes-feed,airplanes-mlat,readsb' ]
    run jq -er '.services[] | select(.name=="readsb") | .restart_count_total' "$BODY_LOG"
    [ "$output" = '1' ]
    # readsb shares the install-time readsb_version file with airplanes-feed.
    run jq -er '.services[] | select(.name=="readsb") | .version' "$BODY_LOG"
    [ "$output" = '0a1b2c3d4e5f6a7b8c9d' ]
}

@test "POST body omits airplanes-978 when UAT_INPUT is empty" {
    # Default feed.env has REPORT_STATUS=true and no UAT_INPUT.
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "show airplanes-feed "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-mlat "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    # The collector must not even probe airplanes-978 when UAT is off —
    # if it does, this stub would emit it and the assertion below fails.
    "show airplanes-978 "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=inactive\nSubState=dead\nNRestarts=0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services | map(select(.name=="airplanes-978")) | length' "$BODY_LOG"
    [ "$output" = '0' ]
}

@test "POST body includes airplanes-978 when UAT_INPUT is set" {
    printf 'REPORT_STATUS=true\nUAT_INPUT=driver=0bda:2838,serial=978\n' \
        > "$ROOT_DIR/etc/airplanes/feed.env"
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "show airplanes-feed "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-mlat "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-978 "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services[] | select(.name=="airplanes-978") | .active_state' "$BODY_LOG"
    [ "$output" = 'active' ]
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

@test "POST body omits pi_throttle and system.ntp_synchronized when both vcgencmd and timedatectl are absent" {
    # Stub BOTH probes to fail. The dev / CI host usually ships
    # `timedatectl` (installed by systemd) and a Pi-based dev box would
    # also have `vcgencmd`; either of those leaking into this test would
    # produce a payload that contradicts the test's title.
    cat > "$STUB_DIR/vcgencmd" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$STUB_DIR/vcgencmd"
    cat > "$STUB_DIR/timedatectl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$STUB_DIR/timedatectl"
    run_script
    [ "$status" -eq 0 ]
    # pi_throttle is absent on non-Pi (no vcgencmd).
    run jq -e 'has("pi_throttle") | not' "$BODY_LOG"
    [ "$status" -eq 0 ]
    # NTP-sync absent in system block (broken timedatectl).
    run jq -e '.system | has("ntp_synchronized") | not' "$BODY_LOG"
    [ "$status" -eq 0 ]
    # Old container is gone — sentinel against accidental regressions.
    run jq -e 'has("pi_health") | not' "$BODY_LOG"
    [ "$status" -eq 0 ]
}

@test "pi_throttle survives a broken timedatectl (probes are independent)" {
    cat > "$STUB_DIR/vcgencmd" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "get_throttled" ]] && printf 'throttled=0x0\n'
SH
    chmod +x "$STUB_DIR/vcgencmd"
    cat > "$STUB_DIR/timedatectl" <<'SH'
#!/usr/bin/env bash
exit 1  # simulate a D-Bus / timedated failure
SH
    chmod +x "$STUB_DIR/timedatectl"
    run_script
    [ "$status" -eq 0 ]
    # pi_throttle bits present, all false
    run jq -er '.pi_throttle.throttled_now' "$BODY_LOG"
    [ "$output" = 'false' ]
    # NTP-sync is absent (broken probe). With separate top-level fields
    # the independence is now structural, but the sentinel stays.
    run jq -e '.system | has("ntp_synchronized") | not' "$BODY_LOG"
    [ "$status" -eq 0 ]
}

@test "POST body pi_throttle bit decode for vcgencmd=0x50005" {
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
    run jq -er '.pi_throttle.undervoltage_now' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_throttle.throttled_now' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_throttle.undervoltage_ever' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_throttle.throttled_ever' "$BODY_LOG"
    [ "$output" = 'true' ]
    run jq -er '.pi_throttle.freq_capped_now' "$BODY_LOG"
    [ "$output" = 'false' ]
    run jq -er '.pi_throttle.soft_temp_limit_ever' "$BODY_LOG"
    [ "$output" = 'false' ]
    run jq -er '.system.ntp_synchronized' "$BODY_LOG"
    [ "$output" = 'true' ]
    # Exact key-set: the server sanitizer drops the whole pi_throttle
    # block unless all 8 known keys are present. Pinning the wire shape
    # here catches an accidental drop of any one bit.
    run jq -er '.pi_throttle | keys | sort | join(",")' "$BODY_LOG"
    [ "$output" = 'freq_capped_ever,freq_capped_now,soft_temp_limit_ever,soft_temp_limit_now,throttled_ever,throttled_now,undervoltage_ever,undervoltage_now' ]
}

@test "system.ntp_synchronized is false when timedatectl reports no" {
    # Pin that `false` survives the prune pass — `_prune` strips empty
    # strings and nulls but must keep boolean false.
    cat > "$STUB_DIR/timedatectl" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "show" ]] && printf 'no\n'
SH
    chmod +x "$STUB_DIR/timedatectl"
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.system.ntp_synchronized' "$BODY_LOG"
    [ "$output" = 'false' ]
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
    [[ "$output" == *"level=warn"* ]]
    [ ! -f "$LAST_SUCCESS" ]
}

@test "HTTP 403 feeder_unclaimed downgrades to level=info status=unclaimed" {
    CURL_STATUS=403 CURL_RESPONSE='{"error":"feeder_unclaimed"}' run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"level=info"* ]]
    [[ "$output" == *"status=unclaimed"* ]]
    [[ "$output" == *"http=403"* ]]
    [[ "$output" == *"error=feeder_unclaimed"* ]]
    [[ "$output" != *"status=client_error"* ]]
    [[ "$output" != *"level=warn"* ]]
    [ ! -f "$LAST_SUCCESS" ]
}

@test "HTTP 403 with non-feeder_unclaimed body stays at level=warn status=client_error" {
    CURL_STATUS=403 CURL_RESPONSE='{"error":"signature_invalid"}' run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"level=warn"* ]]
    [[ "$output" == *"status=client_error"* ]]
    [[ "$output" == *"error=signature_invalid"* ]]
    [[ "$output" != *"status=unclaimed"* ]]
}

@test "log line carries host= tag from WEBSITE_URL" {
    APL_FEED_WEBSITE_URL='http://feed.airplanes.test:8080/v1' run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"host=feed.airplanes.test:8080"* ]]
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

# ---- daemon-published state/reason on service entries ----
#
# Helper: write a schema_version=1 state file at a rooted path.
_write_state_file() {
    local path="$1" state="$2" reason="$3"
    local rooted="$ROOT_DIR$path"
    mkdir -p "$(dirname "$rooted")"
    {
        printf 'schema_version=1\n'
        printf 'state=%s\n' "$state"
        printf 'reason=%s\n' "$reason"
    } > "$rooted"
}

@test "POST body service entry carries state=enabled,reason=ok from state file" {
    _write_state_file /run/airplanes-mlat/state enabled ok
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services[] | select(.name=="airplanes-mlat") | .state' "$BODY_LOG"
    [ "$output" = 'enabled' ]
    run jq -er '.services[] | select(.name=="airplanes-mlat") | .reason' "$BODY_LOG"
    [ "$output" = 'ok' ]
}

@test "POST body service entry carries state=disabled,reason=mlat_enabled_false" {
    _write_state_file /run/airplanes-mlat/state disabled mlat_enabled_false
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services[] | select(.name=="airplanes-mlat") | .state' "$BODY_LOG"
    [ "$output" = 'disabled' ]
    run jq -er '.services[] | select(.name=="airplanes-mlat") | .reason' "$BODY_LOG"
    [ "$output" = 'mlat_enabled_false' ]
}

@test "POST body service entry carries disabled,no_hardware for dump978-fa" {
    printf 'REPORT_STATUS=true\nUAT_INPUT=127.0.0.1:30978\n' \
        > "$ROOT_DIR/etc/airplanes/feed.env"
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "show airplanes-feed "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-mlat "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show dump978-fa "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
    _write_state_file /run/dump978-fa/state disabled no_hardware
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services[] | select(.name=="dump978-fa") | .state' "$BODY_LOG"
    [ "$output" = 'disabled' ]
    run jq -er '.services[] | select(.name=="dump978-fa") | .reason' "$BODY_LOG"
    [ "$output" = 'no_hardware' ]
}

@test "POST body omits dump978-fa when UAT_INPUT is empty" {
    # Default feed.env has REPORT_STATUS=true and no UAT_INPUT. The
    # dump978-fa unit is installed and would otherwise show as
    # inactive/dead in the payload, surfacing a stale warning chip on
    # a feeder that never opted in to UAT.
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "show airplanes-feed "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-mlat "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    # The collector must not even probe dump978-fa when UAT is off —
    # if it does, this stub would emit it and the assertion below fails.
    "show dump978-fa "*) printf 'LoadState=loaded\nUnitFileState=disabled\nActiveState=inactive\nSubState=dead\nNRestarts=0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services | map(select(.name=="dump978-fa")) | length' "$BODY_LOG"
    [ "$output" = '0' ]
}

@test "POST body omits state/reason when state file is missing" {
    # No state file → fields absent. Server falls back to systemd-only.
    run_script
    [ "$status" -eq 0 ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .state // empty' "$BODY_LOG"
    [ -z "$output" ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .reason // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body omits state/reason when schema_version is wrong" {
    local rooted="$ROOT_DIR/run/airplanes-mlat/state"
    mkdir -p "$(dirname "$rooted")"
    {
        printf 'schema_version=2\n'
        printf 'state=disabled\n'
        printf 'reason=mlat_enabled_false\n'
    } > "$rooted"
    run_script
    [ "$status" -eq 0 ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .state // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body omits state/reason on corrupt state file (no schema_version)" {
    local rooted="$ROOT_DIR/run/airplanes-mlat/state"
    mkdir -p "$(dirname "$rooted")"
    {
        printf 'state=disabled\n'
        printf 'reason=mlat_enabled_false\n'
    } > "$rooted"
    run_script
    [ "$status" -eq 0 ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .state // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body airplanes-feed has no state/reason (not plumbed)" {
    # airplanes-feed has no user-disable predicate today; the script doesn't
    # pass a state file path for it. Pinning this so a future PR doesn't
    # silently start plumbing it without a deliberate decision.
    run_script
    [ "$status" -eq 0 ]
    run jq '.services[] | select(.name=="airplanes-feed") | .state // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body airplanes-978 carries state=enabled,reason=peer_no_hardware" {
    # When UAT is configured and the local dump978-fa peer is idle (no SDR),
    # airplanes-978 publishes enabled/peer_no_hardware. The dashboard
    # classifies that as the actionable "978 peer unreachable" chip.
    printf 'REPORT_STATUS=true\nUAT_INPUT=driver=0bda:2838,serial=978\n' \
        > "$ROOT_DIR/etc/airplanes/feed.env"
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "show airplanes-feed "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-mlat "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    "show airplanes-978 "*) printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNRestarts=0\n' ;;
    *) ;;
esac
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
    _write_state_file /run/airplanes-978/state enabled peer_no_hardware
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services[] | select(.name=="airplanes-978") | .state' "$BODY_LOG"
    [ "$output" = 'enabled' ]
    run jq -er '.services[] | select(.name=="airplanes-978") | .reason' "$BODY_LOG"
    [ "$output" = 'peer_no_hardware' ]
}

@test "build_service_json uses rooted /run path (AIRPLANES_DIAGNOSTICS_ROOT honoured)" {
    # Regression guard against a future refactor that hardcodes /run/... —
    # the test seam roots everything under $ROOT_DIR, and the script must
    # route the state file path through root_path() so the seam works.
    _write_state_file /run/airplanes-mlat/state disabled geo_not_configured
    run_script
    [ "$status" -eq 0 ]
    run jq -er '.services[] | select(.name=="airplanes-mlat") | .reason' "$BODY_LOG"
    [ "$output" = 'geo_not_configured' ]
}

@test "POST body omits state/reason when state file has state but no reason" {
    # Schema-valid but orphan: only `state=` present. The publisher must
    # refuse to send half a pair — that would let the dashboard see
    # ``state=disabled`` with no reason and fall through to the catchall.
    local rooted="$ROOT_DIR/run/airplanes-mlat/state"
    mkdir -p "$(dirname "$rooted")"
    {
        printf 'schema_version=1\n'
        printf 'state=disabled\n'
    } > "$rooted"
    run_script
    [ "$status" -eq 0 ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .state // empty' "$BODY_LOG"
    [ -z "$output" ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .reason // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body omits state/reason when state file has reason but no state" {
    # Mirror of the above: orphan reason. All-or-nothing publish keeps the
    # server free of partial pairs even on schema-valid-but-corrupt files.
    local rooted="$ROOT_DIR/run/airplanes-mlat/state"
    mkdir -p "$(dirname "$rooted")"
    {
        printf 'schema_version=1\n'
        printf 'reason=mlat_enabled_false\n'
    } > "$rooted"
    run_script
    [ "$status" -eq 0 ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .state // empty' "$BODY_LOG"
    [ -z "$output" ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .reason // empty' "$BODY_LOG"
    [ -z "$output" ]
}

@test "POST body omits state/reason when state file value contains CR" {
    # state-writer.sh promises no CR in values; a CR in the on-disk file
    # is a corruption signal and must invalidate the whole record.
    local rooted="$ROOT_DIR/run/airplanes-mlat/state"
    mkdir -p "$(dirname "$rooted")"
    {
        printf 'schema_version=1\n'
        printf 'state=disabled\r\n'
        printf 'reason=mlat_enabled_false\n'
    } > "$rooted"
    run_script
    [ "$status" -eq 0 ]
    run jq '.services[] | select(.name=="airplanes-mlat") | .state // empty' "$BODY_LOG"
    [ -z "$output" ]
}
