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

# __FEED_REF__ template behavior: the source-tree install.sh leaves the
# placeholder literal (release CI substitutes it before publishing as the
# release asset). When literal, AIRPLANES_RELEASE_REF resets to empty and
# the fallback chain lands on "main". When substituted (simulated here
# via sed), AIRPLANES_RELEASE_REF holds the tag and AIRPLANES_FEED_BRANCH
# resolves to it.

extract_release_ref_eval() {
    # Print the post-evaluation value of AIRPLANES_FEED_BRANCH when the
    # script's inline fallback block runs in isolation. We extract only
    # the marker handling + AIRPLANES_FEED_BRANCH assignment to avoid
    # pulling in unrelated globals. Pattern matches the AIRPLANES_RELEASE_REF
    # assignment line regardless of whether the placeholder has been
    # substituted by release CI.
    local script="$1"
    awk '
        /^[[:space:]]*AIRPLANES_RELEASE_REF=/ { in_block = 1 }
        in_block { print }
        in_block && /unset AIRPLANES_RELEASE_REF/ { exit }
    ' "$script"
}

@test "inline fallback __FEED_REF__ literal falls through to main" {
    local snippet
    snippet="$(extract_release_ref_eval "$INSTALL")"
    run env -u AIRPLANES_FEED_BRANCH bash -c "$snippet
printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
}

@test "inline fallback __FEED_REF__ substituted uses the tag value" {
    local rendered="$ROOT_DIR/install-rendered.sh"
    python3 -c '
import sys
src, dst, ref = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f: c = f.read()
with open(dst, "w") as f: f.write(c.replace("__FEED_REF__", ref, 1))
' "$INSTALL" "$rendered" "v0.1.0"
    local snippet
    snippet="$(extract_release_ref_eval "$rendered")"
    run env -u AIRPLANES_FEED_BRANCH bash -c "$snippet
printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "v0.1.0" ]
}

@test "inline fallback __FEED_REF__ substituted still respects explicit env override" {
    local rendered="$ROOT_DIR/install-rendered.sh"
    python3 -c '
import sys
src, dst, ref = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f: c = f.read()
with open(dst, "w") as f: f.write(c.replace("__FEED_REF__", ref, 1))
' "$INSTALL" "$rendered" "v0.1.0"
    local snippet
    snippet="$(extract_release_ref_eval "$rendered")"
    run env AIRPLANES_FEED_BRANCH=v0.2.0-test bash -c "$snippet
printf '%s' \"\$AIRPLANES_FEED_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "v0.2.0-test" ]
}
