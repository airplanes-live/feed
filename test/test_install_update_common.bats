#!/usr/bin/env bats

setup() {
    HELPER="$BATS_TEST_DIRNAME/../scripts/lib/install-update-common.sh"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    mkdir -p "$STUB_DIR" "$ROOT_DIR/etc"
    echo 'VERSION_ID="13"' > "$ROOT_DIR/etc/os-release"
    export AIRPLANES_ROOT="$ROOT_DIR"
    # shellcheck source=../scripts/lib/install-update-common.sh
    source "$HELPER"
    airplanes_init_paths
}

teardown() {
    rm -rf "$ROOT_DIR"
}

make_git_repo() {
    local repo="$1"
    local branch="${2:-main}"
    mkdir -p "$repo"
    git -C "$repo" init -q -b "$branch"
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name "Test User"
}

commit_file() {
    local repo="$1"
    local path="$2"
    local content="$3"
    mkdir -p "$(dirname "$repo/$path")"
    printf '%s\n' "$content" > "$repo/$path"
    git -C "$repo" add "$path"
    git -C "$repo" commit -q -m "write $path"
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

write_archive_fallback_stubs() {
    write_stub wget 'output=""; while [[ $# -gt 0 ]]; do case "$1" in -O) output="$2"; shift 2 ;; *) shift ;; esac; done; printf "%s\n" "zip" > "$output"; exit 0'
    write_stub unzip 'if [[ "${2:-}" != "-d" ]]; then exit 1; fi; mkdir -p "$3/archive-main"; printf "%s\n" "fallback" > "$3/archive-main/setup.sh"; exit 0'
}

@test "airplanes_path maps absolute paths under AIRPLANES_ROOT" {
    [ "$(airplanes_path /etc/airplanes/feed.env)" = "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "image install detection supports canonical feed.env without boot config" {
    mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/etc/airplanes"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"
    printf 'USER="image"\n' > "$ROOT_DIR/etc/airplanes/feed.env"

    run airplanes_is_image_install

    [ "$status" -eq 0 ]
}

@test "image install detection accepts marker file with feed.env (new contract)" {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    : > "$ROOT_DIR/etc/airplanes/image-install"
    printf 'USER="image"\n' > "$ROOT_DIR/etc/airplanes/feed.env"

    run airplanes_is_image_install

    [ "$status" -eq 0 ]
}

@test "image install detection rejects marker file alone without feed.env" {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    : > "$ROOT_DIR/etc/airplanes/image-install"

    run airplanes_is_image_install

    [ "$status" -ne 0 ]
}

@test "image install detection returns false for manual install (no marker, no legacy binary)" {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    printf 'USER="manual"\n' > "$ROOT_DIR/etc/airplanes/feed.env"

    run airplanes_is_image_install

    [ "$status" -ne 0 ]
}

@test "feed-bin resolver picks legacy /usr/bin/airplanes-feeder when present" {
    mkdir -p "$ROOT_DIR/usr/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"

    run airplanes_image_feed_bin_default

    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/usr/bin/airplanes-feeder" ]
}

@test "feed-bin resolver falls back to /usr/local/share/airplanes/feed-airplanes when legacy missing" {
    run airplanes_image_feed_bin_default

    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/usr/local/share/airplanes/feed-airplanes" ]
}

@test "getGIT clones the configured branch from a local repository" {
    local repo="$ROOT_DIR/source"
    local target="$ROOT_DIR/target"
    make_git_repo "$repo" main
    commit_file "$repo" setup.sh "first"

    run getGIT "$repo" main "$target"

    [ "$status" -eq 0 ]
    [ "$(cat "$target/setup.sh")" = "first" ]
    [ "$(git -C "$target" remote get-url origin)" = "$repo" ]
}

@test "getGIT updates an existing checkout from the same origin" {
    local repo="$ROOT_DIR/source"
    local target="$ROOT_DIR/target"
    make_git_repo "$repo" main
    commit_file "$repo" setup.sh "first"
    getGIT "$repo" main "$target"
    commit_file "$repo" setup.sh "second"

    run getGIT "$repo" main "$target"

    [ "$status" -eq 0 ]
    [ "$(cat "$target/setup.sh")" = "second" ]
}

@test "getGIT falls back to wget archive when git clone fails" {
    local target="$ROOT_DIR/target"
    write_stub git 'exit 1'
    write_archive_fallback_stubs
    PATH="$STUB_DIR:/usr/bin:/bin"
    export PATH

    run getGIT "https://example.invalid/feed.git" main "$target"

    [ "$status" -eq 0 ]
    [ "$(cat "$target/setup.sh")" = "fallback" ]
}

@test "getGIT falls back to wget archive when git is unavailable" {
    local target="$ROOT_DIR/target"
    write_stub git 'exit 127'
    write_archive_fallback_stubs
    PATH="$STUB_DIR:/usr/bin:/bin"
    export PATH

    run getGIT "https://example.invalid/feed.git" main "$target"

    [ "$status" -eq 0 ]
    [ "$(cat "$target/setup.sh")" = "fallback" ]
}

@test "apt package installer includes Debian package set and netcat fallback" {
    write_stub apt-get 'printf "%s\n" "$@" >> "$APT_GET_LOG"; exit 0'
    PATH="$STUB_DIR:/usr/bin:/bin"
    export PATH APT_GET_LOG="$ROOT_DIR/apt-get.log" AIRPLANES_PACKAGE_MANAGER=apt

    run airplanes_install_update_deps

    [ "$status" -eq 0 ]
    grep -q -- '--no-install-recommends' "$APT_GET_LOG"
    grep -q -- 'build-essential' "$APT_GET_LOG"
    grep -q -- 'pkg-config' "$APT_GET_LOG"
    grep -q -- 'libzstd-dev' "$APT_GET_LOG"
}

@test "yum package branch is selectable without apt autodetection" {
    write_stub yum 'printf "%s\n" "$@" >> "$YUM_LOG"; exit 0'
    PATH="$STUB_DIR:/usr/bin:/bin"
    export PATH YUM_LOG="$ROOT_DIR/yum.log" AIRPLANES_PACKAGE_MANAGER=yum

    run airplanes_install_update_deps

    [ "$status" -eq 0 ]
    grep -q -- 'python3-virtualenv' "$YUM_LOG"
    grep -q -- 'pkgconfig' "$YUM_LOG"
    grep -q -- 'libzstd-devel' "$YUM_LOG"
}

@test "dnf package branch is selectable without apt autodetection" {
    write_stub dnf 'printf "%s\n" "$@" >> "$DNF_LOG"; exit 0'
    PATH="$STUB_DIR:/usr/bin:/bin"
    export PATH DNF_LOG="$ROOT_DIR/dnf.log" AIRPLANES_PACKAGE_MANAGER=dnf

    run airplanes_install_update_deps

    [ "$status" -eq 0 ]
    grep -q -- 'python3-virtualenv' "$DNF_LOG"
    grep -q -- 'pkgconf-pkg-config' "$DNF_LOG"
    grep -q -- 'libzstd-devel' "$DNF_LOG"
}
