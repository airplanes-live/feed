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
    write_stub id 'if [[ "$1" == "-u" && "${2:-}" == "airplanes" ]]; then exit 0; fi; if [[ "$1" == "-u" ]]; then echo 0; exit 0; fi; /usr/bin/id "$@"'
    write_stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; if [[ "$1" == "restart" && "${2:-}" == "airplanes-feed" && -n "${SYSTEMCTL_FEED_ENV:-}" ]]; then printf "target-at-restart=%s\n" "$(grep "^TARGET=" "$SYSTEMCTL_FEED_ENV")" >> "$COMMAND_LOG"; fi; if [[ "$1" == "is-enabled" ]]; then echo disabled; exit 0; fi; exit 0'
    write_stub journalctl 'exit 0'
    write_stub pgrep 'exit 1'
    write_stub nc 'exit 1'
    write_stub sleep 'exit 0'
    write_stub renice 'exit 0'
    write_stub adduser 'printf "adduser %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    write_stub useradd 'printf "useradd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
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
    [ -f "$ipath/airplanes-uuid" ]
    grep -q 'UAT_INPUT="127.0.0.1:30978"' "$root/etc/airplanes/feed.env"
    grep -q 'beast_reduce_plus_out,feed.airplanes.live,64004' "$root/etc/airplanes/feed.env"
    [ -L "$root/etc/default/airplanes" ]
    [ "$(readlink "$root/etc/default/airplanes")" = "$root/etc/airplanes/feed.env" ]
    grep -q 'claim register' "$ROOT_DIR/claim.log"
    grep -q -- '--max-retry-time 15' "$ROOT_DIR/claim.log"
    grep -q 'systemctl restart airplanes-feed' "$ROOT_DIR/commands.log"
    grep -q 'target-at-restart=TARGET="--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed.airplanes.live,64004"' "$ROOT_DIR/commands.log"
}
