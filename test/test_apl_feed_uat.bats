#!/usr/bin/env bats

# Per-module tests for scripts/apl-feed/uat.sh. Mirrors test_apl_feed_mlat.bats
# in shape: source common.sh + uat.sh, stub systemctl, point ROOT at a
# scratch tree containing /etc/airplanes/feed.env.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    INSTALLED_UNITS_FILE="$ROOT_DIR/installed-units"
    FOREIGN_UNITS_FILE="$ROOT_DIR/foreign-units"
    mkdir -p "$TMPDIR" "$STUB_DIR" "$ROOT_DIR/etc/airplanes"
    export TMPDIR

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/configure-validators.sh"
    # shellcheck source=../scripts/lib/feed-env-keys.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-keys.sh"
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-apply.sh"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/uat.sh
    source "$LIB_DIR/uat.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    # Override feed_env_lock_path so the apply library opens the lock
    # in the scratch tree rather than /run/airplanes.
    APL_TEST_LOCK_FILE="$ROOT_DIR/feed-env.lock"
    feed_env_lock_path() { printf '%s\n' "$APL_TEST_LOCK_FILE"; }

    # Default: airplanes-feed always installed (feed daemon, present on
    # both standalone and image installs). dump978-fa + airplanes-978
    # are NOT installed by default — those are image-only. Tests can
    # `mark_unit_installed dump978-fa` to flip to the image-host shape.
    : > "$INSTALLED_UNITS_FILE"
    printf '%s\n' airplanes-feed > "$INSTALLED_UNITS_FILE"

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
case "\$1" in
    cat)
        unit="\${@: -1}"
        # Foreign units (e.g. FlightAware's dump978-fa on a PiAware box)
        # exist but ExecStart a path outside /opt/airplanes/current/share/airplanes/,
        # so the apply lib's ownership gate must skip them.
        if grep -Fxq "\$unit" "$FOREIGN_UNITS_FILE" 2>/dev/null; then
            printf 'ExecStart=/usr/bin/%s\n' "\$unit"
            exit 0
        fi
        if grep -Fxq "\$unit" "$INSTALLED_UNITS_FILE" 2>/dev/null; then
            printf 'ExecStart=/opt/airplanes/current/share/airplanes/%s.sh\n' "\$unit"
            exit 0
        fi
        exit 1
        ;;
    is-active) echo active ;;
    restart)
        # If the unit isn't in the installed list, fail like real systemctl
        # would. _uat_restart_services has separate handling for ALWAYS vs
        # OPTIONAL units, but the OPTIONAL path gates on cat first.
        unit="\${@: -1}"
        if [[ "\$unit" == "airplanes-feed" ]]; then exit 0; fi
        if grep -Fxq "\$unit" "$INSTALLED_UNITS_FILE" 2>/dev/null; then exit 0; fi
        echo "Unit \$unit not found." >&2
        exit 5
        ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    # No-op logger stub so the apply-time journald audit doesn't reach
    # the host's real /dev/log.
    cat > "$STUB_DIR/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/logger"
    PATH="$STUB_DIR:$PATH"
    export PATH

    # USB probe surface for setup-tests that exercise _uat_probe_serial.
    USB_ROOT="$ROOT_DIR/usb-devices"
    mkdir -p "$USB_ROOT"
    APL_FEED_UAT_USB_SERIAL_GLOB="$USB_ROOT/*/serial"
    export APL_FEED_UAT_USB_SERIAL_GLOB
}

teardown() {
    rm -rf "$ROOT_DIR"
}

mark_unit_installed() {
    printf '%s\n' "$1" >> "$INSTALLED_UNITS_FILE"
}

# A unit that exists on the host but belongs to a third-party package
# (ExecStart outside /opt/airplanes/current/share/airplanes/), e.g. FlightAware's
# dump978-fa on a PiAware install.
mark_unit_foreign() {
    printf '%s\n' "$1" >> "$FOREIGN_UNITS_FILE"
}

plug_sdr() {
    local serial="$1" devname="${2:-usb1-dev0}"
    mkdir -p "$USB_ROOT/$devname"
    printf '%s' "$serial" > "$USB_ROOT/$devname/serial"
}

write_feed_env() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<'EOF'
INPUT="127.0.0.1:30005"
MLAT_USER="Anonymous"
MLAT_ENABLED=true
MLAT_PRIVATE=false
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="35"
GEO_CONFIGURED=true
EOF
}

# --- dispatch_uat ---

@test "dispatch_uat: missing subcommand shows 978 help (exit 2)" {
    run dispatch_uat
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed 978 <subcommand>'* ]]
}

@test "dispatch_uat: unknown subcommand dies" {
    run dispatch_uat frobnitz
    [ "$status" -ne 0 ]
    [[ "$output" == *'unknown 978 subcommand: frobnitz'* ]]
}

# --- 978 enable / disable round-trip ---

@test "enable: writes UAT_INPUT and restarts airplanes-feed" {
    write_feed_env
    ROOT="/"  # exercise systemctl path; PATH-stub captures it
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_enable
    [ "$status" -eq 0 ]
    grep -q '^UAT_INPUT="127.0.0.1:30978"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-feed$' "$SYSTEMCTL_LOG"
}

@test "enable: image-only units are restarted when present" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    mark_unit_installed dump978-fa
    mark_unit_installed airplanes-978

    run apl_feed_uat_enable
    [ "$status" -eq 0 ]
    grep -q '^systemctl restart dump978-fa$' "$SYSTEMCTL_LOG"
    grep -q '^systemctl restart airplanes-978$' "$SYSTEMCTL_LOG"
}

@test "enable: image-only units are skipped on standalone-feed host" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    # INSTALLED_UNITS_FILE is empty — neither dump978-fa nor airplanes-978
    # is present. The restart for those must be skipped (not attempted).

    run apl_feed_uat_enable
    [ "$status" -eq 0 ]
    # `! grep -q ...` is a tested context where set -e is suppressed; that
    # would silently mask a real regression. `run` + status check is the
    # reliable form.
    run grep -q '^systemctl restart dump978-fa$' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
    run grep -q '^systemctl restart airplanes-978$' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
    grep -q '^systemctl restart airplanes-feed$' "$SYSTEMCTL_LOG"
}

@test "enable: a foreign dump978-fa unit is never restarted" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    # PiAware shape: dump978-fa.service exists but is FlightAware's unit.
    # `systemctl restart` would START it even when stopped, and with FA's
    # unpinned SDR config it can grab the dongle another decoder is using.
    mark_unit_foreign dump978-fa

    run apl_feed_uat_enable
    [ "$status" -eq 0 ]
    grep -q '^UAT_INPUT="127.0.0.1:30978"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-feed$' "$SYSTEMCTL_LOG"
    run grep -q '^systemctl restart dump978-fa$' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
    # The skip is silent — not surfaced as a failed restart.
    [[ "$output" != *'failed to restart'* ]]
}

@test "disable: a foreign dump978-fa unit is never restarted" {
    write_feed_env
    printf 'UAT_INPUT="127.0.0.1:30978"\n' >> "$ROOT_DIR/etc/airplanes/feed.env"
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    mark_unit_foreign dump978-fa

    run apl_feed_uat_disable
    [ "$status" -eq 0 ]
    grep -q '^UAT_INPUT=""$' "$ROOT_DIR/etc/airplanes/feed.env"
    run grep -q '^systemctl restart dump978-fa$' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
}

@test "enable --serial / --gain pin the wrapper defaults in feed.env" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_enable --serial "00000978" --gain "40.0"
    [ "$status" -eq 0 ]
    grep -q '^DUMP978_SDR_SERIAL="00000978"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^DUMP978_GAIN="40.0"$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "disable: clears UAT_INPUT, preserves DUMP978_SDR_SERIAL / DUMP978_GAIN" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    # Seed both knobs so we can confirm disable doesn't wipe them.
    apl_feed_uat_enable --serial "00000978" --gain "40.0"
    : > "$SYSTEMCTL_LOG"

    run apl_feed_uat_disable
    [ "$status" -eq 0 ]
    grep -q '^UAT_INPUT=""$' "$ROOT_DIR/etc/airplanes/feed.env"
    # Disable uses the `-` sentinel so the serial/gain lines stay verbatim.
    grep -q '^DUMP978_SDR_SERIAL="00000978"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^DUMP978_GAIN="40.0"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^systemctl restart airplanes-feed$' "$SYSTEMCTL_LOG"
}

@test "enable preserves unrelated keys (MLAT_USER, LATITUDE, etc.)" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_uat_enable --serial "978" --gain "42.1"

    grep -q '^MLAT_USER="Anonymous"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE "^MLAT_ENABLED=(true|\"true\")$" "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE "^MLAT_PRIVATE=(false|\"false\")$" "$ROOT_DIR/etc/airplanes/feed.env"
    grep -q '^LATITUDE="52.52"$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "enable twice is idempotent on UAT_INPUT (no duplicate line)" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    apl_feed_uat_enable
    apl_feed_uat_enable
    local count
    count="$(grep -c '^UAT_INPUT=' "$ROOT_DIR/etc/airplanes/feed.env")"
    [ "$count" -eq 1 ]
}

# --- validation ---

@test "enable --serial with shell metacharacters dies" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_enable --serial 'evil;rm -rf /'
    [ "$status" -ne 0 ]
    [[ "$output" == *'DUMP978_SDR_SERIAL'* ]]
    # feed.env must NOT have been touched.
    ! grep -q '^DUMP978_SDR_SERIAL=' "$ROOT_DIR/etc/airplanes/feed.env"
    ! grep -q '^UAT_INPUT="127.0.0.1:30978"$' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "enable --serial that's too long dies" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_enable --serial "$(printf 'a%.0s' {1..33})"
    [ "$status" -ne 0 ]
    [[ "$output" == *'DUMP978_SDR_SERIAL'* ]]
}

@test "enable --gain out of range dies" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_enable --gain "61"
    [ "$status" -ne 0 ]
    [[ "$output" == *'DUMP978_GAIN'* ]]

    run apl_feed_uat_enable --gain "auto"
    [ "$status" -ne 0 ]
    [[ "$output" == *'DUMP978_GAIN'* ]]
}

@test "enable --serial accepts the canonical 8-char hex form" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_enable --serial "00000978"
    [ "$status" -eq 0 ]
    grep -q '^DUMP978_SDR_SERIAL="00000978"$' "$ROOT_DIR/etc/airplanes/feed.env"
}

# --- _uat_probe_serial ---

@test "probe: returns 0 when /sys reports a matching serial" {
    plug_sdr "978" "usb1-dev1"
    run _uat_probe_serial "978"
    [ "$status" -eq 0 ]
}

@test "probe: returns 1 when no device has the requested serial" {
    plug_sdr "1090" "usb1-dev1"
    run _uat_probe_serial "978"
    [ "$status" -ne 0 ]
}

@test "probe: returns 1 when /sys is empty" {
    run _uat_probe_serial "978"
    [ "$status" -ne 0 ]
}

# --- status ---

@test "status: reports disabled when UAT_INPUT is empty" {
    write_feed_env  # has no UAT_INPUT line at all
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_status
    [ "$status" -eq 0 ]
    [[ "$output" == *'978: disabled'* ]]
}

@test "status: reports enabled and shows the configured serial / gain" {
    write_feed_env
    ROOT="/"
    feed_env_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_write_path() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    apl_feed_uat_enable --serial "00000978" --gain "40.0"

    run apl_feed_uat_status
    [ "$status" -eq 0 ]
    [[ "$output" == *'978: enabled'* ]]
    [[ "$output" == *'DUMP978_SDR_SERIAL: 00000978'* ]]
    [[ "$output" == *'DUMP978_GAIN:       40.0'* ]]
}

@test "status: marks image-only units as 'not installed' on standalone-feed" {
    write_feed_env
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }

    run apl_feed_uat_status
    [ "$status" -eq 0 ]
    [[ "$output" == *'dump978-fa'*'not installed (image-only)'* ]]
    [[ "$output" == *'airplanes-978'*'not installed (image-only)'* ]]
}

@test "status: shows systemd state for image-managed 978 units" {
    write_feed_env
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    mark_unit_installed dump978-fa.service
    mark_unit_installed airplanes-978.service

    run apl_feed_uat_status
    [ "$status" -eq 0 ]
    [[ "$output" == *'dump978-fa.service'*'active'* ]]
    [[ "$output" == *'airplanes-978.service'*'active'* ]]
}

@test "status: flags a foreign dump978-fa unit as not managed" {
    write_feed_env
    feed_env_paths() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.env"; }
    # PiAware shape: the unit name exists but it's FlightAware's — its
    # systemd state must not be presented as our 978 chain's state.
    mark_unit_foreign dump978-fa.service

    run apl_feed_uat_status
    [ "$status" -eq 0 ]
    [[ "$output" == *'dump978-fa.service'*'owned by another package (not managed)'* ]]
    [[ "$output" == *'airplanes-978'*'not installed (image-only)'* ]]
}

@test "bridged-legacy: _uat_apply targets canonical feed.env, not boot config" {
    # Same shape as the mlat bridged-legacy regression — guards against
    # the writer side resolving via feed_env_path()'s reader fallback
    # when feed.env doesn't exist yet on a bridged box. Uses a canonical
    # key (UAT_INPUT) that apl_feed_import_legacy_config understands so
    # this fixture is also a valid input to that command.
    rm -rf "$ROOT_DIR/etc/airplanes"
    mkdir -p "$ROOT_DIR/etc/airplanes" "$ROOT_DIR/boot"
    : > "$ROOT_DIR/etc/airplanes/image-install"
    cat > "$ROOT_DIR/boot/airplanes-config.txt" <<'EOF'
UAT_INPUT=127.0.0.1:30978
EOF
    local before
    before="$(cat "$ROOT_DIR/boot/airplanes-config.txt")"

    APPLY_ARGS=""
    apl_feed_apply() {
        APPLY_ARGS="$*"
        APL_APPLY_STATUS=no_change
        return 0
    }

    apl_feed_uat_disable

    [[ "$APPLY_ARGS" == *"--feed-env $ROOT_DIR/etc/airplanes/feed.env"* ]]
    [[ "$APPLY_ARGS" != *"--feed-env $ROOT_DIR/boot/airplanes-config.txt"* ]]
    [ "$before" = "$(cat "$ROOT_DIR/boot/airplanes-config.txt")" ]
}
