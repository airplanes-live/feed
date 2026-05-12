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

# Stage a maximally-realistic post-install state at AIRPLANES_ROOT.
#
# Path enumeration sourced from update.sh's install steps:
#   - $IPATH contents: update.sh:474-497, 545, 569-589, 644-651, 716
#   - systemd units in /lib/systemd/system: update.sh:594-596 (manual install)
#   - /usr/local/bin/apl-feed: update.sh:545
#   - /etc/airplanes/ artifacts: update.sh:428,472,569,704; create-uuid.sh;
#     claim-registration.sh:register_claim_secret
#   - /etc/default/airplanes symlink: update-migrations.sh:finalize_legacy_feed_env_migration
#
# Inside $IPATH only a representative sample is staged; `rm -rf $IPATH` wipes
# the entire directory wholesale, so per-file enumeration there has no
# additional signal.
stage_install_footprint() {
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

    # Manual-install systemd unit layout — /lib/systemd/system. The image-
    # install layout (/etc/systemd/system) is intentionally out of scope here;
    # uninstall.sh is the manual-install uninstaller. See known-leaks tests
    # below for the image-install gap.
    mkdir -p "$ROOT_DIR/lib/systemd/system"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-feed.service"
    : > "$ROOT_DIR/lib/systemd/system/airplanes-mlat.service"

    # CLI wrapper at /usr/local/bin — installed by update.sh:545.
    mkdir -p "$ROOT_DIR/usr/local/bin"
    : > "$ROOT_DIR/usr/local/bin/apl-feed"

    # /etc/airplanes/ — canonical config + identity. feed.env and the claim
    # secret are intentionally preserved across uninstall (user-config and
    # re-claim continuity); feeder-id is explicitly preserved by uninstall.sh.
    mkdir -p "$ROOT_DIR/etc/airplanes"
    printf 'canonical-uuid-content\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    printf 'LATITUDE=0\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    printf 'secret-token\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

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
