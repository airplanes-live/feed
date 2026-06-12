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
ALTITUDE="35"
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
ALTITUDE="35"
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

@test "dispatch_config with no subcommand shows help (exit 2)" {
    run dispatch_config
    [ "$status" -eq 2 ]
    [[ "$output" == *"apl-feed config <subcommand>"* ]]
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

## `apl-feed config show` — effective-config read surface.

@test "config show prints present readable keys as KEY=value lines" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
LATITUDE="52.52"
LONGITUDE="13.40"
MLAT_ENABLED="true"
TARGET="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"
EOF
    run apl_feed_config_show

    [ "$status" -eq 0 ]
    [[ "$output" == *"LATITUDE=52.52"* ]]
    [[ "$output" == *"MLAT_ENABLED=true"* ]]
    # Non-readable keys (backend overrides) are not part of the surface.
    [[ "$output" != *"TARGET"* ]]
    # Absent readable keys produce no line in the human format.
    [[ "$output" != *"GAIN"* ]]
}

@test "config show --json emits null for absent and empty string for empty" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
LATITUDE="52.52"
UAT_INPUT=""
EOF
    run apl_feed_config_show --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema_version' <<< "$output")" = "1" ]
    [ "$(jq -r '.values.LATITUDE' <<< "$output")" = "52.52" ]
    # Explicitly empty value round-trips as "" — distinct from absent.
    [ "$(jq -r '.values.UAT_INPUT | type' <<< "$output")" = "string" ]
    [ "$(jq -r '.values.UAT_INPUT' <<< "$output")" = "" ]
    [ "$(jq -r '.values.GAIN' <<< "$output")" = "null" ]
    # Every readable key appears, even when feed.env is sparse.
    [ "$(jq -r '.values | length' <<< "$output")" = "${#APL_FEED_READABLE_KEYS[@]}" ]
}

@test "config show --json works against an absent feed.env (all null)" {
    rm -f "$ROOT_DIR/etc/airplanes/feed.env"
    run apl_feed_config_show --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '[.values[] | select(. != null)] | length' <<< "$output")" = "0" ]
}

@test "config show falls back to the legacy boot config like the daemons do" {
    rm -f "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/boot"
    printf '#!/bin/true\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"
    cat > "$ROOT_DIR/boot/airplanes-config.txt" <<'EOF'
LATITUDE="50.00"
MLAT_ENABLED="true"
EOF
    cat > "$ROOT_DIR/boot/airplanes-env" <<'EOF'
LATITUDE="51.00"
EOF
    run apl_feed_config_show --json

    [ "$status" -eq 0 ]
    # airplanes-env overrides airplanes-config.txt (feed_env_paths order).
    [ "$(jq -r '.values.LATITUDE' <<< "$output")" = "51.00" ]
    [ "$(jq -r '.values.MLAT_ENABLED' <<< "$output")" = "true" ]
}

@test "config show uses the strict reader: contract-violating lines are absent" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
LATITUDE="52.52"
MLAT_ENABLED="true" # trailing comment makes this line malformed
EOF
    run apl_feed_config_show --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.values.LATITUDE' <<< "$output")" = "52.52" ]
    [ "$(jq -r '.values.MLAT_ENABLED' <<< "$output")" = "null" ]
}

@test "config show rejects unknown flags via die" {
    run apl_feed_config_show --bogus

    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown flag for config show"* ]]
}

@test "dispatch_config routes show" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
LATITUDE="52.52"
EOF
    run dispatch_config show

    [ "$status" -eq 0 ]
    [[ "$output" == *"LATITUDE=52.52"* ]]
}

@test "config show --json escapes shell-hostile value content correctly" {
    # Single-quoted on disk so the strict reader takes it verbatim; the
    # JSON path must round-trip the raw bytes through jq --arg.
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
GAIN='a"b$c\d'
EOF
    run apl_feed_config_show --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.values.GAIN' <<< "$output")" = 'a"b$c\d' ]
}

@test "config show resolves feed.env through --root in either flag order" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
LATITUDE="52.52"
EOF
    local saved_root="$ROOT"
    ROOT="/nonexistent-root"
    run apl_feed_config_show --root "$saved_root" --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.values.LATITUDE' <<< "$output")" = "52.52" ]

    ROOT="/nonexistent-root"
    run apl_feed_config_show --json --root "$saved_root"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.values.LATITUDE' <<< "$output")" = "52.52" ]
    ROOT="$saved_root"
}

@test "config show legacy fallback works when airplanes-env is absent" {
    rm -f "$ROOT_DIR/etc/airplanes/feed.env"
    mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/boot"
    printf '#!/bin/true\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"
    cat > "$ROOT_DIR/boot/airplanes-config.txt" <<'EOF'
LATITUDE="50.00"
EOF
    run apl_feed_config_show --json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.values.LATITUDE' <<< "$output")" = "50.00" ]
}
