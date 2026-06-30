#!/usr/bin/env bats

# remove_pre_fhs_layout — sweep the pre-FHS install layout
# (/usr/local/share/airplanes payload + /lib/systemd/system units) on upgrade
# to the /opt layout, while preserving feeder identity/config under
# /etc/airplanes. /etc/airplanes is the firewall: it is never touched, so the
# feeder keeps its identity (feeder-id) and config (feed.env) across the move.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    TMP="$(mktemp -d)"

    AIRPLANES_ROOT="$TMP/root"
    mkdir -p "$AIRPLANES_ROOT"
    AIRPLANES_BUILD_MODE=
    export AIRPLANES_ROOT AIRPLANES_BUILD_MODE

    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/install-update-common.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/update-migrations.sh"

    LEGACY_IPATH="$AIRPLANES_ROOT/usr/local/share/airplanes"
    LEGACY_SYSTEMD="$AIRPLANES_ROOT/lib/systemd/system"
    ETC_AIRPLANES="$AIRPLANES_ROOT/etc/airplanes"
}

teardown() {
    rm -rf "$TMP"
}

seed_pre_fhs_install() {
    mkdir -p "$LEGACY_IPATH/git" "$LEGACY_IPATH/lib" "$LEGACY_SYSTEMD" "$ETC_AIRPLANES"
    : > "$LEGACY_IPATH/airplanes-feed.sh"
    : > "$LEGACY_IPATH/feed-airplanes"
    : > "$LEGACY_IPATH/airplanes-uuid"
    local u
    for u in airplanes-feed.service airplanes-mlat.service \
             airplanes-diagnostics.service airplanes-diagnostics.timer \
             airplanes-stats.service airplanes-stats.timer \
             airplanes-config-sync.service airplanes-config-sync.timer; do
        : > "$LEGACY_SYSTEMD/$u"
    done
    # Feeder identity + config that MUST survive the sweep.
    printf '%s\n' '11111111-2222-3333-4444-555555555555' > "$ETC_AIRPLANES/feeder-id"
    printf '%s\n' 'INPUT="127.0.0.1:30005"' > "$ETC_AIRPLANES/feed.env"
}

@test "remove_pre_fhs_layout: removes old payload tree and /lib units" {
    seed_pre_fhs_install
    remove_pre_fhs_layout "$LEGACY_IPATH" "$LEGACY_SYSTEMD" /dev/null
    [ ! -e "$LEGACY_IPATH" ]
    [ ! -e "$LEGACY_SYSTEMD/airplanes-feed.service" ]
    [ ! -e "$LEGACY_SYSTEMD/airplanes-config-sync.timer" ]
}

@test "remove_pre_fhs_layout: preserves /etc/airplanes identity and config" {
    seed_pre_fhs_install
    remove_pre_fhs_layout "$LEGACY_IPATH" "$LEGACY_SYSTEMD" /dev/null
    [ -f "$ETC_AIRPLANES/feeder-id" ]
    [ -f "$ETC_AIRPLANES/feed.env" ]
    grep -q '11111111-2222-3333-4444-555555555555' "$ETC_AIRPLANES/feeder-id"
}

@test "remove_pre_fhs_layout: no-op when no pre-FHS install present" {
    mkdir -p "$LEGACY_SYSTEMD" "$ETC_AIRPLANES"
    run remove_pre_fhs_layout "$LEGACY_IPATH" "$LEGACY_SYSTEMD" /dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$LEGACY_IPATH" ]
}

@test "remove_pre_fhs_layout: defensive guard refuses a non-legacy rm -rf target" {
    local bogus="$AIRPLANES_ROOT/var/lib/airplanes/runtime"
    mkdir -p "$bogus" "$LEGACY_SYSTEMD"
    : > "$LEGACY_SYSTEMD/airplanes-feed.service"   # trip the detection gate
    remove_pre_fhs_layout "$bogus" "$LEGACY_SYSTEMD" /dev/null
    # The wrong path must NOT be deleted (the guard only rm -rf's the legacy suffix)...
    [ -d "$bogus" ]
    # ...but the stale units are still swept.
    [ ! -e "$LEGACY_SYSTEMD/airplanes-feed.service" ]
}
