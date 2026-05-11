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
MLAT_PRIVATE=true
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

@test "airplanes-mlat.sh: image-side MLAT_PRIVATE=true → mlat-client gets --privacy" {
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

@test "airplanes-mlat.sh: image-side MLAT_PRIVATE=false → no --privacy" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    write_image_config "$root"
    sed -i -e 's/MLAT_PRIVATE=true/MLAT_PRIVATE=false/' "$root/boot/airplanes-config.txt"
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

# Legacy PRIVACY in-memory fallback. Pins the only deployed code path
# from the pre-rename schema: a manual install whose feed.env still
# carries PRIVACY="--privacy" (inherited from the original ADS-B
# Exchange installer or previously hand-edited) gets the --privacy
# flag passed through even before update.sh runs the migration.
@test "airplanes-mlat.sh: legacy PRIVACY=--privacy with no MLAT_PRIVATE → fallback derives true" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$root/etc/airplanes" "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="52"
LONGITUDE="13"
ALTITUDE="35m"
MLAT_USER="legacy-feeder"
MLAT_ENABLED=true
PRIVACY="--privacy"
MLATSERVER="feed.airplanes.live:31090"
EOF
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
    grep -q -- '--privacy' "$arg_log"
}

@test "airplanes-mlat.sh: legacy PRIVACY=\"\" with no MLAT_PRIVATE → fallback derives false" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$root/etc/airplanes" "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="52"
LONGITUDE="13"
ALTITUDE="35m"
MLAT_USER="legacy-feeder"
MLAT_ENABLED=true
PRIVACY=""
MLATSERVER="feed.airplanes.live:31090"
EOF
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

# Conflict rule: when both the canonical MLAT_PRIVATE and the legacy
# PRIVACY are present, canonical wins. The legacy fallback only fires
# when MLAT_PRIVATE is unset.
@test "airplanes-mlat.sh: MLAT_PRIVATE=false beats legacy PRIVACY=--privacy" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$root/etc/airplanes" "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="52"
LONGITUDE="13"
ALTITUDE="35m"
MLAT_USER="alice"
MLAT_ENABLED=true
PRIVACY="--privacy"
MLAT_PRIVATE=false
MLATSERVER="feed.airplanes.live:31090"
EOF
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

# Legacy MLAT_MARKER in-memory fallback. PHP webconfig's still-shipping
# yes/no dropdown writes MLAT_MARKER to /boot/airplanes-config.txt
# (inverted polarity — "no" means privacy ON). Without this fallback a
# feeder whose user toggled privacy in legacy webconfig would silently
# lose privacy on first daemon start under the new schema.
@test "airplanes-mlat.sh: legacy MLAT_MARKER=no with no MLAT_PRIVATE → fallback derives true" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$root/etc/airplanes" "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="52"
LONGITUDE="13"
ALTITUDE="35m"
MLAT_USER="legacy-feeder"
MLAT_ENABLED=true
MLAT_MARKER="no"
MLATSERVER="feed.airplanes.live:31090"
EOF
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
    grep -q -- '--privacy' "$arg_log"
}

@test "airplanes-mlat.sh: legacy MLAT_MARKER=yes with no MLAT_PRIVATE → fallback derives false" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$root/etc/airplanes" "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="52"
LONGITUDE="13"
ALTITUDE="35m"
MLAT_USER="legacy-feeder"
MLAT_ENABLED=true
MLAT_MARKER="yes"
MLATSERVER="feed.airplanes.live:31090"
EOF
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

# Boot-config sourcing path: legacy image's /boot/airplanes-config.txt has
# MLAT_MARKER from PHP webconfig and no feed.env yet. Daemon falls back to
# sourcing boot config; in-shell MLAT_MARKER fallback derives MLAT_PRIVATE.
# This is the production legacy path that motivated the fallback.
@test "airplanes-mlat.sh: legacy boot-config sourcing with MLAT_MARKER=no → fallback derives true" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$root/boot" "$root/usr/bin" "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/usr/bin/airplanes-feeder"
    chmod +x "$root/usr/bin/airplanes-feeder"
    cat > "$root/boot/airplanes-config.txt" <<'EOF'
LATITUDE="52"
LONGITUDE="13"
ALTITUDE="35m"
MLAT_USER="legacy-feeder"
MLAT_ENABLED=true
MLAT_MARKER="no"
EOF
    cat > "$root/boot/airplanes-env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
MLATSERVER="feed.airplanes.live:31090"
EOF
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
    grep -q -- '--privacy' "$arg_log"
}

# Conflict rule: canonical MLAT_PRIVATE always wins over legacy MLAT_MARKER.
@test "airplanes-mlat.sh: MLAT_PRIVATE=false beats legacy MLAT_MARKER=no" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
    local stub_bin="$ROOT_DIR/bin"
    mkdir -p "$root/etc/airplanes" "$stub_bin" "$root/usr/local/share/airplanes/venv/bin"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
LATITUDE="52"
LONGITUDE="13"
ALTITUDE="35m"
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_MARKER="no"
MLAT_PRIVATE=false
MLATSERVER="feed.airplanes.live:31090"
EOF
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

@test "airplanes-mlat.sh writes state=disabled,reason=geo_not_configured when GEO_CONFIGURED=false" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'GEO_CONFIGURED=false' \
        'LATITUDE=52' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=disabled' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=geo_not_configured' "$root/run/airplanes-mlat/state"
    grep -qx 'geo_configured=false' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh derives GEO_CONFIGURED=false from legacy LATITUDE=0/LONGITUDE=0 pair" {
    # feed.env predating the GEO_CONFIGURED schema addition: in-shell
    # fallback sees the (0,0) placeholder pair and derives false. This is
    # the image-freeze / uninitialized state.
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'LATITUDE=0' \
        'LONGITUDE=0' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'reason=geo_not_configured' "$root/run/airplanes-mlat/state"
    grep -qx 'geo_configured=false' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh fallback heals legacy equator user (LATITUDE=0, LONGITUDE!=0) → GEO_CONFIGURED=true" {
    # Real geographic case the old LATITUDE==0 sentinel falsely disabled.
    # The fallback heuristic recognizes single-axis zero as a legitimate
    # coordinate and classifies as configured.
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

    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'geo_configured=true' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh fallback heals legacy prime-meridian user (LATITUDE!=0, LONGITUDE=0)" {
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

    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'geo_configured=true' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh derives GEO_CONFIGURED=true from non-zero coords (legacy feed.env)" {
    local root="$ROOT_DIR/root"
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

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    grep -qx 'geo_configured=true' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh derives GEO_CONFIGURED=false from decimal-zero pair (0.00000/0.00000)" {
    # Hand-edits or older configure.sh writers may use decimal-zero forms.
    # The helper recognizes them as numerically zero so the placeholder pair
    # isn't misclassified as configured.
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'LATITUDE="0.00000"' \
        'LONGITUDE="0.00000"' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    grep -qx 'geo_configured=false' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh: explicit GEO_CONFIGURED wins over legacy coord derivation" {
    # Equator user (lat=0, lon!=0) with explicit GEO_CONFIGURED=true must
    # not trip the legacy LATITUDE==0 fallback path. The explicit flag is
    # authoritative.
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'GEO_CONFIGURED=true' \
        'LATITUDE=0' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'geo_configured=true' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh: empty MLAT_USER + canonical feeder-id → state=enabled, MLAT_USER=Anonymous-<short>, mlat-client gets --user" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
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
    # Seed a known feeder-id; first 8 chars form the per-device suffix.
    printf '0a1b2c3d-4567-89ab-cdef-0123456789ab\n' > "$root/etc/airplanes/feeder-id"

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=ok' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_user=Anonymous-0a1b2c3d' "$root/run/airplanes-mlat/state"
    # mlat-client must receive the substituted value, not an empty --user.
    grep -q -- '--user Anonymous-0a1b2c3d' "$arg_log"
}

@test "airplanes-mlat.sh: empty MLAT_USER + no feeder-id → state=enabled, MLAT_USER=Anonymous" {
    local root="$ROOT_DIR/root"
    local arg_log="$ROOT_DIR/mlat-args.log"
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
    # Deliberately no $root/etc/airplanes/feeder-id — the daemon falls back
    # to plain "Anonymous" when the file is missing.

    run env AIRPLANES_ROOT="$root" ARG_LOG="$arg_log" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=ok' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_user=Anonymous' "$root/run/airplanes-mlat/state"
    grep -q -- '--user Anonymous' "$arg_log"
}

@test "airplanes-mlat.sh: empty MLAT_USER + empty feeder-id file → MLAT_USER=Anonymous (not Anonymous-)" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER=""' 'MLAT_ENABLED=true' 'LATITUDE=52' 'LONGITUDE=13' 'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' 'INPUT_TYPE="dump1090"' 'MLATSERVER="feed.airplanes.live:31090"'
    : > "$root/etc/airplanes/feeder-id"

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_user=Anonymous' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh: empty MLAT_USER + truncated feeder-id (not a UUID) → MLAT_USER=Anonymous" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER=""' 'MLAT_ENABLED=true' 'LATITUDE=52' 'LONGITUDE=13' 'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' 'INPUT_TYPE="dump1090"' 'MLATSERVER="feed.airplanes.live:31090"'
    # Three printable bytes — would have made a "Anonymous-abc" identity if
    # we used raw head -c 8 without UUID validation.
    printf 'abc' > "$root/etc/airplanes/feeder-id"

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_user=Anonymous' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh: empty MLAT_USER + feeder-id is a symlink → MLAT_USER=Anonymous (refuses to follow)" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER=""' 'MLAT_ENABLED=true' 'LATITUDE=52' 'LONGITUDE=13' 'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' 'INPUT_TYPE="dump1090"' 'MLATSERVER="feed.airplanes.live:31090"'
    # Target file with a canonical-looking UUID; the daemon must still refuse
    # to follow the symlink and fall back to plain Anonymous.
    printf 'ffffffff-1234-5678-9abc-def012345678\n' > "$root/etc/airplanes/feeder-id.target"
    ln -s "$root/etc/airplanes/feeder-id.target" "$root/etc/airplanes/feeder-id"

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'state=enabled' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_user=Anonymous' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh: empty MLAT_USER + feeder-id with CR/LF in canonical UUID → strips CR/LF, MLAT_USER=Anonymous-<short>" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER=""' 'MLAT_ENABLED=true' 'LATITUDE=52' 'LONGITUDE=13' 'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' 'INPUT_TYPE="dump1090"' 'MLATSERVER="feed.airplanes.live:31090"'
    # CRLF line ending (Windows-edited feeder-id file) — must be stripped
    # before the UUID regex check so the validation succeeds.
    printf '0a1b2c3d-4567-89ab-cdef-0123456789ab\r\n' > "$root/etc/airplanes/feeder-id"

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'mlat_user=Anonymous-0a1b2c3d' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh exits 64 with schema-strict guard when boot config has legacy USER but no MLAT_USER" {
    # Simulates a feeder where airplanes-update or webconfig migration
    # did not run before the daemon started. The schema guard catches it
    # early (before any MLAT_USER fallback) and points at the fix — the
    # legacy USER= must be migrated explicitly rather than silently aliased.
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

@test "airplanes-mlat.sh exits 64 with reason=mlat_private_invalid for hand-edited bad MLAT_PRIVATE" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'MLAT_PRIVATE=yes' \
        'LATITUDE=52' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 64 ]
    grep -qx 'state=misconfigured' "$root/run/airplanes-mlat/state"
    grep -qx 'reason=mlat_private_invalid' "$root/run/airplanes-mlat/state"
    grep -qx 'mlat_private=yes' "$root/run/airplanes-mlat/state"
    [[ "$output" == *"MLAT_PRIVATE must be 'true' or 'false'"* ]]
}

@test "airplanes-mlat.sh state file publishes mlat_private=true when MLAT_PRIVATE=true" {
    local root="$ROOT_DIR/root"
    install_state_writer_lib "$root"
    setup_mlat_runtime "$root"
    write_feed_env "$root" \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'MLAT_PRIVATE=true' \
        'LATITUDE=52' \
        'LONGITUDE=13' \
        'ALTITUDE=35m' \
        'INPUT="127.0.0.1:30005"' \
        'INPUT_TYPE="dump1090"' \
        'MLATSERVER="feed.airplanes.live:31090"'

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'mlat_private=true' "$root/run/airplanes-mlat/state"
}

@test "airplanes-mlat.sh state file publishes mlat_private=false when MLAT_PRIVATE absent (runtime default)" {
    local root="$ROOT_DIR/root"
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

    run env AIRPLANES_ROOT="$root" PATH="$ROOT_DIR/bin:$PATH" bash "$MLAT_SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'mlat_private=false' "$root/run/airplanes-mlat/state"
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
