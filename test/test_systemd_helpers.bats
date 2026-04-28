#!/usr/bin/env bats
# Tests for is_unit_masked, defined in scripts/lib/systemd-helpers.sh.
# Stubs `systemctl` via PATH manipulation so the function is exercised
# against deterministic synthetic output rather than the host's real
# systemd state.

setup() {
    STUB_DIR="$(mktemp -d)"
    STUB_OUTPUT_FILE="$(mktemp)"
    STUB_ARGS_FILE="$(mktemp)"

    # Tiny systemctl shim. Records its argv to $STUB_ARGS_FILE so a test
    # can assert how the helper invoked it. Emits the contents of
    # $STUB_OUTPUT_FILE on stdout (empty file → no output, mirroring the
    # "unit not found" case where real systemctl errors with empty stdout).
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/bin/bash
echo "$@" >> "${STUB_ARGS_FILE:-/dev/null}"
[[ -n "${STUB_OUTPUT_FILE:-}" && -s "${STUB_OUTPUT_FILE}" ]] && cat "${STUB_OUTPUT_FILE}"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    PATH="$STUB_DIR:$PATH"
    export PATH STUB_OUTPUT_FILE STUB_ARGS_FILE

    # shellcheck source=../scripts/lib/systemd-helpers.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/systemd-helpers.sh"
}

teardown() {
    rm -rf "$STUB_DIR"
    rm -f "$STUB_OUTPUT_FILE" "$STUB_ARGS_FILE"
}

@test "is_unit_masked returns 0 when systemctl reports masked" {
    echo masked > "$STUB_OUTPUT_FILE"
    run is_unit_masked airplanes-mlat.service
    [ "$status" -eq 0 ]
}

@test "is_unit_masked returns non-zero when systemctl reports enabled" {
    echo enabled > "$STUB_OUTPUT_FILE"
    run is_unit_masked airplanes-mlat.service
    [ "$status" -ne 0 ]
}

@test "is_unit_masked returns non-zero when systemctl reports disabled" {
    echo disabled > "$STUB_OUTPUT_FILE"
    run is_unit_masked airplanes-mlat.service
    [ "$status" -ne 0 ]
}

@test "is_unit_masked returns non-zero when systemctl produces no output" {
    # Mirrors the case where the unit doesn't exist and real systemctl
    # exits non-zero with empty stdout — the function compares "" against
    # "masked" and returns false.
    : > "$STUB_OUTPUT_FILE"
    run is_unit_masked nonexistent.service
    [ "$status" -ne 0 ]
}

@test "is_unit_masked invokes systemctl is-enabled with the unit name" {
    echo masked > "$STUB_OUTPUT_FILE"
    run is_unit_masked airplanes-feed.service
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_ARGS_FILE")" = "is-enabled airplanes-feed.service" ]
}
