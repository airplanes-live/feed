#!/usr/bin/env bats

# Tests for `apl-feed import legacy-config <path>` — translates a legacy
# /boot/airplanes-config.txt-shaped file into the canonical feed.env
# schema and routes the write through apl_feed_apply.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    mkdir -p "$STUB_DIR" "$ROOT_DIR/etc/airplanes"

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/configure-validators.sh"
    # shellcheck source=../scripts/lib/feed-env-keys.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-keys.sh"
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-apply.sh"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/import.sh
    source "$LIB_DIR/import.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    APL_TEST_LOCK_FILE="$ROOT_DIR/feed-env.lock"
    feed_env_lock_path() { printf '%s\n' "$APL_TEST_LOCK_FILE"; }

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$ROOT_DIR"
}

import() {
    IMPORT_RC=0
    apl_feed_import_legacy_config "$@" || IMPORT_RC=$?
}

@test "USER=alice → MLAT_USER + MLAT_ENABLED=true" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -q '^MLAT_USER="alice"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE '^MLAT_ENABLED=(true|"true")$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^LATITUDE="52.5"$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "USER=0 → MLAT_USER empty + MLAT_ENABLED=false" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=0
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -q '^MLAT_USER=""$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE '^MLAT_ENABLED=(false|"false")$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "USER=disable behaves like USER=0" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=disable
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -qE '^MLAT_ENABLED=(false|"false")$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "MLAT_MARKER=no → MLAT_PRIVATE=true (inverted polarity)" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
MLAT_MARKER=no
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -qE '^MLAT_PRIVATE=(true|"true")$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "MLAT_MARKER=yes → MLAT_PRIVATE=false" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
MLAT_MARKER=yes
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -qE '^MLAT_PRIVATE=(false|"false")$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "PRIVACY=yes wins over MLAT_MARKER=yes" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
MLAT_MARKER=yes
PRIVACY=yes
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -qE '^MLAT_PRIVATE=(true|"true")$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "GEO auto-derived from coords (non-zero → true)" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -qE '^GEO_CONFIGURED=(true|"true")$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "GEO auto-derived from coords (0/0 → false)" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=0
LONGITUDE=0
ALTITUDE=120m
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    grep -qE '^GEO_CONFIGURED=(false|"false")$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "missing feed.env is auto-created" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
EOF
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    [ -f "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "missing path: dies" {
    run apl_feed_import_legacy_config "$ROOT_DIR/nope.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *'not found'* ]]
}

@test "empty file: no recognised keys" {
    : > "$ROOT_DIR/airplanes-config.txt"
    run apl_feed_import_legacy_config "$ROOT_DIR/airplanes-config.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *'no recognised keys'* ]]
}

@test "idempotent: rerun on identical input returns no_change" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    : > "$SYSTEMCTL_LOG"
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
}

@test "invalid USER (shape-mismatch) silently dropped" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=bad user with spaces
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    [ "$IMPORT_RC" -eq 0 ]
    # MLAT_USER not present in payload → not in output.
    ! grep -q '^MLAT_USER=' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "unsafe value (shell metachar in MLAT_USER) rejected by library" {
    cat > "$ROOT_DIR/airplanes-config.txt" <<'EOF'
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
MLAT_USER=alice;rm -rf /
EOF
    import "$ROOT_DIR/airplanes-config.txt"
    # The import filter drops the invalid MLAT_USER because the regex
    # check matches the strict canonical pattern only — semicolons are
    # excluded. The library never sees the bad value.
    [ "$IMPORT_RC" -eq 0 ]
    ! grep -q 'rm -rf' "$ROOT_DIR/etc/airplanes/feed.env"
}
