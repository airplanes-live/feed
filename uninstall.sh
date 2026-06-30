#!/bin/bash
set -x

AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"

airplanes_path() {
    local path="$1"
    if [[ "$AIRPLANES_ROOT" == "/" ]]; then
        printf '%s' "$path"
    else
        printf '%s%s' "${AIRPLANES_ROOT%/}" "$path"
    fi
}

PREFIX="$(airplanes_path /opt/airplanes/current)"
IPATH="$PREFIX/share/airplanes"
STATE="$(airplanes_path /var/lib/airplanes/runtime)"
# Payload directory the previous (pre-FHS) layout installed to; removed so an
# upgrade-then-uninstall doesn't leak the stale tree.
LEGACY_IPATH="$(airplanes_path /usr/local/share/airplanes)"
FEEDER_ID="$(airplanes_path /etc/airplanes/feeder-id)"
LEGACY_UUID="$STATE/airplanes-uuid"
# Unit-file directories: units now install to /etc/systemd/system, but
# pre-FHS manual installs wrote to /lib/systemd/system. Iterate both
# unconditionally; unit names are airplanes-specific and rm -f is a no-op
# when absent.
SYSTEMD_UNIT_DIRS=(
    "$(airplanes_path /lib/systemd/system)"
    "$(airplanes_path /etc/systemd/system)"
)
SYSTEMD_ETC="$(airplanes_path /etc/systemd/system)"
TAR1090_DIR="$(airplanes_path /usr/local/share/tar1090)"
LOCAL_BIN_APL_FEED="$(airplanes_path /usr/local/bin/apl-feed)"
IMAGE_INSTALL_MARKER="$(airplanes_path /etc/airplanes/image-install)"

systemctl disable --now airplanes-mlat
systemctl disable --now airplanes-mlat2 &>/dev/null
systemctl disable --now airplanes-feed
systemctl disable --now airplanes-diagnostics.timer &>/dev/null
systemctl disable --now airplanes-diagnostics.service &>/dev/null
systemctl disable --now airplanes-stats.timer &>/dev/null
systemctl disable --now airplanes-stats.service &>/dev/null
systemctl disable --now airplanes-config-sync.timer &>/dev/null
systemctl disable --now airplanes-config-sync.service &>/dev/null

# Legacy cleanup: earlier releases shipped install-or-update-interface.sh, which
# installed wiedehopf/tar1090 with the "airplanes" URL prefix. The installer is
# gone, but existing systems may still have it set up — keep removing it here.
if [[ -d "$TAR1090_DIR/html-airplanes" ]]; then
    bash "$TAR1090_DIR/uninstall.sh" airplanes
fi

for _systemd_dir in "${SYSTEMD_UNIT_DIRS[@]}"; do
    rm -f "$_systemd_dir/airplanes-mlat.service"
    rm -f "$_systemd_dir/airplanes-mlat2.service"
    rm -f "$_systemd_dir/airplanes-feed.service"
    rm -f "$_systemd_dir/airplanes-diagnostics.service"
    rm -f "$_systemd_dir/airplanes-diagnostics.timer"
    rm -f "$_systemd_dir/airplanes-stats.service"
    rm -f "$_systemd_dir/airplanes-stats.timer"
    rm -f "$_systemd_dir/airplanes-config-sync.service"
    rm -f "$_systemd_dir/airplanes-config-sync.timer"
done
unset _systemd_dir

# Wants-target symlinks. `systemctl disable --now` above removes these in
# production; this explicit cleanup handles chroot/build-mode/stubbed-systemctl
# cases where disable can't run and would otherwise leave dangling symlinks
# pointing at now-removed unit files. Mirrors update-migrations.sh's mlat2
# retirement cleanup.
rm -f "$SYSTEMD_ETC/default.target.wants/airplanes-feed.service"
rm -f "$SYSTEMD_ETC/default.target.wants/airplanes-mlat.service"
rm -f "$SYSTEMD_ETC/default.target.wants/airplanes-mlat2.service"
rm -f "$SYSTEMD_ETC/multi-user.target.wants/airplanes-mlat2.service"
rm -f "$SYSTEMD_ETC/timers.target.wants/airplanes-diagnostics.timer"
rm -f "$SYSTEMD_ETC/timers.target.wants/airplanes-stats.timer"
rm -f "$SYSTEMD_ETC/timers.target.wants/airplanes-config-sync.timer"

systemctl daemon-reload || true

# Named-path artifacts written by update.sh outside $IPATH. The IPATH wipe
# below handles everything inside it.
rm -f "$LOCAL_BIN_APL_FEED"
rm -f "$IMAGE_INSTALL_MARKER"
# State directories for the diagnostics and config-sync oneshots (last-success
# timestamp files). Created by systemd's StateDirectory= on first fire of each
# unit; nothing in them is user-supplied, so remove wholesale. Both the new
# nested layout and the pre-FHS flat dirs are removed.
rm -rf "$(airplanes_path /var/lib/airplanes/diagnostics)"
rm -rf "$(airplanes_path /var/lib/airplanes/config-sync)"
rm -rf "$(airplanes_path /var/lib/airplanes-diagnostics)"
rm -rf "$(airplanes_path /var/lib/airplanes-config-sync)"

# Preserve the legacy fallback in memory before wiping IPATH so the canonical
# feeder-id can be materialized from it if no canonical copy exists. The
# canonical feeder-id lives at /etc/airplanes/feeder-id (outside IPATH) and
# survives the wipe untouched, so it does not need shuttling.
#
# Bytes are not preserved verbatim: command substitution strips trailing
# newlines and the materialize step re-adds exactly one. This is intentional
# and acceptable because feeder-id is always a UUID followed by a single
# newline (see create-uuid.sh).
#
# xtrace is disabled around the read and write so the UUID does not appear in
# stderr trace output (the original cp-based shuttle did not print contents).
LEGACY_FALLBACK_VALID=0
LEGACY_UUID_CONTENT=""
if [[ ! -f "$FEEDER_ID" && -f "$LEGACY_UUID" ]]; then
    { set +x; } 2>/dev/null
    if LEGACY_UUID_CONTENT="$(cat "$LEGACY_UUID")"; then
        LEGACY_FALLBACK_VALID=1
    fi
    set -x
fi

rm -rf "$IPATH"
mkdir -p "$IPATH"
# Mutable runtime state (git checkout, build trees, version stamps, legacy
# uuid symlink) and the pre-FHS payload dir.
rm -rf "$STATE"
mkdir -p "$STATE"
rm -rf "$LEGACY_IPATH"

if [[ ! -f "$FEEDER_ID" && "$LEGACY_FALLBACK_VALID" -eq 1 ]]; then
    mkdir -p "$(dirname "$FEEDER_ID")"
    { set +x; } 2>/dev/null
    printf '%s\n' "$LEGACY_UUID_CONTENT" > "$FEEDER_ID"
    set -x
    chmod 644 "$FEEDER_ID"
fi

if [[ -f "$FEEDER_ID" ]]; then
    ln -sfn '../../../../etc/airplanes/feeder-id' "$LEGACY_UUID"
fi

set +x

echo -----
echo "airplanes.live feed scripts have been uninstalled!"
