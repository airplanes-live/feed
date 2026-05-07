#!/usr/bin/env bats

# Stubbed UUID returned by the cat shim when create-uuid.sh reads
# /proc/sys/kernel/random/uuid. Lets generation tests assert exact equality
# instead of just regex shape.
STUB_UUID="11111111-2222-3333-4444-555555555555"
VALID_UUID_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
VALID_UUID_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
VALID_UUID_C="cccccccc-cccc-cccc-cccc-cccccccccccc"

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../create-uuid.sh"
    HELPER="$BATS_TEST_DIRNAME/../scripts/lib/install-update-common.sh"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    mkdir -p "$STUB_DIR"

    # Resolve the same path variables the script does so tests don't hardcode
    # them.
    export AIRPLANES_ROOT="$ROOT_DIR"
    # shellcheck source=../scripts/lib/install-update-common.sh
    source "$HELPER"
    airplanes_init_paths

    # Determinism: replace generate_uuid's two `sleep 0.$RANDOM` waits with
    # no-ops, and short-circuit the /proc UUID read to a known value. cat is
    # stubbed for that one path and delegates everything else to /bin/cat.
    cat > "$STUB_DIR/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$STUB_DIR/sleep"

    cat > "$STUB_DIR/cat" <<SH
#!/usr/bin/env bash
if [[ "\$1" == "/proc/sys/kernel/random/uuid" ]]; then
    printf '%s\\n' "$STUB_UUID"
    exit 0
fi
exec /bin/cat "\$@"
SH
    chmod +x "$STUB_DIR/cat"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Run create-uuid.sh with the stub PATH and AIRPLANES_BUILD_MODE explicitly
# unset so an inherited shell value never silently routes a non-build-mode
# test through the skip branch.
run_create_uuid() {
    run env -u AIRPLANES_BUILD_MODE \
        PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR" \
        bash "$SCRIPT" "$@"
}

write_uuid_source() {
    local file="$1"
    local content="$2"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$content" > "$file"
}

file_mode() {
    stat -c '%a' "$1"
}

@test "--build-mode skips per-device generation and leaves source files untouched" {
    write_uuid_source "$FEEDER_ID_FILE" "garbage-not-a-uuid"
    write_uuid_source "$LEGACY_UUID_FILE" "$VALID_UUID_A"
    write_uuid_source "$BOOT_UUID_FILE" "$VALID_UUID_B"

    run_create_uuid --build-mode

    [ "$status" -eq 0 ]
    [[ "$output" == *"Build mode: skipping"* ]]
    [ "$(cat "$FEEDER_ID_FILE")" = "garbage-not-a-uuid" ]
    [ "$(cat "$LEGACY_UUID_FILE")" = "$VALID_UUID_A" ]
    [ "$(cat "$BOOT_UUID_FILE")" = "$VALID_UUID_B" ]
    [ ! -L "$LEGACY_UUID_FILE" ]
}

@test "generates a new UUID when no source file exists" {
    run_create_uuid

    [ "$status" -eq 0 ]
    [ -f "$FEEDER_ID_FILE" ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$STUB_UUID" ]
    [ "$(file_mode "$FEEDER_ID_FILE")" = "644" ]
    [ -L "$LEGACY_UUID_FILE" ]
    [[ "$output" == *"New Feeder ID: $STUB_UUID"* ]]
    # write_feeder_id uses "$FEEDER_ID_FILE.$$" as a temp before mv -f. After a
    # successful rename, no feeder-id.* siblings should remain.
    ! ls "$ETC_AIRPLANES"/feeder-id.* >/dev/null 2>&1
}

@test "reuses a valid existing UUID from FEEDER_ID_FILE" {
    write_uuid_source "$FEEDER_ID_FILE" "$VALID_UUID_A"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$VALID_UUID_A" ]
    [[ "$output" == *"Using existing valid Feeder ID ($VALID_UUID_A) from $FEEDER_ID_FILE"* ]]
}

@test "reuses LEGACY_UUID_FILE and replaces it with a symlink to FEEDER_ID_FILE" {
    write_uuid_source "$LEGACY_UUID_FILE" "$VALID_UUID_A"
    [ ! -L "$LEGACY_UUID_FILE" ]

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$VALID_UUID_A" ]
    [ -L "$LEGACY_UUID_FILE" ]
    [ "$(readlink "$LEGACY_UUID_FILE")" = "../../../../etc/airplanes/feeder-id" ]
}

@test "reuses BOOT_UUID_FILE as the lowest-priority fallback" {
    write_uuid_source "$BOOT_UUID_FILE" "$VALID_UUID_A"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$VALID_UUID_A" ]
    [[ "$output" == *"from $BOOT_UUID_FILE"* ]]
}

@test "FEEDER_ID_FILE wins over LEGACY_UUID_FILE and BOOT_UUID_FILE" {
    write_uuid_source "$FEEDER_ID_FILE" "$VALID_UUID_A"
    write_uuid_source "$LEGACY_UUID_FILE" "$VALID_UUID_B"
    write_uuid_source "$BOOT_UUID_FILE" "$VALID_UUID_C"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$VALID_UUID_A" ]
}

@test "invalid FEEDER_ID_FILE falls through to LEGACY_UUID_FILE" {
    write_uuid_source "$FEEDER_ID_FILE" "not-a-uuid-at-all"
    write_uuid_source "$LEGACY_UUID_FILE" "$VALID_UUID_B"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$VALID_UUID_B" ]
    [[ "$output" == *"WARNING: Data in UUID file $FEEDER_ID_FILE was invalid"* ]]
}

@test "invalid FEEDER_ID_FILE and LEGACY_UUID_FILE fall through to BOOT_UUID_FILE" {
    write_uuid_source "$FEEDER_ID_FILE" "garbage-1"
    write_uuid_source "$LEGACY_UUID_FILE" "garbage-2"
    write_uuid_source "$BOOT_UUID_FILE" "$VALID_UUID_C"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$VALID_UUID_C" ]
    [[ "$output" == *"WARNING: Data in UUID file $FEEDER_ID_FILE was invalid"* ]]
    [[ "$output" == *"WARNING: Data in UUID file $LEGACY_UUID_FILE was invalid"* ]]
}

@test "invalid in every source triggers fresh generation with the stubbed UUID" {
    write_uuid_source "$FEEDER_ID_FILE" "garbage-1"
    write_uuid_source "$LEGACY_UUID_FILE" "garbage-2"
    write_uuid_source "$BOOT_UUID_FILE" "garbage-3"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "$STUB_UUID" ]
    [[ "$output" == *"WARNING: Data in UUID file $FEEDER_ID_FILE was invalid"* ]]
    [[ "$output" == *"WARNING: Data in UUID file $LEGACY_UUID_FILE was invalid"* ]]
    [[ "$output" == *"WARNING: Data in UUID file $BOOT_UUID_FILE was invalid"* ]]
    [[ "$output" == *"No valid Feeder ID found"* ]]
}

@test "normalize_uuid strips uppercase and surrounding braces" {
    write_uuid_source "$FEEDER_ID_FILE" "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]
}

@test "normalize_uuid is permissive: embedded braces are stripped (current behavior)" {
    # tr -d '{}' is unanchored, so a stray brace anywhere in the source gets
    # silently removed and the result still passes valid_uuid. Locked in as a
    # behavior-documenting test, not an endorsement.
    write_uuid_source "$FEEDER_ID_FILE" "aaaa{aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    run_create_uuid

    [ "$status" -eq 0 ]
    [ "$(cat "$FEEDER_ID_FILE")" = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]
}
