#!/usr/bin/env bats

setup() {
    FEED_SCRIPT="$BATS_TEST_DIRNAME/../scripts/airplanes-feed.sh"
    MLAT_SCRIPT="$BATS_TEST_DIRNAME/../scripts/airplanes-mlat.sh"
    ROOT_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

write_image_config() {
    local root="$1"
    mkdir -p "$root/boot" "$root/usr/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/usr/bin/airplanes-feeder"
    chmod +x "$root/usr/bin/airplanes-feeder"
    # Represents post-migration boot config: USER preserved for legacy
    # consumers, MLAT_USER + MLAT_ENABLED added by airplanes-webconfig's
    # migrate-config.sh so the new daemon sees the split schema.
    cat > "$root/boot/airplanes-config.txt" <<'EOF'
LATITUDE="52.52000"
LONGITUDE="13.40500"
ALTITUDE="35m"
USER="image-feeder"
MLAT_USER="image-feeder"
MLAT_ENABLED=true
MODEAC="yes"
MLAT_MARKER="no"
EOF
    cat > "$root/boot/airplanes-env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
MLATSERVER="feed.airplanes.live:31090"
NET_OPTIONS="--decoder-option-that-must-not-feed --net-bi-port 30004,30104"
JSON_OPTIONS="--json-location-accuracy 2"
RESULTS="--results beast,connect,localhost:30104"
EOF
}

@test "airplanes-feed.sh uses image feed defaults without decoder NET_OPTIONS" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/args.log"
    write_image_config "$root"
    cat > "$root/usr/bin/airplanes-feeder" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$root/usr/bin/airplanes-feeder"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" bash "$FEED_SCRIPT"

    [ "$status" -eq 0 ]
    grep -q -- '--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004' "$arg_log"
    grep -q -- '--net-ro-interval 0.2' "$arg_log"
    grep -q -- '--db-file=none' "$arg_log"
    grep -q -- '--max-range 450' "$arg_log"
    grep -q -- '--modeac' "$arg_log"
    grep -q -- "--uuid-file=$root/etc/airplanes/feeder-id" "$arg_log"
    # --write-json was the output sink for the bundled tar1090 installer; nothing
    # consumes /run/airplanes-feed anymore. Match the bare flag only — guard
    # against accidental reintroduction without flagging --write-json-every or
    # --write-json-globe-index, which are unrelated readsb tuning flags.
    if grep -Eq -- '(^|[[:space:]])--write-json([[:space:]]|$)' "$arg_log"; then
        return 1
    fi
    if grep -q -- '--decoder-option-that-must-not-feed' "$arg_log"; then
        return 1
    fi
    if grep -q -- '--net-bi-port 30004,30104' "$arg_log"; then
        return 1
    fi
}

@test "airplanes-mlat.sh reads image config and applies privacy marker" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    write_image_config "$root"
    mkdir -p "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$stub_bin/nc" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$stub_bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$root/usr/local/share/airplanes/venv/bin/mlat-client" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$stub_bin/nc" "$stub_bin/sleep" "$root/usr/local/share/airplanes/venv/bin/mlat-client"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" PATH="$stub_bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -q -- '--input-connect 127.0.0.1:30005' "$arg_log"
    grep -q -- '--server feed.airplanes.live:31090' "$arg_log"
    grep -q -- '--user image-feeder' "$arg_log"
    grep -q -- '--privacy' "$arg_log"
    grep -q -- '--results beast,connect,localhost:30104' "$arg_log"
    grep -q -- "--uuid-file $root/etc/airplanes/feeder-id" "$arg_log"
}

@test "airplanes-mlat.sh lets MLAT_MARKER enable the marker" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    write_image_config "$root"
    sed -i -e 's/MLAT_MARKER="no"/MLAT_MARKER="yes"/' "$root/boot/airplanes-config.txt"
    printf 'PRIVACY="--privacy"\n' >> "$root/boot/airplanes-env"
    mkdir -p "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$stub_bin/nc" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$stub_bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$root/usr/local/share/airplanes/venv/bin/mlat-client" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$stub_bin/nc" "$stub_bin/sleep" "$root/usr/local/share/airplanes/venv/bin/mlat-client"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" PATH="$stub_bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    if grep -q -- '--privacy' "$arg_log"; then
        return 1
    fi
}

@test "airplanes-feed.sh detects new-contract image via marker without /usr/bin/airplanes-feeder" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/args.log"
    local feed_bin="$root/usr/local/share/airplanes/feed-airplanes"
    mkdir -p "$root/etc/airplanes" "$root/usr/local/share/airplanes"
    : > "$root/etc/airplanes/image-install"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="1"
LONGITUDE="2"
ALTITUDE="3m"
USER="image-marker"
MLATSERVER="feed.airplanes.live:31090"
NET_OPTIONS="--decoder-option-that-must-not-feed --net-bi-port 30004,30104"
EOF
    cat > "$feed_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$feed_bin"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" bash "$FEED_SCRIPT"

    [ "$status" -eq 0 ]
    grep -q -- '--db-file=none' "$arg_log"
    grep -q -- '--max-range 450' "$arg_log"
    grep -q -- '--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004' "$arg_log"
    grep -q -- '--net-ro-interval 0.2' "$arg_log"
    if grep -q -- '--decoder-option-that-must-not-feed' "$arg_log"; then
        return 1
    fi
    if grep -q -- '--net-bi-port 30004,30104' "$arg_log"; then
        return 1
    fi
}

@test "airplanes-feed.sh stays in manual-install branch when neither marker nor legacy binary present" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/args.log"
    local feed_bin="$root/usr/local/share/airplanes/feed-airplanes"
    mkdir -p "$root/etc/airplanes" "$root/usr/local/share/airplanes"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="1"
LONGITUDE="2"
ALTITUDE="3m"
USER="manual-install"
MLATSERVER="feed.airplanes.live:31090"
TARGET="--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"
NET_OPTIONS="--manual-net-option"
EOF
    cat > "$feed_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$feed_bin"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" bash "$FEED_SCRIPT"

    [ "$status" -eq 0 ]
    if grep -q -- '--db-file=none' "$arg_log"; then
        return 1
    fi
    grep -q -- '--manual-net-option' "$arg_log"
}

# --- State-file foundation: daemons publish their config decision ---

# Install state-writer.sh at the daemon's expected runtime path so the
# defensive `if [[ -r ... ]]` branch sources the real lib. Without this,
# the daemon falls through to the stub fallback (no-op) and no state
# file is written.
install_state_writer_lib() {
    local root="$1"
    install -d -m 0755 "$root/usr/local/share/airplanes/lib"
    install -m 0644 "$BATS_TEST_DIRNAME/../scripts/lib/state-writer.sh" \
        "$root/usr/local/share/airplanes/lib/state-writer.sh"
}

# Set up an mlat run with stubbed nc/sleep/mlat-client so the daemon
# proceeds through its decision and either (a) emits MLAT DISABLED +
# sleep + exit 0, (b) exits 64, or (c) execs the mlat-client stub.
setup_mlat_runtime() {
    local root="$1"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$stub_bin/nc" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$stub_bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$root/usr/local/share/airplanes/venv/bin/mlat-client" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$stub_bin/nc" "$stub_bin/sleep" "$root/usr/local/share/airplanes/venv/bin/mlat-client"
}

write_feed_env() {
    local root="$1"; shift
    mkdir -p "$root/etc/airplanes"
    : > "$root/etc/airplanes/feed.env"
    local kv
    for kv in "$@"; do
        printf '%s\n' "$kv" >> "$root/etc/airplanes/feed.env"
    done
}

@test "airplanes-mlat.sh writes state=enabled,reason=ok with valid config" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'LATITUDE=52' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" \
        PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    [ -f "$root/run/airplanes-mlat/state" ]
    grep -qx 'schema_version=1' "$root/run/airplanes-mlat/state"
    grep -qx 'service=airplanes-mlat' "$root/run/airplanes-mlat/state"
    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=ok' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_enabled=true' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_user=alice' "$root/run/airplanes-mlat/state"
    grep -qx 'latitude=52' "$root/run/airplanes-mlat/state"
    grep -qx 'longitude=13' "$root/run/airplanes-mlat/state"
    grep -qE '^decided_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$root/run/airplanes-mlat/state"
    # mlat-client was invoked.
    [ -f "$arg_log" ]
}

@test "airplanes-mlat.sh writes state=disabled,reason=mlat_enabled_false when MLAT_ENABLED=false" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=false' \
        'LATITUDE=52' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" \
        PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=disabled' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=mlat_enabled_false' "$root/run/airplanes-mlat/state"
    [[ "$output" == *'MLAT DISABLED'* ]]
    # mlat-client was NOT invoked.
    [ ! -f "$arg_log" ]
}

@test "airplanes-mlat.sh: MLAT_ENABLED=false wins over LATITUDE=0 in reason priority" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=false' \
        'LATITUDE=0' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'reason=mlat_enabled_false' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh writes state=disabled,reason=latitude_zero when LATITUDE=0" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'LATITUDE=0' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=disabled' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=latitude_zero' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh writes state=disabled,reason=longitude_zero when LONGITUDE=0" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'LATITUDE=52' \
        'LONGITUDE=0' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'reason=longitude_zero' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh exits 64 with state=misconfigured when MLAT_USER empty + MLAT_ENABLED=true" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER=""' \
        'MLAT_ENABLED=true' \
        'LATITUDE=52' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 64 ]
    grep -qx 'state=misconfigured' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=mlat_user_empty' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_user=' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh exits 64 with schema-strict guard when boot config has legacy USER but no MLAT_USER" {
    # Simulates a feeder where airplanes-update or webconfig migration
    # did not run before the daemon started. The schema guard catches it
    # early (before mlat_user_empty classifier) and points at the fix.
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    mkdir -p "$root/boot" "$root/usr/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/usr/bin/airplanes-feeder"
    chmod +x "$root/usr/bin/airplanes-feeder"
    cat > "$root/boot/airplanes-config.txt" <<'EOF'
LATITUDE="52.52000"
LONGITUDE="13.40500"
ALTITUDE="35m"
USER="legacy-only"
EOF

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 64 ]
    [[ "$output" == *"legacy USER= schema detected"* ]]
    [[ "$output" == *"Update Webconfig"* ]]
    # State file is not written: we exit before classifier runs.
    [ ! -f "$root/run/airplanes-mlat/state" ]
}

@test "airplanes-mlat.sh runs without state-writer lib (defensive source falls through to stub)" {
    # Don't install_state_writer_lib — daemon should still proceed.
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'LATITUDE=52' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" \
        PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    # Daemon still invoked mlat-client; no state file because lib was missing.
    [ -f "$arg_log" ]
    [ ! -f "$root/run/airplanes-mlat/state" ]
}

@test "airplanes-feed.sh writes state=enabled,reason=ok with effective config" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/feed-args.log"
    install_state_writer_lib "$root"
    write_image_config "$root"
    cat > "$root/usr/bin/airplanes-feeder" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$root/usr/bin/airplanes-feeder"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" bash "$FEED_SCRIPT"

    [ "$status" -eq 0 ]
    [ -f "$root/run/airplanes-feed/state" ]
    grep -qx 'schema_version=1' "$root/run/airplanes-feed/state"
    grep -qx 'service=airplanes-feed' "$root/run/airplanes-feed/state"
    grep -qx 'state=enabled' "$root/run/airplanes-feed/state"
    grep -qx 'reason=ok' "$root/run/airplanes-feed/state"
    grep -qx 'latitude=52.52000' "$root/run/airplanes-feed/state"
    grep -qx 'longitude=13.40500' "$root/run/airplanes-feed/state"
    grep -qx 'input=127.0.0.1:30005' "$root/run/airplanes-feed/state"
    grep -q -- "feed_bin=$root/usr/bin/airplanes-feeder" "$root/run/airplanes-feed/state"
}

@test "runtime scripts prefer canonical feed.env over boot config when both exist" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/args.log"
    write_image_config "$root"
    mkdir -p "$root/etc/airplanes"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30007"
INPUT_TYPE="dump1090"
LATITUDE="1"
LONGITUDE="2"
ALTITUDE="3m"
USER="canonical-feed-env"
MLATSERVER="feed.airplanes.live:31090"
TARGET="--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"
EOF
    cat > "$root/usr/bin/airplanes-feeder" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARG_LOG"
exit 0
SH
    chmod +x "$root/usr/bin/airplanes-feeder"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" bash "$FEED_SCRIPT"

    [ "$status" -eq 0 ]
    grep -q -- '--lat 1 --lon 2' "$arg_log"
    if grep -q -- '52.52000' "$arg_log"; then
        return 1
    fi
}
