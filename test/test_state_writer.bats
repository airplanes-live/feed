#!/usr/bin/env bats

# Unit tests for scripts/lib/state-writer.sh. The writer is the
# foundation for the daemon-owned runtime state-file pattern; bugs
# here ripple into every consumer (apl-feed status, render-status,
# webconfig).

setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/lib/state-writer.sh"
    ROOT_DIR="$(mktemp -d)"
    TARGET="$ROOT_DIR/state"
    # shellcheck source=../scripts/lib/state-writer.sh
    source "$LIB"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# --- Happy path ---

@test "writes schema_version=1 as first line" {
    airplanes_write_state "$TARGET" service=test
    head -n 1 "$TARGET" | grep -qx 'schema_version=1'
}

@test "subsequent lines are KEY=VALUE in caller-provided order" {
    airplanes_write_state "$TARGET" \
        service=airplanes-mlat \
        state=enabled \
        reason=ok \
        latitude=52.520
    run cat "$TARGET"
    [ "${lines[0]}" = 'schema_version=1' ]
    [ "${lines[1]}" = 'service=airplanes-mlat' ]
    [ "${lines[2]}" = 'state=enabled' ]
    [ "${lines[3]}" = 'reason=ok' ]
    [ "${lines[4]}" = 'latitude=52.520' ]
}

@test "empty value writes empty RHS" {
    airplanes_write_state "$TARGET" mlat_user= state=disabled
    grep -qx 'mlat_user=' "$TARGET"
    grep -qx 'state=disabled' "$TARGET"
}

@test "value with internal spaces is preserved verbatim" {
    airplanes_write_state "$TARGET" "input=127.0.0.1:30005 dump1090"
    grep -qx 'input=127.0.0.1:30005 dump1090' "$TARGET"
}

@test "value with shell metacharacters is preserved verbatim (writer never quotes)" {
    # readers parse by line, never source — these are safe in the file.
    airplanes_write_state "$TARGET" 'feed_bin=/usr/bin/x$(`)"\;&|<>'
    grep -qFx 'feed_bin=/usr/bin/x$(`)"\;&|<>' "$TARGET"
}

@test "mode of resulting file is 0644" {
    airplanes_write_state "$TARGET" service=test
    perms="$(stat -c '%a' "$TARGET" 2>/dev/null || stat -f '%Lp' "$TARGET")"
    [ "$perms" = '644' ]
}

# --- Validation: target unchanged on every failure path ---

@test "rejects value with newline; target unchanged" {
    printf 'schema_version=1\nservice=previous\n' > "$TARGET"
    chmod 0644 "$TARGET"
    run airplanes_write_state "$TARGET" "input=foo
bar"
    [ "$status" -eq 1 ]
    [[ "$output" == *'CR/LF'* ]]
    grep -qx 'service=previous' "$TARGET"
}

@test "rejects value with carriage return; target unchanged" {
    printf 'schema_version=1\nservice=previous\n' > "$TARGET"
    run airplanes_write_state "$TARGET" "input=foo"$'\r'"bar"
    [ "$status" -eq 1 ]
    [[ "$output" == *'CR/LF'* ]]
    grep -qx 'service=previous' "$TARGET"
}

@test "rejects arg without =; target unchanged" {
    printf 'schema_version=1\nservice=previous\n' > "$TARGET"
    run airplanes_write_state "$TARGET" 'no_equals_sign'
    [ "$status" -eq 1 ]
    [[ "$output" == *'not KEY=VALUE'* ]]
    grep -qx 'service=previous' "$TARGET"
}

@test "rejects key starting with digit; target unchanged" {
    printf 'schema_version=1\n' > "$TARGET"
    run airplanes_write_state "$TARGET" '1bad=value'
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid key'* ]]
    [ "$(cat "$TARGET")" = 'schema_version=1' ]
}

@test "rejects key containing dash; target unchanged" {
    printf 'schema_version=1\n' > "$TARGET"
    run airplanes_write_state "$TARGET" 'bad-key=value'
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid key'* ]]
    [ "$(cat "$TARGET")" = 'schema_version=1' ]
}

@test "rejects empty key; target unchanged" {
    printf 'schema_version=1\n' > "$TARGET"
    run airplanes_write_state "$TARGET" '=value'
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid key'* ]]
}

@test "rejects caller-supplied schema_version=1; target unchanged" {
    printf 'schema_version=1\nservice=previous\n' > "$TARGET"
    run airplanes_write_state "$TARGET" schema_version=1
    [ "$status" -eq 1 ]
    [[ "$output" == *'caller-supplied schema_version'* ]]
    grep -qx 'service=previous' "$TARGET"
}

@test "rejects caller-supplied schema_version=2; target unchanged" {
    printf 'schema_version=1\nservice=previous\n' > "$TARGET"
    run airplanes_write_state "$TARGET" schema_version=2 service=test
    [ "$status" -eq 1 ]
    [[ "$output" == *'caller-supplied schema_version'* ]]
    grep -qx 'service=previous' "$TARGET"
}

# --- Filesystem error paths ---

@test "fails when target's parent directory doesn't exist" {
    run airplanes_write_state "$ROOT_DIR/nonexistent/state" service=test
    [ "$status" -eq 1 ]
}

# --- Idempotence / overwrite ---

@test "subsequent successful write replaces previous content" {
    airplanes_write_state "$TARGET" service=first
    airplanes_write_state "$TARGET" service=second
    grep -qx 'service=second' "$TARGET"
    ! grep -qx 'service=first' "$TARGET"
}
