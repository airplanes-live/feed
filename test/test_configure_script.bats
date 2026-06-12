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
    grep -qx 'GEO_CONFIGURED=true' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q '\-\-uuid-file' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q 'Invalid latitude' "$WHIPTAIL_LOG"
    ! grep -q 'Invalid longitude' "$WHIPTAIL_LOG"
}

@test "configure.sh emits GEO_CONFIGURED=false when both lat and lon are 0 (image-freeze placeholder)" {
    run_configure_env \
        AIRPLANES_MLAT_USER="image" \
        AIRPLANES_LATITUDE="0" \
        AIRPLANES_LONGITUDE="0" \
        AIRPLANES_ALTITUDE="0m"

    [ "$status" -eq 0 ]
    grep -qx 'GEO_CONFIGURED=false' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh emits GEO_CONFIGURED=true when only one axis is 0 (legitimate equator/prime-meridian)" {
    # Equator user (lat=0, lon!=0) is a real geographic case; configure.sh
    # must NOT mistake them for an image-freeze placeholder.
    run_configure_env \
        AIRPLANES_MLAT_USER="equator" \
        AIRPLANES_LATITUDE="0" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -qx 'GEO_CONFIGURED=true' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh emits GEO_CONFIGURED=false for decimal-zero pair (0.00000/0.00000)" {
    # Defensive against decimal-zero hand-edits or older callers; the
    # writer-side heuristic recognizes signed/decimal zero forms as
    # numerically zero so the pair is still treated as a placeholder.
    run_configure_env \
        AIRPLANES_MLAT_USER="image" \
        AIRPLANES_LATITUDE="0.00000" \
        AIRPLANES_LONGITUDE="0.00000" \
        AIRPLANES_ALTITUDE="0m"

    [ "$status" -eq 0 ]
    grep -qx 'GEO_CONFIGURED=false' "$ROOT_DIR/etc/airplanes/feed.env"
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
    # configure.sh now routes operator input through altitude_to_bare_metres,
    # so a `35m` env var lands on disk as bare `35`.
    grep -q 'ALTITUDE="35"' "$ROOT_DIR/etc/airplanes/feed.env"
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

@test "configure.sh build mode leaves an unset MLAT_USER empty (daemon fallback)" {
    # Mirrors the image build invocation: build mode, MLAT off, geo
    # placeholders, no name supplied. The baked default must NOT freeze
    # "Anonymous" into the image — empty MLAT_USER lets airplanes-mlat pick
    # a per-device "Anonymous-<short-id>" at runtime instead.
    run_configure_env \
        AIRPLANES_BUILD_MODE=1 \
        AIRPLANES_MLAT_ENABLED="false" \
        AIRPLANES_LATITUDE="0" \
        AIRPLANES_LONGITUDE="0" \
        AIRPLANES_ALTITUDE=""

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER=""' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'GEO_CONFIGURED=false' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'ALTITUDE=""' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="false"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh build mode still honors an explicit MLAT_USER" {
    run_configure_env \
        AIRPLANES_BUILD_MODE=1 \
        AIRPLANES_MLAT_USER="ci-feeder" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="ci-feeder"' "$ROOT_DIR/etc/airplanes/feed.env"
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

@test "configure.sh: interactive flow defaults MLAT_PRIVATE=false" {
    run_configure $'ci-feeder\n52.52000\n13.40500\n35m'

    [ "$status" -eq 0 ]
    grep -qx 'MLAT_PRIVATE=false' "$ROOT_DIR/etc/airplanes/feed.env"
    # Comment from the legacy flow that taught operators to hand-edit
    # PRIVACY="--privacy" must not reappear.
    ! grep -q 'add --privacy between the quotes' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q '^PRIVACY=' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh: noninteractive AIRPLANES_MLAT_PRIVATE=true honored" {
    run_configure_env \
        AIRPLANES_MLAT_USER="alice" \
        AIRPLANES_MLAT_PRIVATE="true" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -qx 'MLAT_PRIVATE=true' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh: noninteractive AIRPLANES_MLAT_PRIVATE defaults to false" {
    run_configure_env \
        AIRPLANES_MLAT_USER="alice" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -qx 'MLAT_PRIVATE=false' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh: noninteractive AIRPLANES_MLAT_PRIVATE rejects bogus value" {
    run_configure_env \
        AIRPLANES_MLAT_USER="alice" \
        AIRPLANES_MLAT_PRIVATE="probably" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "AIRPLANES_MLAT_PRIVATE must be 'true' or 'false'" ]]
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "configure.sh: AIRPLANES_MLAT_PRIVATE alone triggers non-interactive mode" {
    run_configure_env AIRPLANES_MLAT_PRIVATE="true"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Missing required non-interactive configure value: AIRPLANES_LATITUDE" ]]
    [ ! -e "$WHIPTAIL_LOG" ]
}

## Preservation on re-run (feed#131): write_feed_env must not clobber
## operator data it doesn't own.

seed_feed_env() {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    cat > "$ROOT_DIR/etc/airplanes/feed.env"
}

rerun_coords_only() {
    run_configure_env \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"
}

@test "configure.sh re-run carries unowned keys over verbatim" {
    seed_feed_env <<'EOF'
LATITUDE="50.00000"
LONGITUDE="8.00000"
ALTITUDE="100"
MLAT_USER="alice"
TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"
MLATSERVER="feed.airplanes.test:31090"
APL_FEED_WEBSITE_URL="https://airplanes.test"
REPORT_STATUS="false"
GAIN="auto"
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    local env_file="$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"' "$env_file"
    grep -qx 'MLATSERVER="feed.airplanes.test:31090"' "$env_file"
    grep -qx 'APL_FEED_WEBSITE_URL="https://airplanes.test"' "$env_file"
    grep -qx 'REPORT_STATUS="false"' "$env_file"
    grep -qx 'GAIN="auto"' "$env_file"
    grep -q 'Carried over from the previous feed.env' "$env_file"
    # New coordinates landed; owned keys are not duplicated by carry-over.
    grep -q 'LATITUDE="52.52000"' "$env_file"
    [ "$(grep -c '^LATITUDE=' "$env_file")" -eq 1 ]
    [ "$(grep -c '^MLAT_USER=' "$env_file")" -eq 1 ]
}

@test "configure.sh re-run keeps duplicate unowned lines in order" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
GAIN="auto"
GAIN="42"
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    # Both occurrences survive, original order (source last-write-wins).
    [ "$(grep -c '^GAIN=' "$ROOT_DIR/etc/airplanes/feed.env")" -eq 2 ]
    grep -A1 '^GAIN="auto"' "$ROOT_DIR/etc/airplanes/feed.env" | grep -qx 'GAIN="42"'
}

@test "configure.sh re-run does not carry comments or non-KEY= lines" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
# operator note about the override below
TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"
export SHELLISH=1
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    grep -qx 'TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q 'operator note about the override' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q 'SHELLISH' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh re-run twice is idempotent (byte-identical file)" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"
REPORT_STATUS="false"
EOF
    rerun_coords_only
    [ "$status" -eq 0 ]
    cp "$ROOT_DIR/etc/airplanes/feed.env" "$ROOT_DIR/first-pass"

    rerun_coords_only
    [ "$status" -eq 0 ]
    cmp "$ROOT_DIR/first-pass" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh fresh install writes no carried-over section" {
    rerun_coords_only

    [ "$status" -eq 0 ]
    ! grep -q 'Carried over from the previous feed.env' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh re-run preserves MLAT_ENABLED=false and MLAT_PRIVATE=true" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_ENABLED="false"
MLAT_PRIVATE=true
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    grep -q 'MLAT_ENABLED="false"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_PRIVATE=true' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh interactive re-run preserves MLAT toggles and name on blank input" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_USER="keepme"
MLAT_ENABLED="false"
MLAT_PRIVATE=true
EOF
    run_configure $'\n52.52000\n13.40500\n35m'

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="keepme"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q 'MLAT_ENABLED="false"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_PRIVATE=true' "$ROOT_DIR/etc/airplanes/feed.env"
    # The name prompt advertises keep-current semantics on a re-run.
    grep -q 'keep the current name "keepme"' "$WHIPTAIL_LOG"
}

@test "configure.sh interactive re-run: explicit name input still wins" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_USER="keepme"
EOF
    run_configure $'newname\n52.52000\n13.40500\n35m'

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="newname"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh explicit AIRPLANES_MLAT_ENABLED=true overrides preserved false" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_ENABLED="false"
EOF
    run_configure_env \
        AIRPLANES_MLAT_ENABLED="true" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh empty AIRPLANES_MLAT_ENABLED preserves the existing value" {
    # Set-but-empty means "no explicit choice" — same as unset.
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_ENABLED="false"
EOF
    run_configure_env \
        AIRPLANES_MLAT_ENABLED="" \
        AIRPLANES_LATITUDE="52.52000" \
        AIRPLANES_LONGITUDE="13.40500" \
        AIRPLANES_ALTITUDE="35m"

    [ "$status" -eq 0 ]
    grep -q 'MLAT_ENABLED="false"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh re-run: invalid existing toggle falls back to default" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_ENABLED="banana"
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh re-run: quoted toggle with trailing comment falls back to default" {
    # `MLAT_ENABLED="false" # note` doesn't match any strict read form
    # (the bare rule captures the opening quote), so preservation
    # refuses it and the default applies. Pinned: this is the parser
    # behavior that makes same-line comments a forbidden shape.
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_ENABLED="false" # operator note
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    grep -q 'MLAT_ENABLED="true"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh re-run preserves a custom INPUT/INPUT_TYPE" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
INPUT="192.168.1.10:30005"
INPUT_TYPE="dump1090"
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    grep -qx 'INPUT="192.168.1.10:30005"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'INPUT_TYPE="dump1090"' "$ROOT_DIR/etc/airplanes/feed.env"
    [ "$(grep -c '^INPUT=' "$ROOT_DIR/etc/airplanes/feed.env")" -eq 1 ]
}

@test "configure.sh re-run preserves MLAT_USER when no name is supplied" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
MLAT_USER="keepme"
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    grep -q 'MLAT_USER="keepme"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "configure.sh build mode with pre-existing overrides preserves them, no sidecar" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"
EOF
    run_configure_env \
        AIRPLANES_BUILD_MODE=1 \
        AIRPLANES_LATITUDE="0" \
        AIRPLANES_LONGITUDE="0" \
        AIRPLANES_ALTITUDE=""

    [ "$status" -eq 0 ]
    grep -qx 'TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"' "$ROOT_DIR/etc/airplanes/feed.env"
    # Build mode is not an operator edit — no metadata stamps.
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
}

@test "configure.sh stamps sidecar metadata for changed tracked keys only" {
    seed_feed_env <<'EOF'
LATITUDE="50.00000"
LONGITUDE="8.00000"
ALTITUDE="35"
MLAT_USER="alice"
MLAT_ENABLED="false"
MLAT_PRIVATE=false
EOF
    cat > "$ROOT_DIR/etc/airplanes/feed.meta.json" <<'EOF'
{"schema_version":1,"fields":{"MLAT_USER":{"edited_at":"2026-01-01T00:00:00.000000Z","edited_by":"website"}}}
EOF
    rerun_coords_only

    [ "$status" -eq 0 ]
    local meta="$ROOT_DIR/etc/airplanes/feed.meta.json"
    # Coordinates changed → fresh feeder stamps.
    [ "$(jq -r '.fields.LATITUDE.edited_by' "$meta")" = "feeder" ]
    [ "$(jq -r '.fields.LATITUDE.edited_at' "$meta")" != "2026-01-01T00:00:00.000000Z" ]
    # MLAT_USER unchanged (preserved) → existing website tuple kept.
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$meta")" = "website" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$meta")" = "2026-01-01T00:00:00.000000Z" ]
    # MLAT_ENABLED preserved unchanged → no stamp materializes.
    [ "$(jq -r '.fields.MLAT_ENABLED' "$meta")" = "null" ]
}

@test "configure.sh carried keys survive a subsequent apl_feed_apply write" {
    seed_feed_env <<'EOF'
LATITUDE="50.0"
LONGITUDE="8.0"
ALTITUDE="100"
TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"
EOF
    rerun_coords_only
    [ "$status" -eq 0 ]

    # Run the canonical key-level writer over the rewritten file the way
    # apl-feed diagnostics/config would; the carried TARGET value must
    # survive (apply normalizes formatting but keeps the value).
    mkdir -p "$ROOT_DIR/run/airplanes"
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../scripts/lib/configure-validators.sh"
        source "'"$BATS_TEST_DIRNAME"'/../scripts/lib/feed-env-keys.sh"
        source "'"$BATS_TEST_DIRNAME"'/../scripts/lib/feed-env-apply.sh"
        apl_feed_apply --no-restart --no-audit \
            --feed-env "'"$ROOT_DIR"'/etc/airplanes/feed.env" \
            --lock-file "'"$ROOT_DIR"'/run/airplanes/feed-env.lock" \
            REPORT_STATUS=false
    '
    [ "$status" -eq 0 ]
    grep -qx 'TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'REPORT_STATUS="false"' "$ROOT_DIR/etc/airplanes/feed.env"
}
