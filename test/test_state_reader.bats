#!/usr/bin/env bats

# Unit tests for scripts/lib/state-reader.sh. The reader is the foundation
# for daemon-state-driven status display; bugs here ripple into every
# consumer (apl-feed status, render-status, webconfig snapshot endpoint).

setup() {
    READER_LIB="$BATS_TEST_DIRNAME/../scripts/lib/state-reader.sh"
    WRITER_LIB="$BATS_TEST_DIRNAME/../scripts/lib/state-writer.sh"
    ROOT_DIR="$(mktemp -d)"
    TARGET="$ROOT_DIR/state"
    # shellcheck source=../scripts/lib/state-reader.sh
    source "$READER_LIB"
    # shellcheck source=../scripts/lib/state-writer.sh
    source "$WRITER_LIB"
}

teardown() {
    chmod -R u+rwX "$ROOT_DIR" 2>/dev/null || true
    rm -rf "$ROOT_DIR"
}

valid_state_file() {
    cat > "$1" <<'EOF'
schema_version=1
service=airplanes-mlat
state=disabled
reason=mlat_enabled_false
mlat_user=
mlat_enabled=false
latitude=52.520
longitude=13.405
EOF
}

# --- Happy path ---

@test "reads existing key and returns its value" {
    valid_state_file "$TARGET"
    run airplanes_read_state "$TARGET" reason
    [ "$status" -eq 0 ]
    [ "$output" = 'mlat_enabled_false' ]
}

@test "reads first matching key (single-pass scan)" {
    valid_state_file "$TARGET"
    run airplanes_read_state "$TARGET" service
    [ "$status" -eq 0 ]
    [ "$output" = 'airplanes-mlat' ]
}

@test "reads empty value as empty string" {
    valid_state_file "$TARGET"
    run airplanes_read_state "$TARGET" mlat_user
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "reads value containing internal spaces verbatim" {
    cat > "$TARGET" <<'EOF'
schema_version=1
input=127.0.0.1:30005 dump1090
EOF
    run airplanes_read_state "$TARGET" input
    [ "$status" -eq 0 ]
    [ "$output" = '127.0.0.1:30005 dump1090' ]
}

@test "reads value containing shell metacharacters verbatim (reader never sources)" {
    # writer would emit the literal `$(...)` string; reader returns it as data.
    cat > "$TARGET" <<'EOF'
schema_version=1
feed_bin=/usr/bin/x$(`)"\;&|<>
EOF
    run airplanes_read_state "$TARGET" feed_bin
    [ "$status" -eq 0 ]
    [ "$output" = '/usr/bin/x$(`)"\;&|<>' ]
}

# --- Failure paths: every error path returns 1 with no stdout ---

@test "returns 1 for non-existent file" {
    run airplanes_read_state "$ROOT_DIR/missing" reason
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 for unreadable file" {
    valid_state_file "$TARGET"
    chmod 000 "$TARGET"
    run airplanes_read_state "$TARGET" reason
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    chmod 0644 "$TARGET"   # restore for teardown
}

@test "returns 1 for a directory at the path (rejects non-regular files)" {
    mkdir -p "$ROOT_DIR/dir-instead-of-file"
    run airplanes_read_state "$ROOT_DIR/dir-instead-of-file" reason
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 for missing schema_version line" {
    cat > "$TARGET" <<'EOF'
service=airplanes-mlat
reason=mlat_enabled_false
EOF
    run airplanes_read_state "$TARGET" reason
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 for unknown schema_version=2" {
    cat > "$TARGET" <<'EOF'
schema_version=2
reason=future_thing
EOF
    run airplanes_read_state "$TARGET" reason
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 for key not found" {
    valid_state_file "$TARGET"
    run airplanes_read_state "$TARGET" nope
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 when value contains CR (corrupt file)" {
    printf 'schema_version=1\nreason=foo\r\n' > "$TARGET"
    run airplanes_read_state "$TARGET" reason
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 for invalid key arg (shell metacharacter)" {
    valid_state_file "$TARGET"
    run airplanes_read_state "$TARGET" 'reason; rm -rf /'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 for empty key arg" {
    valid_state_file "$TARGET"
    run airplanes_read_state "$TARGET" ''
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "returns 1 for key starting with digit" {
    valid_state_file "$TARGET"
    run airplanes_read_state "$TARGET" '1bad'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- Round-trip with state-writer ---

@test "round-trip: write then read recovers each key in order" {
    airplanes_write_state "$TARGET" \
        service=airplanes-mlat \
        state=disabled \
        reason=mlat_enabled_false \
        mlat_user= \
        mlat_enabled=false
    [ "$(airplanes_read_state "$TARGET" service)" = 'airplanes-mlat' ]
    [ "$(airplanes_read_state "$TARGET" state)" = 'disabled' ]
    [ "$(airplanes_read_state "$TARGET" reason)" = 'mlat_enabled_false' ]
    run airplanes_read_state "$TARGET" mlat_user
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(airplanes_read_state "$TARGET" mlat_enabled)" = 'false' ]
}

@test "schema_version is validation-only, not retrievable as a key" {
    # The first line is consumed by the schema check; readers don't
    # need to retrieve schema_version (it's always 1 per the contract).
    # Document this explicitly: schema_version returns 1 (not found)
    # even though it's syntactically present, because it's special.
    airplanes_write_state "$TARGET" service=test
    run airplanes_read_state "$TARGET" schema_version
    [ "$status" -eq 1 ]
}

@test "round-trip: shell-metacharacter values survive write+read" {
    airplanes_write_state "$TARGET" 'feed_bin=/usr/bin/x$(`)"\;&|<>'
    [ "$(airplanes_read_state "$TARGET" feed_bin)" = '/usr/bin/x$(`)"\;&|<>' ]
}

# --- Non-root readability (sentinel against future writer tightening) ---

@test "non-root user can read state files written by non-root user (mode 0644)" {
    # The bats test process runs as a non-root user. The writer chmods
    # to 0644 (per state-writer.sh). Confirm the same user can read
    # what was just written. Guards against any future regression that
    # tightens permissions and accidentally locks out apl-feed-as-user.
    airplanes_write_state "$TARGET" service=test state=enabled reason=ok
    perms="$(stat -c '%a' "$TARGET" 2>/dev/null || stat -f '%Lp' "$TARGET")"
    [ "$perms" = '644' ]
    [ "$(airplanes_read_state "$TARGET" reason)" = 'ok' ]
}
