#!/usr/bin/env bats

setup() {
    UPDATE="$BATS_TEST_DIRNAME/../update.sh"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    mkdir -p "$STUB_DIR"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

write_stub() {
    local name="$1"
    local body="$2"
    cat > "$STUB_DIR/$name" <<SH
#!/usr/bin/env bash
$body
SH
    chmod +x "$STUB_DIR/$name"
}

install_command_stubs() {
    write_stub apt-get 'printf "apt-get %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    write_stub id 'if [[ "$1" == "-u" && "${2:-}" == "airplanes-feed" ]]; then exit 0; fi; if [[ "$1" == "-u" ]]; then echo 0; exit 0; fi; /usr/bin/id "$@"'
    write_stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; if [[ "$1" == "restart" && "${2:-}" == "airplanes-feed" && -n "${SYSTEMCTL_FEED_ENV:-}" ]]; then printf "target-at-restart=%s\n" "$(grep "^TARGET=" "$SYSTEMCTL_FEED_ENV")" >> "$COMMAND_LOG"; fi; if [[ "$1" == "is-enabled" ]]; then echo disabled; exit 0; fi; exit 0'
    write_stub journalctl 'exit 0'
    write_stub pgrep 'printf "pgrep %s\n" "$*" >> "$COMMAND_LOG"; exit 1'
    write_stub nc 'exit 1'
    write_stub sleep 'exit 0'
    write_stub renice 'exit 0'
    write_stub adduser 'printf "adduser %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    write_stub useradd 'printf "useradd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    write_stub addgroup 'printf "addgroup %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    write_stub groupadd 'printf "groupadd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    write_stub usermod 'printf "usermod %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    write_stub gpasswd 'printf "gpasswd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
}

make_git_repo() {
    local repo="$1"
    local branch="${2:-main}"
    mkdir -p "$repo"
    git -C "$repo" init -q -b "$branch"
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name "Test User"
}

commit_all() {
    local repo="$1"
    git -C "$repo" add .
    git -C "$repo" commit -q -m fixture
}

copy_feed_fixture_repo() {
    local repo="$1"
    mkdir -p "$repo"
    cp -a "$REPO_ROOT/." "$repo/"
    rm -rf "$repo/.git"
    make_git_repo "$repo" main
    commit_all "$repo"
}

make_component_repo() {
    local repo="$1"
    local branch="$2"
    make_git_repo "$repo" "$branch"
    printf '%s\n' "$repo" > "$repo/README"
    commit_all "$repo"
}

write_feed_env() {
    local root="$1"
    mkdir -p "$root/etc/airplanes" "$root/etc/default" "$root/etc"
    echo 'VERSION_ID="13"' > "$root/etc/os-release"
    cat > "$root/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
INPUT_TYPE="dump1090"
USER="0"
LATITUDE="0"
LONGITUDE="0"
ALTITUDE="0"
MLATSERVER="feed.airplanes.live:31090"
TARGET="--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed.airplanes.live,64004"
NET_OPTIONS="--net-heartbeat 60 --uuid-file /usr/local/share/airplanes/airplanes-uuid"
EOF
}

write_image_boot_config() {
    local root="$1"
    mkdir -p "$root/boot" "$root/etc/default" "$root/etc/systemd/system" "$root/usr/bin"
    echo 'VERSION_ID="13"' > "$root/etc/os-release"
    ln -s /boot/airplanes-config.txt "$root/etc/default/airplanes"
    printf 'ExecStart=/usr/local/bin/airplanes-feed.sh\n' > "$root/etc/systemd/system/airplanes-feed.service"
    printf 'ExecStart=/usr/local/bin/mlat.sh\n' > "$root/etc/systemd/system/airplanes-mlat.service"
    # Post-migration shape — feed/update.sh's strict guard requires the
    # split keys. airplanes-update's migrate-config.sh produces this from
    # legacy USER= on every image update; the migration itself is covered
    # by airplanes-webconfig's migrate-config-test.sh and airplanes-update's
    # rootfs smokes. Here we treat the migrated state as the starting point.
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
RESULTS="--results beast,connect,localhost:30104"
NET_OPTIONS="--decoder-option-that-must-not-feed"
JSON_OPTIONS="--json-location-accuracy 2"
EOF
    printf '%s\n' "22222222-3333-4444-5555-666666666666" > "$root/boot/airplanes-uuid"
}

prepare_skip_build_state() {
    local root="$1"
    local feed_repo="$2"
    local mlat_repo="$3"
    local readsb_repo="$4"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$ipath/venv/bin"
    cp "$feed_repo/update.sh" "$ipath/update.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ipath/venv/bin/mlat-client"
    chmod +x "$ipath/venv/bin/mlat-client"
    git -C "$mlat_repo" rev-parse HEAD > "$ipath/mlat_version"
    git -C "$readsb_repo" rev-parse HEAD > "$ipath/readsb_version"
    cat > "$ipath/feed-airplanes" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-V" ]] && exit 0
exit 0
SH
    chmod +x "$ipath/feed-airplanes"
}

prepare_image_skip_build_state() {
    local root="$1"
    local feed_repo="$2"
    local mlat_repo="$3"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$ipath/venv/bin" "$root/usr/bin"
    cp "$feed_repo/update.sh" "$ipath/update.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ipath/venv/bin/mlat-client"
    chmod +x "$ipath/venv/bin/mlat-client"
    git -C "$mlat_repo" rev-parse HEAD > "$ipath/mlat_version"
    cat > "$root/usr/bin/airplanes-feeder" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-V" ]] && exit 0
exit 0
SH
    chmod +x "$root/usr/bin/airplanes-feeder"
}

prepare_marker_image_skip_build_state() {
    local root="$1"
    local feed_repo="$2"
    local mlat_repo="$3"
    local readsb_repo="$4"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$ipath/venv/bin"
    cp "$feed_repo/update.sh" "$ipath/update.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ipath/venv/bin/mlat-client"
    chmod +x "$ipath/venv/bin/mlat-client"
    git -C "$mlat_repo" rev-parse HEAD > "$ipath/mlat_version"
    git -C "$readsb_repo" rev-parse HEAD > "$ipath/readsb_version"
    cat > "$ipath/feed-airplanes" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-V" ]] && exit 0
exit 0
SH
    chmod +x "$ipath/feed-airplanes"
    mkdir -p "$root/etc/airplanes"
    : > "$root/etc/airplanes/image-install"
}

@test "update.sh replaces a missing or stale installed updater before continuing" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$feed_repo" "$ipath" "$root/etc"
    echo 'VERSION_ID="13"' > "$root/etc/os-release"
    cat > "$feed_repo/update.sh" <<'SH'
#!/usr/bin/env bash
set -e
printf 'self-update-ran\n' > "$AIRPLANES_ROOT/self-update-marker"
SH
    chmod +x "$feed_repo/update.sh"
    make_git_repo "$feed_repo" main
    commit_all "$feed_repo"
    printf 'old updater\n' > "$ipath/update.sh"

    run env PATH="/usr/bin:/bin" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=none \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ "$(cat "$root/self-update-marker")" = "self-update-ran" ]
    cmp "$feed_repo/update.sh" "$ipath/update.sh"
    [ "$(stat -c '%a' "$ipath/update.sh")" = "755" ]
}

@test "update.sh self-replace tolerates a 0644 destination from older feed" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$feed_repo" "$ipath" "$root/etc"
    echo 'VERSION_ID="13"' > "$root/etc/os-release"
    cat > "$feed_repo/update.sh" <<'SH'
#!/usr/bin/env bash
set -e
printf 'self-update-ran\n' > "$AIRPLANES_ROOT/self-update-marker"
SH
    chmod +x "$feed_repo/update.sh"
    make_git_repo "$feed_repo" main
    commit_all "$feed_repo"
    printf 'old updater\n' > "$ipath/update.sh"
    chmod 0644 "$ipath/update.sh"

    run env PATH="/usr/bin:/bin" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=none \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$ipath/update.sh")" = "755" ]
}

@test "update.sh runs setup when no feed env exists" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$ipath" "$root/etc"
    echo 'VERSION_ID="13"' > "$root/etc/os-release"
    copy_feed_fixture_repo "$feed_repo"
    cat > "$feed_repo/setup.sh" <<'SH'
#!/usr/bin/env bash
set -e
mkdir -p "$AIRPLANES_ROOT"
printf 'setup-ran\n' > "$AIRPLANES_ROOT/setup-marker"
SH
    chmod +x "$feed_repo/setup.sh"
    commit_all "$feed_repo"
    cp "$feed_repo/update.sh" "$ipath/update.sh"

    run env PATH="/usr/bin:/bin" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=none \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ "$(cat "$root/setup-marker")" = "setup-ran" ]
}

@test "update.sh runs configured update path without touching host root" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local mlat_repo="$ROOT_DIR/mlat-source"
    local readsb_repo="$ROOT_DIR/readsb-source"
    local claim_bin="$ROOT_DIR/apl-feed-stub"
    local ipath="$root/usr/local/share/airplanes"

    copy_feed_fixture_repo "$feed_repo"
    make_component_repo "$mlat_repo" master
    make_component_repo "$readsb_repo" dev
    write_feed_env "$root"
    sed -i -e 's/beast_reduce_plus_out/beast_reduce_out/' "$root/etc/airplanes/feed.env"
    prepare_skip_build_state "$root" "$feed_repo" "$mlat_repo" "$readsb_repo"
    install_command_stubs
    cat > "$claim_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIM_LOG"
exit 0
SH
    chmod +x "$claim_bin"

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        CLAIM_LOG="$ROOT_DIR/claim.log" \
        SYSTEMCTL_FEED_ENV="$root/etc/airplanes/feed.env" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        AIRPLANES_MLAT_REPO="$mlat_repo" \
        AIRPLANES_MLAT_BRANCH=master \
        AIRPLANES_READSB_REPO="$readsb_repo" \
        AIRPLANES_READSB_BRANCH=dev \
        APL_FEED_BIN="$claim_bin" \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ -x "$root/usr/local/bin/apl-feed" ]
    [ -f "$ipath/apl-feed/common.sh" ]
    [ -f "$root/lib/systemd/system/airplanes-feed.service" ]
    [ -f "$root/lib/systemd/system/airplanes-mlat.service" ]
    [ -f "$root/etc/airplanes/feeder-id" ]
    [ -L "$ipath/airplanes-uuid" ]
    [ "$(readlink "$ipath/airplanes-uuid")" = "../../../../etc/airplanes/feeder-id" ]
    grep -q 'UAT_INPUT="127.0.0.1:30978"' "$root/etc/airplanes/feed.env"
    grep -q 'beast_reduce_plus_out,feed2.airplanes.live,64004' "$root/etc/airplanes/feed.env"
    ! grep -q -- '--uuid-file' "$root/etc/airplanes/feed.env"
    [ -L "$root/etc/default/airplanes" ]
    [ "$(readlink "$root/etc/default/airplanes")" = "$root/etc/airplanes/feed.env" ]
    grep -q 'claim register' "$ROOT_DIR/claim.log"
    grep -q -- '--max-retry-time 15' "$ROOT_DIR/claim.log"
    grep -q 'systemctl restart airplanes-feed' "$ROOT_DIR/commands.log"
    [ "$(grep -c 'systemctl daemon-reload' "$ROOT_DIR/commands.log")" = "1" ]
    grep -q 'target-at-restart=TARGET="--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"' "$ROOT_DIR/commands.log"
    # Lifecycle handover: even when MLAT is disabled by config, update.sh
    # no longer disables/stops the unit — the daemon self-disables via
    # sleep+exit. The state-file pattern depends on the daemon being
    # invoked at all (so it can publish state=disabled, reason=...).
    ! grep -q 'systemctl disable airplanes-mlat' "$ROOT_DIR/commands.log"
    ! grep -q 'systemctl stop airplanes-mlat' "$ROOT_DIR/commands.log"
    grep -q 'systemctl enable airplanes-mlat' "$ROOT_DIR/commands.log"
    grep -q 'systemctl restart airplanes-mlat' "$ROOT_DIR/commands.log"
}

# Mirror /usr/bin and /bin into $out via symlinks, but skip nc, netcat,
# and timeout. Used by the missing-nc regression test below to give the
# updater a working PATH for everything *except* the connectivity-probe
# tools, so `command -v nc` truly returns false during the test.
_make_no_nc_bin() {
    local out="$1"
    mkdir -p "$out"
    local d f name
    for d in /usr/bin /bin; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*; do
            [[ -e "$f" ]] || continue
            name="$(basename "$f")"
            case "$name" in nc|nc.*|netcat|netcat-*|timeout) continue;; esac
            [[ -e "$out/$name" || -L "$out/$name" ]] && continue
            ln -s "$f" "$out/$name" 2>/dev/null || true
        done
    done
}

@test "update.sh post-install probe stays silent when nc is missing" {
    # Regression pin for the nc-probe ordering bug: prior to the fix,
    # update.sh ran `nc -z ...` before checking `command -v nc`, so a
    # feeder that couldn't install netcat-openbsd (apt unreachable,
    # alpine, custom image) saw `nc: command not found` from the shell
    # right above the success message. The fix gates both `nc` and
    # `timeout` via `command -v` so the probe is silently skipped when
    # either is missing.
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local mlat_repo="$ROOT_DIR/mlat-source"
    local readsb_repo="$ROOT_DIR/readsb-source"
    local claim_bin="$ROOT_DIR/apl-feed-stub"
    local nonc_bin="$ROOT_DIR/nonc-bin"

    copy_feed_fixture_repo "$feed_repo"
    make_component_repo "$mlat_repo" master
    make_component_repo "$readsb_repo" dev
    write_feed_env "$root"
    prepare_skip_build_state "$root" "$feed_repo" "$mlat_repo" "$readsb_repo"
    install_command_stubs
    # install_command_stubs always installs an `nc` stub. Remove it so
    # `command -v nc` fails when the only PATH entries are $STUB_DIR and
    # $nonc_bin (the latter mirrors /usr/bin and /bin minus nc/timeout).
    rm -f "$STUB_DIR/nc"
    _make_no_nc_bin "$nonc_bin"
    cat > "$claim_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIM_LOG"
exit 0
SH
    chmod +x "$claim_bin"

    run env PATH="$STUB_DIR:$nonc_bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        CLAIM_LOG="$ROOT_DIR/claim.log" \
        SYSTEMCTL_FEED_ENV="$root/etc/airplanes/feed.env" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        AIRPLANES_MLAT_REPO="$mlat_repo" \
        AIRPLANES_MLAT_BRANCH=master \
        AIRPLANES_READSB_REPO="$readsb_repo" \
        AIRPLANES_READSB_BRANCH=dev \
        APL_FEED_BIN="$claim_bin" \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Thanks for choosing to share your data"* ]]
    # The pre-fix code would leak these via stderr from nc / timeout.
    # `run` merges stderr into $output by default, so this assertion
    # fails before the fix and passes after.
    [[ "$output" != *"nc: command not found"* ]]
    [[ "$output" != *"timeout: failed to run command"* ]]
}

@test "update.sh build mode enables units without live systemd or per-device state" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local mlat_repo="$ROOT_DIR/mlat-source"
    local readsb_repo="$ROOT_DIR/readsb-source"
    local claim_bin="$ROOT_DIR/apl-feed-stub"

    copy_feed_fixture_repo "$feed_repo"
    make_component_repo "$mlat_repo" master
    make_component_repo "$readsb_repo" dev
    write_feed_env "$root"
    prepare_skip_build_state "$root" "$feed_repo" "$mlat_repo" "$readsb_repo"
    install_command_stubs
    cat > "$claim_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIM_LOG"
exit 0
SH
    chmod +x "$claim_bin"

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        CLAIM_LOG="$ROOT_DIR/claim.log" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_BUILD_MODE=1 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        AIRPLANES_MLAT_REPO="$mlat_repo" \
        AIRPLANES_MLAT_BRANCH=master \
        AIRPLANES_READSB_REPO="$readsb_repo" \
        AIRPLANES_READSB_BRANCH=dev \
        APL_FEED_BIN="$claim_bin" \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ -f "$root/etc/systemd/system/airplanes-feed.service" ]
    [ -f "$root/etc/systemd/system/airplanes-mlat.service" ]
    [ ! -e "$root/lib/systemd/system/airplanes-feed.service" ]
    grep -qE '^After=.*airplanes-first-run.service' "$root/etc/systemd/system/airplanes-feed.service"
    grep -qE '^After=.*airplanes-first-run.service' "$root/etc/systemd/system/airplanes-mlat.service"
    [ -x "$root/usr/local/share/airplanes/feed-airplanes" ]
    [ ! -x "$root/usr/bin/airplanes-feeder" ]
    [ -f "$root/etc/airplanes/image-install" ]
    grep -q 'systemctl enable airplanes-feed' "$ROOT_DIR/commands.log"
    grep -q 'systemctl enable airplanes-mlat' "$ROOT_DIR/commands.log"
    ! grep -q 'systemctl restart' "$ROOT_DIR/commands.log"
    ! grep -q 'systemctl stop' "$ROOT_DIR/commands.log"
    ! grep -q 'systemctl is-active' "$ROOT_DIR/commands.log"
    ! grep -q 'systemctl daemon-reload' "$ROOT_DIR/commands.log"
    ! grep -q '^pgrep ' "$ROOT_DIR/commands.log"
    [ ! -e "$root/etc/airplanes/feeder-id" ]
    [ ! -e "$root/usr/local/share/airplanes/airplanes-uuid" ]
    [ ! -e "$ROOT_DIR/claim.log" ]
    [[ "$output" =~ "Build mode setup complete" ]]
}

@test "update.sh treats lone boot config without image feeder as manual install" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local mlat_repo="$ROOT_DIR/mlat-source"
    local readsb_repo="$ROOT_DIR/readsb-source"
    local claim_bin="$ROOT_DIR/apl-feed-stub"
    local ipath="$root/usr/local/share/airplanes"

    copy_feed_fixture_repo "$feed_repo"
    make_component_repo "$mlat_repo" master
    make_component_repo "$readsb_repo" dev
    write_feed_env "$root"
    mkdir -p "$root/boot"
    printf 'LATITUDE="52.52000"\n' > "$root/boot/airplanes-config.txt"
    prepare_skip_build_state "$root" "$feed_repo" "$mlat_repo" "$readsb_repo"
    install_command_stubs
    cat > "$claim_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIM_LOG"
exit 0
SH
    chmod +x "$claim_bin"

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        CLAIM_LOG="$ROOT_DIR/claim.log" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        AIRPLANES_MLAT_REPO="$mlat_repo" \
        AIRPLANES_MLAT_BRANCH=master \
        AIRPLANES_READSB_REPO="$readsb_repo" \
        AIRPLANES_READSB_BRANCH=dev \
        APL_FEED_BIN="$claim_bin" \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ -x "$ipath/feed-airplanes" ]
    [ -L "$root/etc/default/airplanes" ]
    [ -f "$root/lib/systemd/system/airplanes-feed.service" ]
    [ ! -e "$root/etc/systemd/system/airplanes-feed.service" ]
    [ ! -x "$root/usr/bin/airplanes-feeder" ]
    grep -q 'systemctl restart airplanes-feed' "$ROOT_DIR/commands.log"
    [ "$(grep -c 'systemctl daemon-reload' "$ROOT_DIR/commands.log")" = "1" ]
}

@test "update.sh runs against marker-only image without legacy /usr/bin/airplanes-feeder" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local mlat_repo="$ROOT_DIR/mlat-source"
    local readsb_repo="$ROOT_DIR/readsb-source"
    local claim_bin="$ROOT_DIR/apl-feed-stub"
    local ipath="$root/usr/local/share/airplanes"

    copy_feed_fixture_repo "$feed_repo"
    make_component_repo "$mlat_repo" master
    make_component_repo "$readsb_repo" dev
    write_feed_env "$root"
    prepare_marker_image_skip_build_state "$root" "$feed_repo" "$mlat_repo" "$readsb_repo"
    install_command_stubs
    cat > "$claim_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIM_LOG"
exit 0
SH
    chmod +x "$claim_bin"

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        CLAIM_LOG="$ROOT_DIR/claim.log" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        AIRPLANES_MLAT_REPO="$mlat_repo" \
        AIRPLANES_MLAT_BRANCH=master \
        AIRPLANES_READSB_REPO="$readsb_repo" \
        AIRPLANES_READSB_BRANCH=dev \
        APL_FEED_BIN="$claim_bin" \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    # Marker-only path must not exit with "Image feed binary missing".
    ! [[ "$output" =~ "Image feed binary missing" ]]
    grep -q "Using image-provided feed client: $ipath/feed-airplanes" <<< "$output"
    [ -x "$ipath/feed-airplanes" ]
    [ ! -e "$root/usr/bin/airplanes-feeder" ]
    [ -f "$root/etc/airplanes/image-install" ]
    [ -f "$root/etc/systemd/system/airplanes-feed.service" ]
    grep -q 'systemctl restart airplanes-feed' "$ROOT_DIR/commands.log"
}

@test "update.sh updates image feed stack without migrating boot config to feed.env" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local mlat_repo="$ROOT_DIR/mlat-source"
    local claim_bin="$ROOT_DIR/apl-feed-stub"
    local ipath="$root/usr/local/share/airplanes"

    copy_feed_fixture_repo "$feed_repo"
    make_component_repo "$mlat_repo" master
    write_image_boot_config "$root"
    prepare_image_skip_build_state "$root" "$feed_repo" "$mlat_repo"
    install_command_stubs
    cat > "$claim_bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIM_LOG"
exit 0
SH
    chmod +x "$claim_bin"

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        CLAIM_LOG="$ROOT_DIR/claim.log" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        AIRPLANES_MLAT_REPO="$mlat_repo" \
        AIRPLANES_MLAT_BRANCH=master \
        APL_FEED_BIN="$claim_bin" \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ -x "$root/usr/local/bin/apl-feed" ]
    [ -f "$ipath/apl-feed/common.sh" ]
    [ -f "$root/etc/systemd/system/airplanes-feed.service" ]
    [ -f "$root/etc/systemd/system/airplanes-mlat.service" ]
    grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-feed.sh' "$root/etc/systemd/system/airplanes-feed.service"
    grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh' "$root/etc/systemd/system/airplanes-mlat.service"
    grep -qE '^After=.*airplanes-first-run.service' "$root/etc/systemd/system/airplanes-feed.service"
    grep -qE '^After=.*airplanes-first-run.service' "$root/etc/systemd/system/airplanes-mlat.service"
    [ ! -e "$root/lib/systemd/system/airplanes-feed.service" ]
    [ ! -e "$root/lib/systemd/system/airplanes-mlat.service" ]
    [ "$(cat "$root/etc/airplanes/feeder-id")" = "22222222-3333-4444-5555-666666666666" ]
    [ -L "$ipath/airplanes-uuid" ]
    [ -x "$root/usr/bin/airplanes-feeder" ]
    [ ! -e "$ipath/feed-airplanes" ]
    [ ! -e "$root/etc/airplanes/feed.env" ]
    [ -L "$root/etc/default/airplanes" ]
    [ "$(readlink "$root/etc/default/airplanes")" = "/boot/airplanes-config.txt" ]
    grep -q 'feed2.airplanes.live,64004' "$ipath/airplanes-feed.sh"
    grep -q 'claim register' "$ROOT_DIR/claim.log"
    grep -q 'systemctl restart airplanes-feed' "$ROOT_DIR/commands.log"
    [ "$(grep -c 'systemctl daemon-reload' "$ROOT_DIR/commands.log")" = "1" ]
}

@test "update.sh sweeps orphan airplanes-mlat2 unit before falling back to setup" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$ipath" "$root/etc" \
        "$root/lib/systemd/system" \
        "$root/etc/systemd/system/default.target.wants" \
        "$root/etc/systemd/system/multi-user.target.wants"
    echo 'VERSION_ID="13"' > "$root/etc/os-release"

    cat > "$root/lib/systemd/system/airplanes-mlat2.service" <<'SH'
[Unit]
Description=airplanes-mlat2
[Service]
ExecStart=/bin/true
[Install]
WantedBy=default.target
SH
    ln -s ../../airplanes-mlat2.service \
        "$root/etc/systemd/system/default.target.wants/airplanes-mlat2.service"
    ln -s ../../airplanes-mlat2.service \
        "$root/etc/systemd/system/multi-user.target.wants/airplanes-mlat2.service"

    copy_feed_fixture_repo "$feed_repo"
    cat > "$feed_repo/setup.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$feed_repo/setup.sh"
    commit_all "$feed_repo"
    cp "$feed_repo/update.sh" "$ipath/update.sh"

    install_command_stubs
    : > "$ROOT_DIR/commands.log"

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=none \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [ ! -e "$root/lib/systemd/system/airplanes-mlat2.service" ]
    [ ! -L "$root/etc/systemd/system/default.target.wants/airplanes-mlat2.service" ]
    [ ! -L "$root/etc/systemd/system/multi-user.target.wants/airplanes-mlat2.service" ]
    [[ "$output" == *"Removing legacy airplanes-mlat2 helper unit"* ]]
    # AIRPLANES_ROOT is non-"/" here, so the systemctl guard skips the
    # `disable --now` invocation. We can only verify the file removal +
    # the operator-visible log line. The systemctl-actually-fires path is
    # only exercised when AIRPLANES_ROOT="/" — too risky to test against a
    # real host, and the smoke harness covers it under stubbed PATH.
    ! grep -q 'systemctl disable --now airplanes-mlat2' "$ROOT_DIR/commands.log"
}

@test "update.sh sweep is no-op when no orphan airplanes-mlat2 unit exists" {
    local root="$ROOT_DIR/root"
    local feed_repo="$ROOT_DIR/feed-source"
    local ipath="$root/usr/local/share/airplanes"
    mkdir -p "$ipath" "$root/etc"
    echo 'VERSION_ID="13"' > "$root/etc/os-release"

    copy_feed_fixture_repo "$feed_repo"
    cat > "$feed_repo/setup.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$feed_repo/setup.sh"
    commit_all "$feed_repo"
    cp "$feed_repo/update.sh" "$ipath/update.sh"

    install_command_stubs
    : > "$ROOT_DIR/commands.log"

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        COMMAND_LOG="$ROOT_DIR/commands.log" \
        AIRPLANES_ROOT="$root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=none \
        AIRPLANES_FEED_REPO="$feed_repo" \
        AIRPLANES_FEED_BRANCH=main \
        bash "$UPDATE"

    [ "$status" -eq 0 ]
    [[ "$output" != *"airplanes-mlat2"* ]]
    ! grep -q 'airplanes-mlat2' "$ROOT_DIR/commands.log"
}
