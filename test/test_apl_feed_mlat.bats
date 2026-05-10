#!/usr/bin/env bats

# Per-module tests for scripts/apl-feed/mlat.sh. Mirrors test_apl_feed_id.bats
# in shape: source common.sh + mlat.sh, stub systemctl, point ROOT at a
# scratch tree containing /etc/airplanes/feed.env.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    mkdir -p "$TMPDIR" "$STUB_DIR" "$ROOT_DIR/etc/airplanes"
    export TMPDIR

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/mlat.sh
    source "$LIB_DIR/mlat.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
case "\$1" in
    is-active) echo active ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$ROOT_DIR"
}

write_feed_env() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
MLAT_USER="$1"
MLAT_ENABLED=$2
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35m"
EOF
}

# --- dispatch_mlat ---

@test "dispatch_mlat: missing subcommand dies" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/mlat.sh'
        dispatch_mlat
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'mlat requires a subcommand'* ]]
}

@test "dispatch_mlat: unknown subcommand dies" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/mlat.sh'
        dispatch_mlat frobnitz
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'unknown mlat subcommand: frobnitz'* ]]
}

# --- disable / enable round-trip ---

@test "disable flips MLAT_ENABLED true→false, preserves MLAT_USER, restarts service" {
    write_feed_env "alice" "true"
    ROOT="/"  # exercise the systemctl path; only safe because PATH-stub captures it
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"

    # Override feed_env_path to point inside ROOT_DIR (the helper resolves
    # off /etc/airplanes which would be the host's real path with ROOT='/').
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_disable

    grep -q '^MLAT_USER="alice"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^MLAT_ENABLED=false$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-mlat$' "$SYSTEMCTL_LOG"
}

@test "enable flips MLAT_ENABLED false→true, preserves MLAT_USER, restarts service" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_enable

    grep -q '^MLAT_USER="alice"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^MLAT_ENABLED=true$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-mlat$' "$SYSTEMCTL_LOG"
}

@test "enable with empty MLAT_USER fills in Anonymous default" {
    write_feed_env "" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_enable

    [ "$status" -eq 0 ]
    [[ "$output" == *'MLAT_USER was empty; filling in with default "Anonymous"'* ]]
    grep -q '^MLAT_USER="Anonymous"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^MLAT_ENABLED=true$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "disable preserves MLAT_USER even when empty (no Anonymous fill on disable)" {
    write_feed_env "" "true"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_disable

    # MLAT_USER stays empty on disable — only enable triggers the fallback,
    # since the runtime doesn't strict-fail empty MLAT_USER while disabled.
    grep -q '^MLAT_USER=""$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^MLAT_ENABLED=false$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "round-trip disable→enable restores the original MLAT_USER" {
    write_feed_env "william34-london" "true"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_disable
    grep -q '^MLAT_USER="william34-london"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^MLAT_ENABLED=false$' "$ROOT_DIR/etc/airplanes/feed.env"

    apl_feed_mlat_enable
    grep -q '^MLAT_USER="william34-london"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^MLAT_ENABLED=true$' "$ROOT_DIR/etc/airplanes/feed.env"
}

# --- error paths ---

@test "missing feed.env: enable dies with documented message" {
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]

    run apl_feed_mlat_enable

    [ "$status" -ne 0 ]
    [[ "$output" == *'feed.env not found'* ]]
    [[ "$output" == *'run setup first'* ]]
}

@test "unmigrated feed.env (USER= without MLAT_USER) dies with documented message" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
USER="alice"
LATITUDE="52.52"
EOF
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_disable

    [ "$status" -ne 0 ]
    [[ "$output" == *'feed.env at'* ]]
    [[ "$output" == *'unmigrated'* ]]
    [[ "$output" == *'/usr/local/share/airplanes/update.sh'* ]]
}

# --- restart-skip semantics ---

@test "AIRPLANES_BUILD_MODE=1 skips the systemctl restart (file edits still happen)" {
    write_feed_env "alice" "true"
    ROOT="/"
    AIRPLANES_BUILD_MODE=1
    export AIRPLANES_BUILD_MODE
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_disable

    [ "$status" -eq 0 ]
    grep -q '^MLAT_ENABLED=false$' "$ROOT_DIR/etc/airplanes/feed.env"
    [ ! -f "$SYSTEMCTL_LOG" ] || ! grep -q 'restart' "$SYSTEMCTL_LOG"
    [[ "$output" == *'AIRPLANES_BUILD_MODE'* ]]
}

@test "ROOT != / skips the systemctl restart (file edits still happen)" {
    write_feed_env "alice" "true"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_disable

    [ "$status" -eq 0 ]
    grep -q '^MLAT_ENABLED=false$' "$ROOT_DIR/etc/airplanes/feed.env"
    [ ! -f "$SYSTEMCTL_LOG" ] || ! grep -q 'restart' "$SYSTEMCTL_LOG"
    [[ "$output" == *"--root=$ROOT_DIR"* ]]
}
