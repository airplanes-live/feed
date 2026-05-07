#!/usr/bin/env bats

setup() {
    SETUP_SCRIPT="$BATS_TEST_DIRNAME/../setup.sh"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    EVENTS_LOG="$ROOT_DIR/events.log"
    ID_LOG="$ROOT_DIR/id.log"
    GIT_DIR="$ROOT_DIR/usr/local/share/airplanes/git"
    mkdir -p "$STUB_DIR" "$GIT_DIR"
    : > "$EVENTS_LOG"
    : > "$ID_LOG"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Quote a path/string into a single-quoted shell literal so heredoc-baked
# scripts stay safe even if TMPDIR contains spaces or shell metacharacters.
shell_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

write_id_stub() {
    local uid="$1"
    local id_log_q
    id_log_q="$(shell_quote "$ID_LOG")"
    cat > "$STUB_DIR/id" <<EOF
#!/usr/bin/env bash
printf 'id %s\n' "\$*" >> $id_log_q
if [[ "\$1" == "-u" ]]; then
    printf '%s\n' "$uid"
    exit 0
fi
exit 0
EOF
    chmod +x "$STUB_DIR/id"
}

write_fixture_script() {
    local target="$1"
    local label="$2"
    local exit_code="$3"
    local events_q
    events_q="$(shell_quote "$EVENTS_LOG")"
    cat > "$target" <<EOF
#!/usr/bin/env bash
{
    printf '%s\n' "$label"
    printf 'env:AIRPLANES_BUILD_MODE=%s\n' "\${AIRPLANES_BUILD_MODE:-}"
    for a in "\$@"; do
        printf 'argv:%s\n' "\$a"
    done
} >> $events_q
exit $exit_code
EOF
    chmod +x "$target"
}

write_whiptail_stub() {
    local exit_code="$1"
    local events_q
    events_q="$(shell_quote "$EVENTS_LOG")"
    cat > "$STUB_DIR/whiptail" <<EOF
#!/usr/bin/env bash
{
    printf 'whiptail\n'
    for a in "\$@"; do
        printf 'whiptail-argv:%s\n' "\$a"
    done
} >> $events_q
exit $exit_code
EOF
    chmod +x "$STUB_DIR/whiptail"
}

make_image_install_fixture() {
    mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/etc/airplanes"
    : > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"
    : > "$ROOT_DIR/etc/airplanes/feed.env"
}

# run_setup [ENV=val ...] -- [setup.sh args...]
# Always invokes via `env -i` so a developer shell that exported
# AIRPLANES_BUILD_MODE, BASH_ENV, etc. cannot make a refusal/prompt test lie.
run_setup() {
    local extra_env=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        extra_env+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    run env -i \
        PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        "${extra_env[@]}" \
        bash "$SETUP_SCRIPT" "$@"
}

@test "setup.sh refuses to run on an airplanes.live image" {
    make_image_install_fixture
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 99
    write_fixture_script "$GIT_DIR/update.sh" "update" 99
    write_whiptail_stub 99

    run_setup --

    [ "$status" -eq 1 ]
    [[ "$output" == *"airplanes.live image"* ]]
    [ ! -s "$EVENTS_LOG" ]
}

@test "setup.sh --build-mode bypasses image refusal and propagates args+env to children" {
    make_image_install_fixture
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 0
    write_fixture_script "$GIT_DIR/update.sh" "update" 0
    write_whiptail_stub 99

    run_setup -- --build-mode "with space"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^configure$' "$EVENTS_LOG")" = "1" ]
    [ "$(grep -c '^update$' "$EVENTS_LOG")" = "1" ]
    [ "$(grep -c '^whiptail$' "$EVENTS_LOG")" = "0" ]
    # configure runs before update.
    [ "$(grep -nE '^(configure|update)$' "$EVENTS_LOG" | head -n1)" = "1:configure" ]
    [ "$(grep -E '^(configure|update)$' "$EVENTS_LOG" | tail -n1)" = "update" ]
    # Both children received --build-mode and "with space" as separate argv entries.
    [ "$(grep -c '^argv:--build-mode$' "$EVENTS_LOG")" = "2" ]
    [ "$(grep -c '^argv:with space$' "$EVENTS_LOG")" = "2" ]
    # Both children saw AIRPLANES_BUILD_MODE=1 (exported by airplanes_enable_build_mode_from_args).
    [ "$(grep -c '^env:AIRPLANES_BUILD_MODE=1$' "$EVENTS_LOG")" = "2" ]
}

@test "setup.sh non-build-mode runs configure, prompts confirm, runs update, and forwards args" {
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 0
    write_fixture_script "$GIT_DIR/update.sh" "update" 0
    write_whiptail_stub 0

    run_setup -- "plain arg"

    [ "$status" -eq 0 ]
    actual_order="$(grep -E '^(configure|update|whiptail)$' "$EVENTS_LOG")"
    expected_order=$'configure\nwhiptail\nupdate'
    [ "$actual_order" = "$expected_order" ]
    # Whiptail received --yesno and the prompt as DISTINCT argv entries.
    grep -q '^whiptail-argv:--yesno$' "$EVENTS_LOG"
    grep -q '^whiptail-argv:.*ready to begin setting up' "$EVENTS_LOG"
    # Both children saw the plain-arg pass-through, no --build-mode injected.
    [ "$(grep -c '^argv:plain arg$' "$EVENTS_LOG")" = "2" ]
    [ "$(grep -c '^argv:--build-mode$' "$EVENTS_LOG")" = "0" ]
    # AIRPLANES_BUILD_MODE stayed empty — proves non-build mode reached children.
    [ "$(grep -c '^env:AIRPLANES_BUILD_MODE=$' "$EVENTS_LOG")" = "2" ]
}

@test "setup.sh aborts when whiptail confirm returns non-zero" {
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 0
    write_fixture_script "$GIT_DIR/update.sh" "update" 99
    write_whiptail_stub 1

    run_setup --

    [ "$status" -eq 1 ]
    grep -q '^configure$' "$EVENTS_LOG"
    grep -q '^whiptail$' "$EVENTS_LOG"
    [ "$(grep -c '^update$' "$EVENTS_LOG")" = "0" ]
}

@test "setup.sh propagates configure.sh exit status (no whiptail, no update)" {
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 37
    write_fixture_script "$GIT_DIR/update.sh" "update" 99
    write_whiptail_stub 99

    run_setup --

    # set -e propagates the exact child exit code, not a normalized 1.
    [ "$status" -eq 37 ]
    grep -q '^configure$' "$EVENTS_LOG"
    [ "$(grep -c '^whiptail$' "$EVENTS_LOG")" = "0" ]
    [ "$(grep -c '^update$' "$EVENTS_LOG")" = "0" ]
}

@test "setup.sh propagates update.sh exit status" {
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 0
    write_fixture_script "$GIT_DIR/update.sh" "update" 42
    write_whiptail_stub 0

    run_setup --

    [ "$status" -eq 42 ]
    grep -q '^configure$' "$EVENTS_LOG"
    grep -q '^whiptail$' "$EVENTS_LOG"
    grep -q '^update$' "$EVENTS_LOG"
}

@test "setup.sh AIRPLANES_BUILD_MODE=1 env (no flag) skips whiptail and adds no flag to children" {
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 0
    write_fixture_script "$GIT_DIR/update.sh" "update" 0
    write_whiptail_stub 99

    run_setup AIRPLANES_BUILD_MODE=1 --

    [ "$status" -eq 0 ]
    [ "$(grep -c '^configure$' "$EVENTS_LOG")" = "1" ]
    [ "$(grep -c '^update$' "$EVENTS_LOG")" = "1" ]
    [ "$(grep -c '^whiptail$' "$EVENTS_LOG")" = "0" ]
    [ "$(grep -c '^env:AIRPLANES_BUILD_MODE=1$' "$EVENTS_LOG")" = "2" ]
    # No args were passed in; setup must NOT inject --build-mode into child argv.
    [ "$(grep -c '^argv:' "$EVENTS_LOG")" = "0" ]
}

@test "setup.sh hermetic env strips parent AIRPLANES_BUILD_MODE leak" {
    write_id_stub 0
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 0
    write_fixture_script "$GIT_DIR/update.sh" "update" 0
    write_whiptail_stub 0

    # Parent shell pollution: a developer shell exporting these vars must not
    # cause setup.sh to silently take the build-mode branch.
    export AIRPLANES_BUILD_MODE=1
    export BASH_ENV=/dev/null

    run_setup --

    [ "$status" -eq 0 ]
    # whiptail was invoked → setup ran as non-build despite parent env.
    grep -q '^whiptail$' "$EVENTS_LOG"
    [ "$(grep -c '^env:AIRPLANES_BUILD_MODE=$' "$EVENTS_LOG")" = "2" ]
}

@test "setup.sh refuses to run as non-root" {
    write_id_stub 1000
    write_fixture_script "$GIT_DIR/configure.sh" "configure" 99
    write_fixture_script "$GIT_DIR/update.sh" "update" 99
    write_whiptail_stub 99

    # Don't pass AIRPLANES_SKIP_ROOT_CHECK=1 — exercise the real-root path.
    run env -i \
        PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR" \
        bash "$SETUP_SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo or as root"* ]]
    # Prove the test rejected via setup.sh's own check, not because the test
    # runner happens to be non-root: the id stub must have been invoked with -u.
    grep -q '^id -u$' "$ID_LOG"
    [ ! -s "$EVENTS_LOG" ]
}
