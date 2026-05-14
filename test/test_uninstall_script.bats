#!/usr/bin/env bats

setup() {
    UNINSTALL="$BATS_TEST_DIRNAME/../uninstall.sh"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    TAR1090_LOG="$ROOT_DIR/tar1090.log"
    mkdir -p "$STUB_DIR"

    # systemctl stub: log every invocation to a file path passed in via env.
    # Using an env-var file path (not stdout/stderr) is required because the
    # script invokes `systemctl disable --now airplanes-mlat2 &>/dev/null`,
    # which would silence any stdio-based capture.
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

run_uninstall() {
    run env -i \
        PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR" \
        SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        TAR1090_LOG="$TAR1090_LOG" \
        bash "$UNINSTALL"
}

# Drop a sandboxed tar1090 uninstall stub at $ROOT/usr/local/share/tar1090/uninstall.sh.
# The stub appends its argv to TAR1090_LOG so callers can detect whether the
# real script invoked it.
write_tar1090_stub() {
    local dir="$ROOT_DIR/usr/local/share/tar1090"
    mkdir -p "$dir"
    cat > "$dir/uninstall.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TAR1090_LOG"
exit 0
SH
    chmod +x "$dir/uninstall.sh"
}

@test "uninstall.sh runs idempotently with no prior install" {
    run_uninstall

    [ "$status" -eq 0 ]
    [ -d "$ROOT_DIR/usr/local/share/airplanes" ]
    [ -z "$(ls -A "$ROOT_DIR/usr/local/share/airplanes")" ]
    [ ! -e "$ROOT_DIR/etc/airplanes/feeder-id" ]
    [ -f "$SYSTEMCTL_LOG" ]
}

@test "uninstall.sh disables services in mlat -> mlat2 -> feed -> diagnostics -> config-sync order, then daemon-reloads, exactly eight calls" {
    run_uninstall

    [ "$status" -eq 0 ]

    local first second third fourth fifth sixth seventh eighth count
    first="$(sed -n '1p' "$SYSTEMCTL_LOG")"
    second="$(sed -n '2p' "$SYSTEMCTL_LOG")"
    third="$(sed -n '3p' "$SYSTEMCTL_LOG")"
    fourth="$(sed -n '4p' "$SYSTEMCTL_LOG")"
    fifth="$(sed -n '5p' "$SYSTEMCTL_LOG")"
    sixth="$(sed -n '6p' "$SYSTEMCTL_LOG")"
    seventh="$(sed -n '7p' "$SYSTEMCTL_LOG")"
    eighth="$(sed -n '8p' "$SYSTEMCTL_LOG")"
    count="$(wc -l < "$SYSTEMCTL_LOG" | tr -d '[:space:]')"
    [ "$first" = "disable --now airplanes-mlat" ]
    [ "$second" = "disable --now airplanes-mlat2" ]
    [ "$third" = "disable --now airplanes-feed" ]
    [ "$fourth" = "disable --now airplanes-diagnostics.timer" ]
    [ "$fifth" = "disable --now airplanes-diagnostics.service" ]
    [ "$sixth" = "disable --now airplanes-config-sync.timer" ]
    [ "$seventh" = "disable --now airplanes-config-sync.service" ]
    [ "$eighth" = "daemon-reload" ]
    [ "$count" = "8" ]
}

@test "uninstall.sh removes the airplanes systemd unit files and leaves others alone" {
    mkdir -p "$ROOT_DIR/lib/systemd/system"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-mlat.service"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-mlat2.service"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-feed.service"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.service"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.timer"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-config-sync.service"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-config-sync.timer"
    : > "$ROOT_DIR/lib/systemd/system/keep-this.service"

    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-mlat.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-mlat2.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-feed.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.timer" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-config-sync.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-config-sync.timer" ]
    [ -e "$ROOT_DIR/lib/systemd/system/keep-this.service" ]
}

@test "uninstall.sh does not touch image-baked airplanes-first-run.service" {
    # airplanes-first-run.service ships in the image rootfs (airplanes-live/image),
    # not from feed. Feed's units only declare After=airplanes-first-run.service
    # for ordering. A regression here would brick first-boot on image feeders
    # whose user has run uninstall.
    mkdir -p "$ROOT_DIR/etc/systemd/system"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-first-run.service"
    mkdir -p "$ROOT_DIR/etc/systemd/system/default.target.wants"
    ln -sfn '/etc/systemd/system/airplanes-first-run.service' \
        "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-first-run.service"

    run_uninstall

    [ "$status" -eq 0 ]
    [ -e "$ROOT_DIR/etc/systemd/system/airplanes-first-run.service" ]
    [ -L "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-first-run.service" ]
}

@test "uninstall.sh wipes IPATH contents and recreates the directory" {
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes/git/sub"
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes/.cache"
    : > "$ROOT_DIR/usr/local/share/airplanes/marker"
    : > "$ROOT_DIR/usr/local/share/airplanes/git/sub/file"

    run_uninstall

    [ "$status" -eq 0 ]
    [ -d "$ROOT_DIR/usr/local/share/airplanes" ]
    [ -z "$(ls -A "$ROOT_DIR/usr/local/share/airplanes")" ]
}

@test "canonical feeder-id is preserved across wipe and the legacy symlink is recreated" {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    printf 'canonical-uuid-content\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes/git"
    : > "$ROOT_DIR/usr/local/share/airplanes/git/marker"

    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/usr/local/share/airplanes/git/marker" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "canonical-uuid-content" ]
    [ -L "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid" ]
    [ "$(readlink "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid")" = "../../../../etc/airplanes/feeder-id" ]
}

@test "legacy fallback is materialized to canonical when canonical is absent" {
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes"
    printf 'legacy-uuid-content\n' > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"

    run_uninstall

    [ "$status" -eq 0 ]
    [ -f "$ROOT_DIR/etc/airplanes/feeder-id" ]

    # Byte-exact comparison: legacy was UUID + single newline; output should match exactly.
    local expected="$ROOT_DIR/expected.bin"
    printf 'legacy-uuid-content\n' > "$expected"
    cmp "$expected" "$ROOT_DIR/etc/airplanes/feeder-id"

    # Materialized canonical must be 0644.
    [ "$(stat -c '%a' "$ROOT_DIR/etc/airplanes/feeder-id")" = "644" ]

    [ -L "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid" ]
    [ "$(readlink "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid")" = "../../../../etc/airplanes/feeder-id" ]
}

@test "legacy without a trailing newline is normalized to one trailing newline (UUID-format contract)" {
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes"
    printf 'legacy-no-newline' > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"

    run_uninstall

    [ "$status" -eq 0 ]
    [ -f "$ROOT_DIR/etc/airplanes/feeder-id" ]

    local expected="$ROOT_DIR/expected.bin"
    printf 'legacy-no-newline\n' > "$expected"
    cmp "$expected" "$ROOT_DIR/etc/airplanes/feeder-id"
}

@test "empty legacy file still triggers materialization and symlink restoration" {
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes"
    : > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"

    run_uninstall

    [ "$status" -eq 0 ]
    # Canonical materialized as a one-newline file (matches the contract).
    [ -f "$ROOT_DIR/etc/airplanes/feeder-id" ]
    local expected="$ROOT_DIR/expected.bin"
    printf '\n' > "$expected"
    cmp "$expected" "$ROOT_DIR/etc/airplanes/feeder-id"
    # Legacy symlink restored on top of the wiped IPATH.
    [ -L "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid" ]
}

@test "legacy UUID content is not leaked into trace output by set -x" {
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes"
    local secret_marker="LEGACY-LEAK-CANARY-9F3B7A"
    printf '%s\n' "$secret_marker" > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"

    run_uninstall

    [ "$status" -eq 0 ]
    # The materialized file must contain the legacy content...
    grep -q "$secret_marker" "$ROOT_DIR/etc/airplanes/feeder-id"
    # ...but the bash trace must not.
    if printf '%s' "$output" | grep -q "$secret_marker"; then
        echo "secret marker leaked into trace output: $output" >&2
        return 1
    fi
}

@test "canonical wins over legacy when both exist with different values" {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes"
    printf 'CANONICAL-UUID\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    printf 'legacy-different\n' > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"

    run_uninstall

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "CANONICAL-UUID" ]
    [ -L "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid" ]
    [ "$(readlink "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid")" = "../../../../etc/airplanes/feeder-id" ]
}

@test "no feeder-id is created when neither canonical nor legacy existed" {
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/etc/airplanes/feeder-id" ]
    [ ! -e "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid" ]
}

@test "tar1090 uninstall hook fires when html-airplanes/ exists, with sandboxed gate AND invocation" {
    write_tar1090_stub
    mkdir -p "$ROOT_DIR/usr/local/share/tar1090/html-airplanes"

    run_uninstall

    [ "$status" -eq 0 ]
    [ -f "$TAR1090_LOG" ]
    [ "$(cat "$TAR1090_LOG")" = "airplanes" ]
}

@test "tar1090 uninstall hook is skipped when html-airplanes/ is absent" {
    write_tar1090_stub
    # Note: html-airplanes/ deliberately not created.

    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -f "$TAR1090_LOG" ]
}

@test "tar1090 hook with html-airplanes/ but missing uninstall.sh does not abort the rest of the script" {
    # html-airplanes/ exists but the tar1090 uninstall script is absent.
    # The script must keep going (it has no set -e) and still wipe IPATH +
    # daemon-reload + report success.
    mkdir -p "$ROOT_DIR/usr/local/share/tar1090/html-airplanes"
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes/git"
    : > "$ROOT_DIR/usr/local/share/airplanes/git/marker"

    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/usr/local/share/airplanes/git/marker" ]
    grep -q "daemon-reload" "$SYSTEMCTL_LOG"
}

@test "tar1090 hook is best-effort: nonzero exit does not abort the script" {
    mkdir -p "$ROOT_DIR/usr/local/share/tar1090/html-airplanes"
    cat > "$ROOT_DIR/usr/local/share/tar1090/uninstall.sh" <<'SH'
#!/usr/bin/env bash
exit 7
SH
    chmod +x "$ROOT_DIR/usr/local/share/tar1090/uninstall.sh"

    mkdir -p "$ROOT_DIR/usr/local/share/airplanes/git"
    : > "$ROOT_DIR/usr/local/share/airplanes/git/marker"

    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/usr/local/share/airplanes/git/marker" ]
    grep -q "daemon-reload" "$SYSTEMCTL_LOG"
}

@test "tar1090 hook runs before IPATH is wiped (ordering guard for tar1090 dependencies on IPATH)" {
    mkdir -p "$ROOT_DIR/usr/local/share/tar1090/html-airplanes"
    cat > "$ROOT_DIR/usr/local/share/tar1090/uninstall.sh" <<'SH'
#!/usr/bin/env bash
if [[ -f "$AIRPLANES_ROOT/usr/local/share/airplanes/marker-during-hook" ]]; then
    printf 'IPATH-INTACT\n' >> "$TAR1090_LOG"
else
    printf 'IPATH-WIPED\n' >> "$TAR1090_LOG"
fi
exit 0
SH
    chmod +x "$ROOT_DIR/usr/local/share/tar1090/uninstall.sh"

    mkdir -p "$ROOT_DIR/usr/local/share/airplanes"
    : > "$ROOT_DIR/usr/local/share/airplanes/marker-during-hook"

    run_uninstall

    [ "$status" -eq 0 ]
    [ -f "$TAR1090_LOG" ]
    [ "$(cat "$TAR1090_LOG")" = "IPATH-INTACT" ]
}
