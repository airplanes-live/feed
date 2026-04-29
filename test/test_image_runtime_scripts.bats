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
    cat > "$root/boot/airplanes-config.txt" <<'EOF'
LATITUDE="52.52000"
LONGITUDE="13.40500"
ALTITUDE="35m"
USER="image-feeder"
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
    grep -q -- "--uuid-file=$root/boot/airplanes-uuid" "$arg_log"
    grep -q -- "--write-json $root/run/airplanes-feed" "$arg_log"
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
