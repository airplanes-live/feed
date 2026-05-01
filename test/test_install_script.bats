#!/usr/bin/env bats

setup() {
    INSTALL="$BATS_TEST_DIRNAME/../install.sh"
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

make_git_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name "Test User"
}

commit_all() {
    local repo="$1"
    git -C "$repo" add .
    git -C "$repo" commit -q -m fixture
}

@test "install.sh reports a clear error when not run as root" {
    write_stub id 'if [[ "$1" == "-u" ]]; then echo 1000; exit 0; fi; /usr/bin/id "$@"'

    run env PATH="$STUB_DIR:/usr/bin:/bin" AIRPLANES_ROOT="$ROOT_DIR" bash "$INSTALL"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "must be ran using sudo or as root" ]]
}

@test "install.sh fetches configured repo branch and runs setup.sh" {
    local repo="$ROOT_DIR/source"
    make_git_repo "$repo"
    cat > "$repo/setup.sh" <<'SH'
#!/usr/bin/env bash
set -e
mkdir -p "$AIRPLANES_ROOT"
printf '%s\n' "$PWD" > "$AIRPLANES_ROOT/setup-pwd"
SH
    chmod +x "$repo/setup.sh"
    commit_all "$repo"

    write_stub whiptail 'exit 0'
    write_stub apt-get 'printf "%s\n" "$@" >> "$APT_GET_LOG"; exit 0'

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR/root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_FEED_REPO="$repo" \
        AIRPLANES_FEED_BRANCH=main \
        APT_GET_LOG="$ROOT_DIR/apt-get.log" \
        bash "$INSTALL"

    [ "$status" -eq 0 ]
    [ -f "$ROOT_DIR/root/setup-pwd" ]
    [ "$(cat "$ROOT_DIR/root/setup-pwd")" = "$ROOT_DIR/root/usr/local/share/airplanes/git" ]
    [ "$(git -C "$ROOT_DIR/root/usr/local/share/airplanes/git" remote get-url origin)" = "$repo" ]
}

@test "install.sh propagates build mode to setup.sh" {
    local repo="$ROOT_DIR/source"
    make_git_repo "$repo"
    cat > "$repo/setup.sh" <<'SH'
#!/usr/bin/env bash
set -e
mkdir -p "$AIRPLANES_ROOT"
printf '%s\n' "${AIRPLANES_BUILD_MODE:-}" > "$AIRPLANES_ROOT/build-mode"
printf '%s\n' "$*" > "$AIRPLANES_ROOT/setup-args"
SH
    chmod +x "$repo/setup.sh"
    commit_all "$repo"

    write_stub whiptail 'exit 0'
    write_stub apt-get 'printf "%s\n" "$@" >> "$APT_GET_LOG"; exit 0'

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR/root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_FEED_REPO="$repo" \
        AIRPLANES_FEED_BRANCH=main \
        APT_GET_LOG="$ROOT_DIR/apt-get.log" \
        bash "$INSTALL" --build-mode

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/root/build-mode")" = "1" ]
    [ "$(cat "$ROOT_DIR/root/setup-args")" = "--build-mode" ]
}

@test "standalone install.sh works without scripts/lib checkout" {
    local repo="$ROOT_DIR/source"
    local standalone="$ROOT_DIR/standalone"
    mkdir -p "$standalone"
    cp "$INSTALL" "$standalone/install.sh"
    chmod +x "$standalone/install.sh"

    make_git_repo "$repo"
    cat > "$repo/setup.sh" <<'SH'
#!/usr/bin/env bash
set -e
mkdir -p "$AIRPLANES_ROOT"
printf '%s\n' "$PWD" > "$AIRPLANES_ROOT/standalone-setup-pwd"
SH
    chmod +x "$repo/setup.sh"
    commit_all "$repo"

    write_stub apt-get 'printf "%s\n" "$@" >> "$APT_GET_LOG"; exit 0'

    run env PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR/root" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_FEED_REPO="$repo" \
        AIRPLANES_FEED_BRANCH=main \
        APT_GET_LOG="$ROOT_DIR/apt-get.log" \
        bash "$standalone/install.sh"

    [ "$status" -eq 0 ]
    [ -f "$ROOT_DIR/root/standalone-setup-pwd" ]
    [ "$(cat "$ROOT_DIR/root/standalone-setup-pwd")" = "$ROOT_DIR/root/usr/local/share/airplanes/git" ]
}
