#!/usr/bin/env bats

# Per-module tests for scripts/apl-feed/diagnostics.sh. Mirrors
# test_apl_feed_mlat.bats: source common.sh + diagnostics.sh, point ROOT
# at a scratch tree containing /etc/airplanes/feed.env, route apply
# through the per-test lock file.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    mkdir -p "$TMPDIR" "$STUB_DIR" "$ROOT_DIR/etc/airplanes"
    export TMPDIR

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/configure-validators.sh"
    # shellcheck source=../scripts/lib/feed-env-keys.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-keys.sh"
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-apply.sh"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/diagnostics.sh
    source "$LIB_DIR/diagnostics.sh"
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
    cat > "$STUB_DIR/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/logger"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Baseline feed.env with no REPORT_STATUS line (the post-install default
# state — commented in the template, parsed as enabled).
write_feed_env_default() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35"
GEO_CONFIGURED=true
MLAT_USER="bats-tester"
MLAT_ENABLED=true
MLAT_PRIVATE=false
EOF
}

write_feed_env_with_report_status() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35"
GEO_CONFIGURED=true
MLAT_USER="bats-tester"
MLAT_ENABLED=true
MLAT_PRIVATE=false
REPORT_STATUS=$1
EOF
}

# --- enable ---

@test "diagnostics enable: appends REPORT_STATUS=true to feed.env from default state" {
    write_feed_env_default
    run apl_feed_diagnostics_enable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REPORT_STATUS set to true"* ]]
    grep -Eq "^REPORT_STATUS=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "diagnostics enable: idempotent (no_change exit 0 when REPORT_STATUS=true already)" {
    write_feed_env_with_report_status true
    run apl_feed_diagnostics_enable
    [ "$status" -eq 0 ]
    # no_change suppresses the "REPORT_STATUS set to true" success line;
    # the stderr "Skipping service restart" line from --root testing is
    # the only output expected here.
    ! [[ "$output" == *"REPORT_STATUS set to"* ]]
    grep -Eq "^REPORT_STATUS=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "diagnostics enable: flips REPORT_STATUS=false to true and reports applied" {
    write_feed_env_with_report_status false
    run apl_feed_diagnostics_enable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REPORT_STATUS set to true"* ]]
    grep -Eq "^REPORT_STATUS=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "diagnostics enable: rejects unknown flag" {
    write_feed_env_default
    run apl_feed_diagnostics_enable --no-such-flag
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown flag"* ]]
}

# --- disable ---

@test "diagnostics disable: writes REPORT_STATUS=false to feed.env from default state" {
    write_feed_env_default
    run apl_feed_diagnostics_disable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REPORT_STATUS set to false"* ]]
    grep -Eq "^REPORT_STATUS=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "diagnostics disable: idempotent when REPORT_STATUS=false already" {
    write_feed_env_with_report_status false
    run apl_feed_diagnostics_disable
    [ "$status" -eq 0 ]
    ! [[ "$output" == *"REPORT_STATUS set to"* ]]
    grep -Eq "^REPORT_STATUS=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "diagnostics disable: flips REPORT_STATUS=true to false and reports applied" {
    write_feed_env_with_report_status true
    run apl_feed_diagnostics_disable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REPORT_STATUS set to false"* ]]
    grep -Eq "^REPORT_STATUS=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

# --- round-trip ---

@test "diagnostics enable -> disable -> enable preserves canonical bytes" {
    write_feed_env_default
    apl_feed_diagnostics_enable >/dev/null
    apl_feed_diagnostics_disable >/dev/null
    apl_feed_diagnostics_enable >/dev/null
    grep -Eq "^REPORT_STATUS=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
    # No spurious duplicate lines — the apply library rewrites in place.
    local count
    count="$(grep -Ec '^REPORT_STATUS=' "$ROOT_DIR/etc/airplanes/feed.env")"
    [ "$count" = "1" ]
}

# --- no daemon restart ---

@test "diagnostics enable does NOT restart any service (REPORT_STATUS is no-restart in the key registry)" {
    write_feed_env_default
    apl_feed_diagnostics_enable >/dev/null
    [ -f "$SYSTEMCTL_LOG" ] && ! grep -q 'restart' "$SYSTEMCTL_LOG" || true
    # Stronger assertion: the log file is either absent or has no restart lines.
    if [[ -f "$SYSTEMCTL_LOG" ]]; then
        ! grep -q 'restart' "$SYSTEMCTL_LOG"
    fi
}

# --- dispatcher ---

@test "dispatch_diagnostics enable routes to apl_feed_diagnostics_enable" {
    write_feed_env_default
    run dispatch_diagnostics enable
    [ "$status" -eq 0 ]
    grep -Eq "^REPORT_STATUS=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "dispatch_diagnostics disable routes to apl_feed_diagnostics_disable" {
    write_feed_env_default
    run dispatch_diagnostics disable
    [ "$status" -eq 0 ]
    grep -Eq "^REPORT_STATUS=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "dispatch_diagnostics with no subcommand fails with actionable message" {
    run dispatch_diagnostics
    [ "$status" -ne 0 ]
    [[ "$output" == *"diagnostics requires a subcommand"* ]]
    [[ "$output" == *"enable"* ]]
    [[ "$output" == *"disable"* ]]
}

@test "dispatch_diagnostics with unknown subcommand fails" {
    run dispatch_diagnostics nuke
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown diagnostics subcommand: nuke"* ]]
}

# --- missing feed.env ---

@test "diagnostics enable surfaces filesystem_error when feed.env is missing" {
    # No write_feed_env_default; the file simply doesn't exist.
    run apl_feed_diagnostics_enable
    [ "$status" -ne 0 ]
    # The apply library reports filesystem_error or rejected; either way
    # the message is to stderr and the result is non-zero.
    [[ "$output" == *"ERROR"* ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feed.env" ]
}
