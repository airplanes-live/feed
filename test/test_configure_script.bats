#!/usr/bin/env bats

setup() {
    CONFIGURE="$BATS_TEST_DIRNAME/../configure.sh"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    mkdir -p "$STUB_DIR"
    WHIPTAIL_LOG="$ROOT_DIR/whiptail.log"
    WHIPTAIL_COUNTER="$ROOT_DIR/whiptail-counter"
    write_whiptail_stub
}

teardown() {
    rm -rf "$ROOT_DIR"
}

write_whiptail_stub() {
    cat > "$STUB_DIR/whiptail" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'whiptail %s\n' "$*" >> "$WHIPTAIL_LOG"

if printf '%s\n' "$@" | grep -q -- '--yesno'; then
    exit 0
fi

if printf '%s\n' "$@" | grep -q -- '--inputbox'; then
    n=0
    [[ -f "$WHIPTAIL_COUNTER" ]] && n="$(cat "$WHIPTAIL_COUNTER")"
    n=$((n + 1))
    printf '%s\n' "$n" > "$WHIPTAIL_COUNTER"
    value="$(printf '%s' "$WHIPTAIL_INPUTS" | sed -n "${n}p")"
    printf '%s\n' "$value" >&2
    exit 0
fi

# --msgbox and anything else: succeed silently (already logged above).
exit 0
SH
    chmod +x "$STUB_DIR/whiptail"
}

run_configure() {
    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR" \
        WHIPTAIL_LOG="$WHIPTAIL_LOG" \
        WHIPTAIL_COUNTER="$WHIPTAIL_COUNTER" \
        WHIPTAIL_INPUTS="$1" \
        bash "$CONFIGURE"
}

run_configure_env() {
    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR" \
        WHIPTAIL_LOG="$WHIPTAIL_LOG" \
        WHIPTAIL_COUNTER="$WHIPTAIL_COUNTER" \
        "$@" \
        bash "$CONFIGURE"
}

@test "configure.sh accepts canonical decimal latitude and longitude" {
    run_configure $'ci-feeder\n52.52000\n13.40500\n35m'

    [ "$status" -eq 0 ]
    grep -q 'LATITUDE="52.52000"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'LONGITUDE="13.40500"' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q '\-\-uuid-file' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q 'Invalid latitude' "$WHIPTAIL_LOG"
    ! grep -q 'Invalid longitude' "$WHIPTAIL_LOG"
}

@test "configure.sh rejects non-numeric latitude with Invalid msgbox" {
    run_configure $'ci-feeder\nabc\n52.52000\n13.40500\n35m'

    [ "$status" -eq 0 ]
    # The "Invalid latitude" msgbox fired during the syntax-invalid attempt.
    grep -q 'Invalid latitude' "$WHIPTAIL_LOG"
    # Final value is the valid one, not "abc".
    grep -q 'LATITUDE="52.52000"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh rejects non-numeric longitude with Invalid msgbox" {
    run_configure $'ci-feeder\n52.52000\nbad\n13.40500\n35m'

    [ "$status" -eq 0 ]
    grep -q 'Invalid longitude' "$WHIPTAIL_LOG"
    grep -q 'LONGITUDE="13.40500"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh accepts +signed latitude (regex broadened in F11 fix)" {
    run_configure $'ci-feeder\n+52.52\n13.40500\n35m'

    [ "$status" -eq 0 ]
    grep -q 'LATITUDE="+52.52"' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q 'Invalid latitude' "$WHIPTAIL_LOG"
}

@test "configure.sh re-prompts silently on out-of-range latitude (regex passes, awk rejects)" {
    # 91.0 passes the syntax regex but fails the awk range check; the loop
    # continues without firing the "Invalid latitude" msgbox.
    run_configure $'ci-feeder\n91.0\n52.52000\n13.40500\n35m'

    [ "$status" -eq 0 ]
    ! grep -q 'Invalid latitude' "$WHIPTAIL_LOG"
    grep -q 'LATITUDE="52.52000"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh re-prompts silently on out-of-range longitude" {
    run_configure $'ci-feeder\n52.52000\n181.0\n13.40500\n35m'

    [ "$status" -eq 0 ]
    ! grep -q 'Invalid longitude' "$WHIPTAIL_LOG"
    grep -q 'LONGITUDE="13.40500"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh writes feed.env from non-interactive env without whiptail" {
    run_configure_env \
        AIRPLANES_MLAT_USER="ci feeder" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="ci feeder"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q '^USER=' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'LATITUDE="52.52000"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'LONGITUDE="13.40500"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'ALTITUDE="35m"' "$ROOT_DIR/etc/airplanes/feed.env"
    [ ! -e "$WHIPTAIL_LOG" ]
}

@test "configure.sh fails non-interactive mode when required env is partial" {
    run_configure_env \
        AIRPLANES_MLAT_USER="ci-feeder" \
        AIRPLANES_LATITUDE="52.52000"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Missing required non-interactive configure value: AIRPLANES_LONGITUDE" ]]
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]
    [ ! -e "$WHIPTAIL_LOG" ]
}

@test "configure.sh fails build mode instead of prompting when config env is missing" {
    run_configure_env AIRPLANES_BUILD_MODE=1

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Missing required non-interactive configure value" ]]
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]
    [ ! -e "$WHIPTAIL_LOG" ]
}

@test "configure.sh rejects invalid non-interactive latitude" {
    run_configure_env \
        AIRPLANES_MLAT_USER="ci-feeder" \
        AIRPLANES_LATITUDE="north" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Latitude must be a decimal number" ]]
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "configure.sh empty AIRPLANES_MLAT_USER falls back to Anonymous" {
    run_configure_env \
        AIRPLANES_MLAT_USER="" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="Anonymous"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh unset AIRPLANES_MLAT_USER also falls back to Anonymous" {
    # Triggering non-interactive via AIRPLANES_LATITUDE; MLAT_USER is unset.
    run_configure_env \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="Anonymous"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh AIRPLANES_MLAT_ENABLED=false preserves the supplied name" {
    run_configure_env \
        AIRPLANES_MLAT_USER="alice" \
        AIRPLANES_MLAT_ENABLED="false" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="alice"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="false"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh AIRPLANES_MLAT_ENABLED=false plus empty user still fills Anonymous" {
    run_configure_env \
        AIRPLANES_MLAT_USER="" \
        AIRPLANES_MLAT_ENABLED="false" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="Anonymous"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="false"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh AIRPLANES_MLAT_ENABLED with bogus value rejects with documented message" {
    run_configure_env \
        AIRPLANES_MLAT_USER="alice" \
        AIRPLANES_MLAT_ENABLED="probably" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "AIRPLANES_MLAT_ENABLED must be 'true' or 'false'" ]]
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "configure.sh AIRPLANES_MLAT_USER=0 is now a literal username (sentinel dropped)" {
    # Contract change: pre-migration this would have disabled MLAT.
    # Now it's a regular name and MLAT stays enabled.
    run_configure_env \
        AIRPLANES_MLAT_USER="0" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="0"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh AIRPLANES_MLAT_ENABLED alone triggers non-interactive mode" {
    # Even with no other AIRPLANES_* vars set, AIRPLANES_MLAT_ENABLED on
    # its own should make has_noninteractive_config_env return true.
    # Required lat/lon/alt are then missing, so this exits 1 with the
    # standard "Missing required" error — proving has_noninteractive
    # recognized AIRPLANES_MLAT_ENABLED.
    run_configure_env AIRPLANES_MLAT_ENABLED="false"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Missing required non-interactive configure value: AIRPLANES_LATITUDE" ]]
    [ ! -e "$WHIPTAIL_LOG" ]
}

@test "configure.sh interactive: empty MLAT name input writes Anonymous" {
    # The first interactive inputbox (name) gets an empty line. The flow
    # falls back to DEFAULT_MLAT_NAME on disk.
    run_configure $'\n52.52000\n13.40500\n35m'

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="Anonymous"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
}
