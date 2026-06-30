#!/usr/bin/env bats

# Per-module unit tests for scripts/apl-feed/id.sh.
#
# id_set malformed-input rejection, --force semantics, and --dry-run
# are covered end-to-end in test_apl_feed_cli.bats — not duplicated
# here. This file isolates dispatch_id and id_set boundary cases that
# the CLI suite skips.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    STUB_DIR="$ROOT_DIR/bin"
    mkdir -p "$TMPDIR" "$STUB_DIR" \
        "$ROOT_DIR/etc/airplanes" \
        "$ROOT_DIR/var/lib/airplanes/runtime"
    export TMPDIR
    APL_FEED_SECRET_OWNER="$(id -un)"
    APL_FEED_SECRET_GROUP="$(id -gn)"
    export APL_FEED_SECRET_OWNER APL_FEED_SECRET_GROUP

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/id.sh
    source "$LIB_DIR/id.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    # Track every systemctl invocation to a log so we can assert
    # whether a restart was attempted.
    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$ROOT_DIR/systemctl.log"
case "\$1" in
    is-active|is-enabled) exit 0 ;;
    restart) exit 0 ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# --- dispatch_id ---

@test "dispatch_id: missing subcommand shows id help (exit 2)" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        dispatch_id
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed id <subcommand>'* ]]
}

@test "dispatch_id: unknown subcommand dies" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        dispatch_id frobnitz
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'unknown id subcommand: frobnitz'* ]]
}

@test "dispatch_id: -h prints usage and exits 0" {
    run bash -c "
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        dispatch_id -h
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *'Usage:'* ]]
}

# --- id_set boundaries ---

@test "id_set: empty stdin dies" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        ROOT='$ROOT_DIR'
        printf '' | id_set
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'no input provided'* ]]
}

@test "id_set: stdin with trailing whitespace canonicalizes correctly" {
    UUID='11111111-2222-3333-4444-555555555555'
    run bash -c "
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        ROOT='$ROOT_DIR'
        printf '%s\n   \n' '$UUID' | id_set --root '$ROOT_DIR'
    "
    [ "$status" -eq 0 ]
    saved="$(cat "$ROOT_DIR/etc/airplanes/feeder-id")"
    [ "$saved" = "$UUID" ]
}

@test "id_set: --root != / skips restart even when systemctl available" {
    UUID='11111111-2222-3333-4444-555555555555'
    run bash -c "
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        printf '%s\n' '$UUID' | id_set --root '$ROOT_DIR'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *'Skipping service restart'* ]]
    if [[ -f "$ROOT_DIR/systemctl.log" ]]; then
        ! grep -q 'systemctl restart' "$ROOT_DIR/systemctl.log"
    fi
}

@test "id_set: existing UUID matches input — already matches, no restart" {
    UUID='11111111-2222-3333-4444-555555555555'
    printf '%s\n' "$UUID" > "$ROOT_DIR/etc/airplanes/feeder-id"
    run bash -c "
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        printf '%s\n' '$UUID' | id_set --root '$ROOT_DIR'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *'already matches'* ]]
    if [[ -f "$ROOT_DIR/systemctl.log" ]]; then
        ! grep -q 'systemctl restart' "$ROOT_DIR/systemctl.log"
    fi
}

@test "id_set: existing UUID matches but uppercase normalizes to lowercase" {
    UUID_LOWER='11111111-2222-3333-4444-555555555555'
    UUID_UPPER='11111111-2222-3333-4444-AAAAAAAAAAAA'
    UUID_NORM='11111111-2222-3333-4444-aaaaaaaaaaaa'
    # Pre-populate uppercase; supply lowercase via stdin (different
    # byte-form, same canonical value should hit "already matches"
    # — but uppercase != lowercase canonical, so this is the rejection
    # branch, not the normalize branch. Use the same canonical value
    # to exercise the normalize-in-place branch.
    printf '%s\n' "$UUID_UPPER" > "$ROOT_DIR/etc/airplanes/feeder-id"
    run bash -c "
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/id.sh'
        printf '%s\n' '$UUID_NORM' | id_set --root '$ROOT_DIR'
    "
    [ "$status" -eq 0 ]
    saved="$(cat "$ROOT_DIR/etc/airplanes/feeder-id")"
    [ "$saved" = "$UUID_NORM" ]
}
