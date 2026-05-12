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
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/configure-validators.sh"
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
MLAT_PRIVATE=false
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35m"
GEO_CONFIGURED=true
EOF
}

write_feed_env_with_private() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
MLAT_USER="$1"
MLAT_ENABLED=$2
MLAT_PRIVATE=$3
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35m"
GEO_CONFIGURED=true
EOF
}

# Variants used by GEO-gate tests on `apl_feed_mlat_enable`.
write_feed_env_no_geo_flag() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
MLAT_USER="$1"
MLAT_ENABLED=$2
MLAT_PRIVATE=false
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35m"
GEO_CONFIGURED=false
EOF
}

write_feed_env_no_axis() {
    # $1 user, $2 enabled, $3 axis-to-blank (LATITUDE|LONGITUDE|ALTITUDE)
    local user="$1" enabled="$2" blank="$3"
    local lat='"52.52"' lon='"13.40"' alt='"35m"'
    case "$blank" in
        LATITUDE)  lat='""' ;;
        LONGITUDE) lon='""' ;;
        ALTITUDE)  alt='""' ;;
    esac
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
MLAT_USER="$user"
MLAT_ENABLED=$enabled
MLAT_PRIVATE=false
LATITUDE=$lat
LONGITUDE=$lon
ALTITUDE=$alt
GEO_CONFIGURED=true
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

@test "enable preserves empty MLAT_USER — daemon Anonymous-<short-id> fallback owns the runtime name" {
    write_feed_env "" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_enable

    [ "$status" -eq 0 ]
    grep -q '^MLAT_USER=""$' "$ROOT_DIR/etc/airplanes/feed.env"
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

# --- mlat private subcommand ---

@test "dispatch_mlat private: missing subcommand dies" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/mlat.sh'
        dispatch_mlat private
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'mlat private requires a subcommand'* ]]
}

@test "dispatch_mlat private: unknown subcommand dies" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/mlat.sh'
        dispatch_mlat private frobnitz
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'unknown mlat private subcommand: frobnitz'* ]]
}

@test "private enable flips MLAT_PRIVATE false→true, preserves other keys, restarts service" {
    write_feed_env_with_private "alice" "true" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_private_enable

    [ "$status" -eq 0 ]
    grep -qx 'MLAT_PRIVATE=true' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_USER="alice"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_ENABLED=true' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-mlat$' "$SYSTEMCTL_LOG"
}

@test "private disable flips MLAT_PRIVATE true→false, preserves other keys" {
    write_feed_env_with_private "alice" "true" "true"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_private_disable

    [ "$status" -eq 0 ]
    grep -qx 'MLAT_PRIVATE=false' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_USER="alice"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_ENABLED=true' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "private round-trip enable→disable→enable returns to true" {
    write_feed_env_with_private "alice" "true" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_private_enable
    grep -qx 'MLAT_PRIVATE=true' "$ROOT_DIR/etc/airplanes/feed.env"

    apl_feed_mlat_private_disable
    grep -qx 'MLAT_PRIVATE=false' "$ROOT_DIR/etc/airplanes/feed.env"

    apl_feed_mlat_private_enable
    grep -qx 'MLAT_PRIVATE=true' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "private enable: missing feed.env dies with documented message" {
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]

    run apl_feed_mlat_private_enable

    [ "$status" -ne 0 ]
    [[ "$output" == *'feed.env not found'* ]]
    [[ "$output" == *'run setup first'* ]]
}

@test "private enable: unmigrated feed.env (PRIVACY= without MLAT_PRIVATE=) dies" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
MLAT_USER="alice"
MLAT_ENABLED=true
PRIVACY="--privacy"
LATITUDE="52.52"
EOF
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_private_disable

    [ "$status" -ne 0 ]
    [[ "$output" == *'unmigrated'* ]]
    [[ "$output" == *'no MLAT_PRIVATE='* ]]
    [[ "$output" == *'/usr/local/share/airplanes/update.sh'* ]]
}

@test "private enable: rewrite leaves no duplicate MLAT_PRIVATE lines" {
    write_feed_env_with_private "alice" "true" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_private_enable
    apl_feed_mlat_private_enable

    [ "$(grep -c '^MLAT_PRIVATE=' "$ROOT_DIR/etc/airplanes/feed.env")" -eq 1 ]
}

@test "private enable under AIRPLANES_BUILD_MODE=1 skips restart, edits file" {
    write_feed_env_with_private "alice" "true" "false"
    ROOT="/"
    AIRPLANES_BUILD_MODE=1
    export AIRPLANES_BUILD_MODE
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_private_enable

    [ "$status" -eq 0 ]
    grep -qx 'MLAT_PRIVATE=true' "$ROOT_DIR/etc/airplanes/feed.env"
    [ ! -f "$SYSTEMCTL_LOG" ] || ! grep -q 'restart' "$SYSTEMCTL_LOG"
    [[ "$output" == *'AIRPLANES_BUILD_MODE'* ]]
}

# --- mlat enable geo gate (α: belt-and-braces; canonical source GEO_CONFIGURED) ---

@test "enable refuses when GEO_CONFIGURED=false" {
    write_feed_env_no_geo_flag "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_enable

    [ "$status" -ne 0 ]
    [[ "$output" == *'location not configured'* ]]
    [[ "$output" == *'apl-feed mlat setup'* ]]
    # File untouched.
    grep -qx 'MLAT_ENABLED=false' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "enable refuses when GEO_CONFIGURED is missing" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35m"
EOF
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_enable

    [ "$status" -ne 0 ]
    [[ "$output" == *'location not configured'* ]]
}

@test "enable refuses when LATITUDE is empty (belt-and-braces)" {
    write_feed_env_no_axis "alice" "false" LATITUDE
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_enable

    [ "$status" -ne 0 ]
    [[ "$output" == *'LATITUDE is empty'* ]]
}

@test "enable refuses when ALTITUDE is empty (belt-and-braces)" {
    write_feed_env_no_axis "alice" "false" ALTITUDE
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_enable

    [ "$status" -ne 0 ]
    [[ "$output" == *'ALTITUDE is empty'* ]]
}

# --- mlat user ---

@test "mlat user <name>: writes MLAT_USER, preserves MLAT_ENABLED, restarts service" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_user bob-123

    grep -qx 'MLAT_USER="bob-123"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_ENABLED=false' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-mlat$' "$SYSTEMCTL_LOG"
}

@test "mlat user --clear: writes empty MLAT_USER" {
    write_feed_env "alice" "true"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_user --clear

    grep -qx 'MLAT_USER=""' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'MLAT_ENABLED=true' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "mlat user: rejects name with space" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_user "alice rabbit"

    [ "$status" -ne 0 ]
    [[ "$output" == *'MLAT_USER must match'* ]]
    grep -qx 'MLAT_USER="alice"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "mlat user: rejects name >64 chars" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    local long
    long="$(printf 'a%.0s' {1..65})"
    run apl_feed_mlat_user "$long"

    [ "$status" -ne 0 ]
    [[ "$output" == *'MLAT_USER must match'* ]]
}

@test "mlat user: rejects shell-metachar even when regex-passing" {
    # The regex prevents most metas anyway, but assert that universal-reject
    # catches the cross-cutting cases (\\ would actually fail the regex too).
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_user 'bad$name'

    [ "$status" -ne 0 ]
    [[ "$output" == *'MLAT_USER must match'* ]] || [[ "$output" == *'forbidden shell metacharacter'* ]]
}

@test "mlat user: --clear with a positional name dies" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_user --clear bob

    [ "$status" -ne 0 ]
    [[ "$output" == *'mutually exclusive'* ]]
}

@test "mlat user: no args dies" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_user

    [ "$status" -ne 0 ]
    [[ "$output" == *'provide a name or use --clear'* ]]
}

# --- mlat geo ---

@test "mlat geo writes four keys, derives GEO_CONFIGURED=true for non-zero coords, restarts" {
    write_feed_env_no_geo_flag "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_geo 48.137 11.575 520m

    grep -qx 'LATITUDE="48.137"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'LONGITUDE="11.575"' "$ROOT_DIR/etc/airplanes/feed.env"
    # normalize_altitude is a no-op for the `m` suffix; only `ft` gets converted.
    grep -qx 'ALTITUDE="520m"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qx 'GEO_CONFIGURED=true' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-mlat$' "$SYSTEMCTL_LOG"
}

@test "mlat geo at (0, 0) derives GEO_CONFIGURED=false (Atlantic placeholder)" {
    write_feed_env_no_geo_flag "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_geo 0 0 0m

    grep -qx 'GEO_CONFIGURED=false' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "mlat geo at (0.0, 0) still derives false (decimal-zero forms)" {
    write_feed_env_no_geo_flag "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_mlat_geo 0.0 -0 0m

    grep -qx 'GEO_CONFIGURED=false' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "mlat geo rejects invalid latitude" {
    write_feed_env_no_geo_flag "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_geo 91 0 0m

    [ "$status" -ne 0 ]
    [[ "$output" == *'LATITUDE must be'* ]]
    # File untouched.
    grep -qx 'GEO_CONFIGURED=false' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "mlat geo rejects wrong arg count" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_mlat_geo 52.5 13.4
    [ "$status" -ne 0 ]
    [[ "$output" == *'exactly three positional args'* ]]

    run apl_feed_mlat_geo 52.5 13.4 120m extra
    [ "$status" -ne 0 ]
    [[ "$output" == *'exactly three positional args'* ]]
}

# --- mlat setup ---

@test "mlat setup: dies on non-TTY stdin with a guidance message" {
    write_feed_env "alice" "false"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    # bats's run captures stdin from a pipe so [[ -t 0 ]] is false.
    run apl_feed_mlat_setup

    [ "$status" -ne 0 ]
    [[ "$output" == *'mlat setup is interactive'* ]]
    [[ "$output" == *'apl-feed mlat geo'* ]]
}

# --- dispatch_mlat new subcommands ---

@test "dispatch_mlat user routes to apl_feed_mlat_user (no name → die)" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/mlat.sh'
        dispatch_mlat user
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'provide a name or use --clear'* ]]
}

@test "dispatch_mlat geo routes to apl_feed_mlat_geo (no args → die)" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/mlat.sh'
        dispatch_mlat geo
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'exactly three positional args'* ]]
}

# --- setup helper (single 7-key transaction) ---

@test "_mlat_rewrite_feed_env_setup writes all seven keys atomically; preserves unrelated" {
    write_feed_env_with_private "alice" "false" "false"
    local feed_env="$ROOT_DIR/etc/airplanes/feed.env"

    _mlat_rewrite_feed_env_setup "$feed_env" \
        "48.137" "11.575" "520m" "true" "bob-99" "true" "true"

    grep -qx 'LATITUDE="48.137"'    "$feed_env"
    grep -qx 'LONGITUDE="11.575"'   "$feed_env"
    grep -qx 'ALTITUDE="520m"'      "$feed_env"
    grep -qx 'GEO_CONFIGURED=true'  "$feed_env"
    grep -qx 'MLAT_USER="bob-99"'   "$feed_env"
    grep -qx 'MLAT_ENABLED=true'    "$feed_env"
    grep -qx 'MLAT_PRIVATE=true'    "$feed_env"
    # The unrelated INPUT key survives unchanged.
    grep -qx 'INPUT="127.0.0.1:30005"' "$feed_env"
}

@test "_mlat_rewrite_feed_env_setup leaves no duplicate keys after rerun" {
    write_feed_env_with_private "alice" "false" "false"
    local feed_env="$ROOT_DIR/etc/airplanes/feed.env"

    _mlat_rewrite_feed_env_setup "$feed_env" "1" "2" "3m" "true" "u1" "true" "false"
    _mlat_rewrite_feed_env_setup "$feed_env" "4" "5" "6m" "true" "u2" "true" "true"

    [ "$(grep -c '^LATITUDE='       "$feed_env")" -eq 1 ]
    [ "$(grep -c '^LONGITUDE='      "$feed_env")" -eq 1 ]
    [ "$(grep -c '^ALTITUDE='       "$feed_env")" -eq 1 ]
    [ "$(grep -c '^GEO_CONFIGURED=' "$feed_env")" -eq 1 ]
    [ "$(grep -c '^MLAT_USER='      "$feed_env")" -eq 1 ]
    [ "$(grep -c '^MLAT_ENABLED='   "$feed_env")" -eq 1 ]
    [ "$(grep -c '^MLAT_PRIVATE='   "$feed_env")" -eq 1 ]
}

@test "_mlat_rewrite_feed_env_setup refuses unmigrated feed.env (no MLAT_PRIVATE=)" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
INPUT="127.0.0.1:30005"
MLAT_USER="alice"
MLAT_ENABLED=false
LATITUDE="0"
LONGITUDE="0"
ALTITUDE="0"
GEO_CONFIGURED=false
EOF
    local feed_env="$ROOT_DIR/etc/airplanes/feed.env"

    run _mlat_rewrite_feed_env_setup "$feed_env" "1" "2" "3m" "true" "u" "true" "true"

    [ "$status" -ne 0 ]
    [[ "$output" == *'no MLAT_PRIVATE='* ]]
    # File untouched.
    grep -qx 'MLAT_ENABLED=false' "$feed_env"
}
