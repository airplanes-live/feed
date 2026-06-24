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

@test "image install detection accepts marker file with boot config (no feed.env)" {
    mkdir -p "$ROOT_DIR/etc/airplanes" "$ROOT_DIR/boot"
    : > "$ROOT_DIR/etc/airplanes/image-install"
    printf 'USER="image"\n' > "$ROOT_DIR/boot/airplanes-config.txt"

    run airplanes_is_image_install

    [ "$status" -eq 0 ]
}

@test "image install detection accepts the legacy feeder binary with config (legacy upgrade path)" {
    # A legacy image predates the /etc/airplanes/image-install marker but ships
    # the baked /usr/bin/airplanes-feeder binary. It must still be detected as
    # an image install so a legacy ROM updating to feed/dev takes the image
    # branch instead of dropping into interactive setup.
    mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/etc/airplanes"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"
    printf 'USER="image"\n' > "$ROOT_DIR/etc/airplanes/feed.env"

    run airplanes_is_image_install

    [ "$status" -eq 0 ]
}

@test "image install detection rejects the legacy feeder binary without any config" {
    # The binary alone (bare rootfs, no feed.env and no boot config) is not a
    # configured image — the config guard must keep it out of the image branch.
    mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/etc/airplanes"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"

    run airplanes_is_image_install

    [ "$status" -ne 0 ]
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

@test "feed-bin resolver returns the unified /opt prefix binary" {
    run airplanes_image_feed_bin_default

    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/opt/airplanes/current/bin/feed-airplanes" ]
}

@test "feed-bin resolver ignores the legacy feeder binary (unified path)" {
    mkdir -p "$ROOT_DIR/usr/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"

    run airplanes_image_feed_bin_default

    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/opt/airplanes/current/bin/feed-airplanes" ]
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

# release-channel pin: image-built feeders drop /etc/airplanes/release-channel
# at build time, and the lib reads it as the fallback branch source so a
# dev-channel image doesn't silently pull runtime updates from feed/main.

@test "release-channel file resolves AIRPLANES_FEED_BRANCH when env is unset" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'dev\n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
    rm -rf "$fresh_root"
}

@test "release-channel file ignored when env override is set" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'dev\n' > "$fresh_root/etc/airplanes/release-channel"
    run env AIRPLANES_FEED_BRANCH=feature-x AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "feature-x" ]
    rm -rf "$fresh_root"
}

@test "missing release-channel falls back to stable sentinel" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "stable" ]
    rm -rf "$fresh_root"
}

@test "release-channel file=stable sets AIRPLANES_FEED_BRANCH=stable sentinel" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'stable\n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "stable" ]
    rm -rf "$fresh_root"
}

@test "release-channel file=main treated as legacy alias for stable" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'main\n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "stable" ]
    rm -rf "$fresh_root"
}

@test "release-channel with trailing whitespace is trimmed" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'dev   \n  \n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
    rm -rf "$fresh_root"
}

@test "release-channel only first line consulted (multi-line tolerated)" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'dev\nbogus\n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
    rm -rf "$fresh_root"
}

@test "release-channel with arbitrary branch name aborts (allowlist enforced)" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'feature-x\n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER"
    [ "$status" -ne 0 ]
    [[ "$output" == *"feature-x"* ]]
    [[ "$output" == *"stable, dev, main"* ]]
    rm -rf "$fresh_root"
}

@test "release-channel with typo (deev) aborts (allowlist enforced)" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'deev\n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER"
    [ "$status" -ne 0 ]
    [[ "$output" == *"deev"* ]]
    rm -rf "$fresh_root"
}

@test "release-channel empty file aborts (does NOT silently fall back to main)" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    : > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER"
    [ "$status" -ne 0 ]
    rm -rf "$fresh_root"
}

@test "release-channel value is uppercase MAIN -> aborts (case-sensitive allowlist)" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'MAIN\n' > "$fresh_root/etc/airplanes/release-channel"
    run env -u AIRPLANES_FEED_BRANCH AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MAIN"* ]]
    rm -rf "$fresh_root"
}

@test "env override bypasses allowlist file check (operator-controlled escape)" {
    local fresh_root
    fresh_root="$(mktemp -d)"
    mkdir -p "$fresh_root/etc/airplanes"
    printf 'feature-x\n' > "$fresh_root/etc/airplanes/release-channel"
    run env AIRPLANES_FEED_BRANCH=feature-x AIRPLANES_ROOT="$fresh_root" \
        bash -c "source $HELPER; printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "feature-x" ]
    rm -rf "$fresh_root"
}

# Tag resolution: airplanes_resolve_latest_stable_tag picks the highest
# semver-strict (vMAJOR.MINOR.PATCH, no leading zeroes, no prereleases) tag
# from the configured feed remote. Tests use a local bare repo as the remote
# so they don't depend on network or on the live feed repo's tag state.

make_remote_with_tags() {
    local remote_dir="$1"
    shift
    local work_dir
    work_dir="$(mktemp -d)"
    git -C "$work_dir" init -q -b main
    git -C "$work_dir" config user.email test@example.invalid
    git -C "$work_dir" config user.name "Test User"
    echo "seed" > "$work_dir/seed"
    git -C "$work_dir" add seed
    git -C "$work_dir" commit -q -m "seed"
    git init --bare -q "$remote_dir"
    git -C "$work_dir" remote add origin "$remote_dir"
    git -C "$work_dir" push -q origin main
    local tag
    for tag in "$@"; do
        git -C "$work_dir" tag "$tag"
    done
    if (( $# > 0 )); then
        git -C "$work_dir" push -q origin --tags
    fi
    rm -rf "$work_dir"
}

@test "airplanes_resolve_latest_stable_tag picks highest semver-strict tag" {
    local remote
    remote="$(mktemp -d)/remote.git"
    make_remote_with_tags "$remote" v0.1.0 v0.1.1 v0.2.0 v1.0.0
    run airplanes_resolve_latest_stable_tag "$remote"
    [ "$status" -eq 0 ]
    [ "$output" = "v1.0.0" ]
}

@test "airplanes_resolve_latest_stable_tag ignores prerelease tags" {
    local remote
    remote="$(mktemp -d)/remote.git"
    make_remote_with_tags "$remote" v0.1.0 v0.2.0-rc.1 v0.2.0-rc.2
    run airplanes_resolve_latest_stable_tag "$remote"
    [ "$status" -eq 0 ]
    [ "$output" = "v0.1.0" ]
}

@test "airplanes_resolve_latest_stable_tag rejects leading-zero versions" {
    local remote
    remote="$(mktemp -d)/remote.git"
    make_remote_with_tags "$remote" v0.1.0 v01.02.03
    run airplanes_resolve_latest_stable_tag "$remote"
    [ "$status" -eq 0 ]
    [ "$output" = "v0.1.0" ]
}

@test "airplanes_resolve_latest_stable_tag returns 1 when no matching tags" {
    local remote
    remote="$(mktemp -d)/remote.git"
    make_remote_with_tags "$remote" v1.0 release-2024 some-feature
    run airplanes_resolve_latest_stable_tag "$remote"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "airplanes_resolve_latest_stable_tag returns 2 on remote-not-found" {
    run airplanes_resolve_latest_stable_tag "/nonexistent/path/repo.git"
    [ "$status" -eq 2 ]
}

@test "airplanes_resolve_feed_branch resolves stable sentinel via remote" {
    local remote
    remote="$(mktemp -d)/remote.git"
    make_remote_with_tags "$remote" v0.1.0 v0.2.0
    AIRPLANES_FEED_REPO="$remote"
    AIRPLANES_FEED_BRANCH=stable
    airplanes_resolve_feed_branch
    [ "$AIRPLANES_FEED_BRANCH" = "v0.2.0" ]
}

@test "airplanes_resolve_feed_branch leaves dev alone" {
    AIRPLANES_FEED_BRANCH=dev
    airplanes_resolve_feed_branch
    [ "$AIRPLANES_FEED_BRANCH" = "dev" ]
}

@test "airplanes_resolve_feed_branch leaves explicit tag alone" {
    AIRPLANES_FEED_BRANCH=v0.1.0
    airplanes_resolve_feed_branch
    [ "$AIRPLANES_FEED_BRANCH" = "v0.1.0" ]
}

@test "airplanes_resolve_feed_branch leaves arbitrary ref alone" {
    AIRPLANES_FEED_BRANCH=feature-x
    airplanes_resolve_feed_branch
    [ "$AIRPLANES_FEED_BRANCH" = "feature-x" ]
}

@test "airplanes_resolve_feed_branch aborts with no-tags-found on stable channel + empty repo" {
    local remote
    remote="$(mktemp -d)/remote.git"
    make_remote_with_tags "$remote" some-feature
    run env AIRPLANES_FEED_REPO="$remote" AIRPLANES_FEED_BRANCH=stable \
        bash -c "source $HELPER; airplanes_resolve_feed_branch"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no v[MAJOR].[MINOR].[PATCH] tags exist"* ]]
}

@test "airplanes_resolve_feed_branch aborts with lookup-failed on stable channel + bad remote" {
    run env AIRPLANES_FEED_REPO="/nonexistent/path/repo.git" AIRPLANES_FEED_BRANCH=stable \
        bash -c "source $HELPER; airplanes_resolve_feed_branch"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not query release tags"* ]]
    [[ "$output" == *"network/DNS/TLS"* ]]
}
