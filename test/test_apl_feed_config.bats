#!/usr/bin/env bats

# Per-module tests for scripts/apl-feed/config.sh covering the
# REMOTE_CONFIG_ENABLED opt-in surface:
#   1. `apl-feed config enable|disable` write the toggle to feed.env via
#      the canonical apl_feed_apply path. Same shape as
#      test_apl_feed_diagnostics.bats.
#   2. `apl-feed config sync` short-circuits silently when the toggle is
#      absent / empty / false, and exits 64 on an unparseable value.
#      The integration-shaped happy-path coverage already lives in
#      test_apl_feed_config_sync.bats; this file only pins the gate.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    CURL_LOG="$ROOT_DIR/curl.log"
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
    # shellcheck source=../scripts/apl-feed/config.sh
    source "$LIB_DIR/config.sh"
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
    # Curl stub: record every invocation so the gate-blocks-network
    # assertion can prove no HTTP went out.
    cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$CURL_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Baseline feed.env with no REMOTE_CONFIG_ENABLED line (the post-install
# default state — operator has not opted in).
write_feed_env_default() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35m"
GEO_CONFIGURED=true
MLAT_USER="bats-tester"
MLAT_ENABLED=true
MLAT_PRIVATE=false
EOF
}

write_feed_env_with_remote_config() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35m"
GEO_CONFIGURED=true
MLAT_USER="bats-tester"
MLAT_ENABLED=true
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=$1
EOF
}

# --- enable ---

@test "config enable: appends REMOTE_CONFIG_ENABLED=true to feed.env from default state" {
    write_feed_env_default
    run apl_feed_config_enable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REMOTE_CONFIG_ENABLED set to true"* ]]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "config enable: idempotent (no_change exit 0 when REMOTE_CONFIG_ENABLED=true already)" {
    write_feed_env_with_remote_config true
    run apl_feed_config_enable
    [ "$status" -eq 0 ]
    ! [[ "$output" == *"REMOTE_CONFIG_ENABLED set to"* ]]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "config enable: flips REMOTE_CONFIG_ENABLED=false to true and reports applied" {
    write_feed_env_with_remote_config false
    run apl_feed_config_enable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REMOTE_CONFIG_ENABLED set to true"* ]]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "config enable: rejects unknown flag" {
    write_feed_env_default
    run apl_feed_config_enable --no-such-flag
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown flag"* ]]
}

# --- disable ---

@test "config disable: writes REMOTE_CONFIG_ENABLED=false to feed.env from default state" {
    write_feed_env_default
    run apl_feed_config_disable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REMOTE_CONFIG_ENABLED set to false"* ]]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "config disable: idempotent when REMOTE_CONFIG_ENABLED=false already" {
    write_feed_env_with_remote_config false
    run apl_feed_config_disable
    [ "$status" -eq 0 ]
    ! [[ "$output" == *"REMOTE_CONFIG_ENABLED set to"* ]]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "config disable: flips REMOTE_CONFIG_ENABLED=true to false and reports applied" {
    write_feed_env_with_remote_config true
    run apl_feed_config_disable
    [ "$status" -eq 0 ]
    [[ "$output" == *"REMOTE_CONFIG_ENABLED set to false"* ]]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

# --- round-trip ---

@test "config enable -> disable -> enable preserves canonical bytes" {
    write_feed_env_default
    apl_feed_config_enable  >/dev/null
    apl_feed_config_disable >/dev/null
    apl_feed_config_enable  >/dev/null
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
    local count
    count="$(grep -Ec '^REMOTE_CONFIG_ENABLED=' "$ROOT_DIR/etc/airplanes/feed.env")"
    [ "$count" = "1" ]
}

# --- no daemon restart ---

@test "config enable does NOT restart any service (REMOTE_CONFIG_ENABLED is no-restart in the key registry)" {
    write_feed_env_default
    apl_feed_config_enable >/dev/null
    if [[ -f "$SYSTEMCTL_LOG" ]]; then
        ! grep -q 'restart' "$SYSTEMCTL_LOG"
    fi
}

# --- dispatcher ---

@test "dispatch_config enable routes to apl_feed_config_enable" {
    write_feed_env_default
    run dispatch_config enable
    [ "$status" -eq 0 ]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?true\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "dispatch_config disable routes to apl_feed_config_disable" {
    write_feed_env_default
    run dispatch_config disable
    [ "$status" -eq 0 ]
    grep -Eq "^REMOTE_CONFIG_ENABLED=\"?false\"?$" "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "dispatch_config with no subcommand fails with actionable message" {
    run dispatch_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"config requires a subcommand"* ]]
    [[ "$output" == *"enable"* ]]
    [[ "$output" == *"disable"* ]]
    [[ "$output" == *"sync"* ]]
}

@test "dispatch_config with unknown subcommand fails" {
    run dispatch_config nuke
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown config subcommand: nuke"* ]]
}

# --- gate: sync short-circuits without REMOTE_CONFIG_ENABLED=true ---

@test "config sync exits 0 silently when REMOTE_CONFIG_ENABLED is absent (default opt-in semantics)" {
    write_feed_env_default
    run apl_feed_config_sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"opt_in_required"* ]]
    [ ! -f "$CURL_LOG" ]
}

@test "config sync exits 0 silently when REMOTE_CONFIG_ENABLED=false" {
    write_feed_env_with_remote_config false
    run apl_feed_config_sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"opt_in_required"* ]]
    [ ! -f "$CURL_LOG" ]
}

@test "config sync exits 0 silently when REMOTE_CONFIG_ENABLED is empty" {
    write_feed_env_with_remote_config ""
    run apl_feed_config_sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"opt_in_required"* ]]
    [ ! -f "$CURL_LOG" ]
}

@test "config sync exits 64 on unparseable REMOTE_CONFIG_ENABLED value" {
    write_feed_env_with_remote_config bogus
    run apl_feed_config_sync
    [ "$status" -eq 64 ]
    [[ "$output" == *"bad_config"* ]]
    [[ "$output" == *"REMOTE_CONFIG_ENABLED"* ]]
    [ ! -f "$CURL_LOG" ]
}

@test "config sync with REMOTE_CONFIG_ENABLED=true passes the gate (subsequent identity check is what fails)" {
    # Confirms the gate is not the blocker: identity files are absent so
    # the function hits the missing-uuid branch, which exits 64. The
    # important property is that the gate's "opt_in_required" message is
    # NOT in the output.
    write_feed_env_with_remote_config true
    run apl_feed_config_sync
    [ "$status" -eq 64 ]
    ! [[ "$output" == *"opt_in_required"* ]]
}

# --- gate position relative to dry-run ---

@test "config sync --dry-run also honors the opt-in gate" {
    # Even dry-run is a payload-build step that touches feed.env beyond
    # what the operator opted into. The gate sits above the dry-run
    # branch so a non-opted-in feeder cannot inadvertently emit a payload.
    write_feed_env_default
    run apl_feed_config_sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"opt_in_required"* ]]
}
