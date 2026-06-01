#!/usr/bin/env bats

# Install/uninstall symmetry: stage the canonical install footprint, run
# uninstall.sh, assert what's removed vs preserved. Catches drift between
# what install/update/configure put down and what uninstall removes.
#
# The footprint enumerated in stage_install_footprint() is the documented
# contract — adding a new install-time write outside $IPATH must come with
# a matching entry here AND a matching `rm` in uninstall.sh.
#
# Companion to test_uninstall_script.bats: that file pins uninstall's
# behavior given specific seeded states; this file pins the install↔uninstall
# round-trip against the full installer footprint.

setup() {
    UNINSTALL="$BATS_TEST_DIRNAME/../uninstall.sh"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    TAR1090_LOG="$ROOT_DIR/tar1090.log"
    USERDEL_LOG="$ROOT_DIR/userdel.log"
    GROUPDEL_LOG="$ROOT_DIR/groupdel.log"
    mkdir -p "$STUB_DIR"

    # Silent systemctl stub — `systemctl disable --now airplanes-mlat2 &>/dev/null`
    # would otherwise drop stdio captures.
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
SH
    chmod +x "$STUB_DIR/systemctl"

    # userdel / groupdel stubs. Uninstall must NOT invoke these for the
    # airplanes-feed account (CLAUDE.md architecture.md: "The original
    # `airplanes` user is intentionally not removed on upgrade — it may be
    # referenced by user-supplied drop-ins or orphan units." Same principle
    # applies to the airplanes-feed account on uninstall.) The log files are
    # only created when the stub is invoked, so absence of the log file is
    # the assertion.
    cat > "$STUB_DIR/userdel" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$USERDEL_LOG"
exit 0
SH
    chmod +x "$STUB_DIR/userdel"

    cat > "$STUB_DIR/groupdel" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GROUPDEL_LOG"
exit 0
SH
    chmod +x "$STUB_DIR/groupdel"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Stage a maximally-realistic post-install state at AIRPLANES_ROOT. The
# optional first argument selects the systemd unit layout:
#   - "manual" (default) — units in /lib/systemd/system, no marker.
#   - "image" — units in /etc/systemd/system, /etc/airplanes/image-install
#     marker present. Mirrors what update.sh produces when IMAGE_SERVICE_LAYOUT
#     is set (either IMAGE_INSTALL=1 or AIRPLANES_BUILD_MODE=1).
#
# Path enumeration sourced from update.sh's install steps:
#   - $IPATH contents: update.sh:474-497, 545, 569-589, 644-651, 716
#   - systemd units: /lib/systemd/system (manual, update.sh:594-596) or
#     /etc/systemd/system (image, update.sh:336 + 594-596)
#   - /usr/local/bin/apl-feed: update.sh:545
#   - /etc/airplanes/ artifacts: update.sh:428,472,569,704; create-uuid.sh;
#     claim-registration.sh:register_claim_secret
#   - /etc/default/airplanes symlink: update-migrations.sh:finalize_legacy_feed_env_migration
#
# Inside $IPATH only a representative sample is staged; `rm -rf $IPATH` wipes
# the entire directory wholesale, so per-file enumeration there has no
# additional signal.
stage_install_footprint() {
    local systemd_layout="${1:-manual}"
    case "$systemd_layout" in
        manual|image) ;;
        *) echo "stage_install_footprint: invalid systemd_layout '$systemd_layout'" >&2; return 2 ;;
    esac

    # $IPATH (= /usr/local/share/airplanes) — wiped wholesale by uninstall.
    local ipath="$ROOT_DIR/usr/local/share/airplanes"
    mkdir -p "$ipath/git"
    mkdir -p "$ipath/apl-feed"
    mkdir -p "$ipath/lib"
    mkdir -p "$ipath/venv/bin"
    mkdir -p "$ipath/mlat-client-git"
    mkdir -p "$ipath/readsb-git"
    : > "$ipath/update.sh"
    : > "$ipath/uninstall.sh"
    : > "$ipath/airplanes-feed.sh"
    : > "$ipath/airplanes-mlat.sh"
    : > "$ipath/apl-feed.sh"
    : > "$ipath/apl-feed/status.sh"
    : > "$ipath/lib/state-writer.sh"
    : > "$ipath/lib/state-reader.sh"
    : > "$ipath/feed-airplanes"
    : > "$ipath/lastlog"

    # /etc/airplanes/ — canonical config + identity. feed.env and the claim
    # secret are intentionally preserved across uninstall (user-config and
    # re-claim continuity); feeder-id is explicitly preserved by uninstall.sh.
    # Staged before the systemd block so the image-install marker has a
    # parent directory when systemd_layout=image.
    mkdir -p "$ROOT_DIR/etc/airplanes"
    printf 'canonical-uuid-content\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    printf 'LATITUDE=0\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    printf 'secret-token\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    # Systemd unit layout — manual (/lib/systemd/system) or image
    # (/etc/systemd/system, gated by IMAGE_SERVICE_LAYOUT in update.sh).
    # Image layout also stages the /etc/airplanes/image-install marker.
    if [[ "$systemd_layout" == "image" ]]; then
        mkdir -p "$ROOT_DIR/etc/systemd/system"
        : > "$ROOT_DIR/etc/systemd/system/airplanes-feed.service"
        : > "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service"
        : > "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.service"
        : > "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.timer"
        : > "$ROOT_DIR/etc/airplanes/image-install"
    else
        mkdir -p "$ROOT_DIR/lib/systemd/system"
        : > "$ROOT_DIR/lib/systemd/system/airplanes-feed.service"
        : > "$ROOT_DIR/lib/systemd/system/airplanes-mlat.service"
        : > "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.service"
        : > "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.timer"
    fi

    # Diagnostics state directory — systemd's StateDirectory=airplanes-diagnostics
    # creates /var/lib/airplanes-diagnostics owned by the diagnostics user on
    # first timer fire. uninstall.sh wipes the whole directory.
    mkdir -p "$ROOT_DIR/var/lib/airplanes-diagnostics"
    : > "$ROOT_DIR/var/lib/airplanes-diagnostics/diagnostics-last-success"

    # Config-sync state directory — its own StateDirectory=airplanes-config-sync
    # (separate from diagnostics so the two oneshots never re-chown a shared
    # dir). uninstall.sh wipes it too.
    mkdir -p "$ROOT_DIR/var/lib/airplanes-config-sync"
    : > "$ROOT_DIR/var/lib/airplanes-config-sync/config-sync-last-success"

    # CLI wrapper at /usr/local/bin — installed by update.sh:545.
    mkdir -p "$ROOT_DIR/usr/local/bin"
    : > "$ROOT_DIR/usr/local/bin/apl-feed"

    # Legacy symlink at /etc/default/airplanes → /etc/airplanes/feed.env,
    # materialized by finalize_legacy_feed_env_migration on manual installs.
    mkdir -p "$ROOT_DIR/etc/default"
    ln -sfn '/etc/airplanes/feed.env' "$ROOT_DIR/etc/default/airplanes"
}

run_uninstall() {
    run env -i \
        PATH="$STUB_DIR:/usr/bin:/bin" \
        AIRPLANES_ROOT="$ROOT_DIR" \
        SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        TAR1090_LOG="$TAR1090_LOG" \
        USERDEL_LOG="$USERDEL_LOG" \
        GROUPDEL_LOG="$GROUPDEL_LOG" \
        bash "$UNINSTALL"
}

@test "after install footprint, uninstall removes manual-install systemd units" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-feed.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-mlat.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.timer" ]
}

@test "after install footprint, uninstall removes /var/lib/airplanes-diagnostics state dir" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/var/lib/airplanes-diagnostics" ]
}

@test "after install footprint, uninstall removes /var/lib/airplanes-config-sync state dir" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/var/lib/airplanes-config-sync" ]
}

@test "after install footprint, uninstall wipes IPATH and leaves only the legacy UUID symlink" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ -d "$ROOT_DIR/usr/local/share/airplanes" ]
    # IPATH is recreated empty (uninstall.sh:59-60) then the legacy
    # airplanes-uuid symlink is re-materialized when canonical feeder-id
    # exists (uninstall.sh:70-72). Nothing else should remain.
    local remaining
    remaining="$(ls -A "$ROOT_DIR/usr/local/share/airplanes")"
    [ "$remaining" = "airplanes-uuid" ]
    [ -L "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid" ]
}

@test "after install footprint, uninstall preserves /etc/airplanes/feeder-id" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ -f "$ROOT_DIR/etc/airplanes/feeder-id" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "canonical-uuid-content" ]
}

@test "after install footprint, uninstall preserves /etc/airplanes/feed.env (user config)" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ -f "$ROOT_DIR/etc/airplanes/feed.env" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feed.env")" = "LATITUDE=0" ]
}

@test "after install footprint, uninstall preserves /etc/airplanes/feeder-claim-secret (re-claim continuity)" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "secret-token" ]
}

@test "after install footprint, uninstall preserves the /etc/default/airplanes legacy symlink" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ -L "$ROOT_DIR/etc/default/airplanes" ]
}

@test "uninstall does not invoke userdel for the airplanes-feed account (intentional preserve)" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -f "$USERDEL_LOG" ]
}

@test "uninstall does not invoke groupdel for the airplanes-feed group (intentional preserve)" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -f "$GROUPDEL_LOG" ]
}

@test "after install footprint, second uninstall is byte-identical to the first (idempotent)" {
    stage_install_footprint
    run_uninstall
    [ "$status" -eq 0 ]

    local before_listing
    before_listing="$(find "$ROOT_DIR" -mindepth 1 -not -path "$STUB_DIR*" -not -name 'systemctl.log' -not -name 'tar1090.log' -not -name 'userdel.log' -not -name 'groupdel.log' | sort)"

    : > "$SYSTEMCTL_LOG"
    run_uninstall
    [ "$status" -eq 0 ]

    local after_listing
    after_listing="$(find "$ROOT_DIR" -mindepth 1 -not -path "$STUB_DIR*" -not -name 'systemctl.log' -not -name 'tar1090.log' -not -name 'userdel.log' -not -name 'groupdel.log' | sort)"

    [ "$before_listing" = "$after_listing" ]
}

@test "after install footprint, uninstall removes /usr/local/bin/apl-feed CLI wrapper" {
    stage_install_footprint
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/usr/local/bin/apl-feed" ]
}

@test "after build-mode footprint, uninstall removes /etc/airplanes/image-install marker" {
    stage_install_footprint
    : > "$ROOT_DIR/etc/airplanes/image-install"
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/etc/airplanes/image-install" ]
}

@test "after image-install footprint, uninstall removes image-layout systemd units" {
    stage_install_footprint image
    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-feed.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.timer" ]
    [ ! -e "$ROOT_DIR/etc/airplanes/image-install" ]
}

@test "image-layout systemd units are removed even without the image-install marker" {
    # Regression guard: cleanup must not be gated on /etc/airplanes/image-install.
    # update.sh routes units to /etc/systemd/system whenever IMAGE_SERVICE_LAYOUT
    # is set, which includes AIRPLANES_BUILD_MODE=1 builds that may not write
    # the marker — uninstall has to clean those too.
    mkdir -p "$ROOT_DIR/etc/systemd/system"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-feed.service"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.service"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.timer"

    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-feed.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.timer" ]
}

@test "after mixed-layout footprint, uninstall removes units and wants symlinks from both layouts" {
    # Defends a feeder caught mid-migration (units staged in both layouts) and
    # exercises the explicit wants-target cleanup that handles
    # chroot/build-mode/stubbed-systemctl environments where `systemctl disable`
    # can't run.
    stage_install_footprint manual
    mkdir -p "$ROOT_DIR/etc/systemd/system"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-feed.service"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-mlat2.service"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.service"
    : > "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.timer"
    : > "$ROOT_DIR/etc/airplanes/image-install"

    mkdir -p "$ROOT_DIR/etc/systemd/system/default.target.wants"
    mkdir -p "$ROOT_DIR/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$ROOT_DIR/etc/systemd/system/timers.target.wants"
    ln -sfn '/etc/systemd/system/airplanes-feed.service' \
        "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-feed.service"
    ln -sfn '/etc/systemd/system/airplanes-mlat.service' \
        "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-mlat.service"
    ln -sfn '/etc/systemd/system/airplanes-mlat2.service' \
        "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-mlat2.service"
    ln -sfn '/etc/systemd/system/airplanes-mlat2.service' \
        "$ROOT_DIR/etc/systemd/system/multi-user.target.wants/airplanes-mlat2.service"
    ln -sfn '/etc/systemd/system/airplanes-diagnostics.timer' \
        "$ROOT_DIR/etc/systemd/system/timers.target.wants/airplanes-diagnostics.timer"

    run_uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-feed.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-mlat.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.service" ]
    [ ! -e "$ROOT_DIR/lib/systemd/system/airplanes-diagnostics.timer" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-feed.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-mlat2.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.service" ]
    [ ! -e "$ROOT_DIR/etc/systemd/system/airplanes-diagnostics.timer" ]
    [ ! -L "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-feed.service" ]
    [ ! -L "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-mlat.service" ]
    [ ! -L "$ROOT_DIR/etc/systemd/system/default.target.wants/airplanes-mlat2.service" ]
    [ ! -L "$ROOT_DIR/etc/systemd/system/multi-user.target.wants/airplanes-mlat2.service" ]
    [ ! -L "$ROOT_DIR/etc/systemd/system/timers.target.wants/airplanes-diagnostics.timer" ]
    [ ! -e "$ROOT_DIR/etc/airplanes/image-install" ]
}
