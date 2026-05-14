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

IPATH="$(airplanes_path /usr/local/share/airplanes)"
FEEDER_ID="$(airplanes_path /etc/airplanes/feeder-id)"
LEGACY_UUID="$IPATH/airplanes-uuid"
SYSTEMD_DIR="$(airplanes_path /lib/systemd/system)"
TAR1090_DIR="$(airplanes_path /usr/local/share/tar1090)"
LOCAL_BIN_APL_FEED="$(airplanes_path /usr/local/bin/apl-feed)"
IMAGE_INSTALL_MARKER="$(airplanes_path /etc/airplanes/image-install)"

systemctl disable --now airplanes-mlat
systemctl disable --now airplanes-mlat2 &>/dev/null
systemctl disable --now airplanes-feed
systemctl disable --now airplanes-diagnostics.timer &>/dev/null
systemctl disable --now airplanes-diagnostics.service &>/dev/null

# Legacy cleanup: earlier releases shipped install-or-update-interface.sh, which
# installed wiedehopf/tar1090 with the "airplanes" URL prefix. The installer is
# gone, but existing systems may still have it set up — keep removing it here.
if [[ -d "$TAR1090_DIR/html-airplanes" ]]; then
    bash "$TAR1090_DIR/uninstall.sh" airplanes
fi

rm -f "$SYSTEMD_DIR/airplanes-mlat.service"
rm -f "$SYSTEMD_DIR/airplanes-mlat2.service"
rm -f "$SYSTEMD_DIR/airplanes-feed.service"
rm -f "$SYSTEMD_DIR/airplanes-diagnostics.service"
rm -f "$SYSTEMD_DIR/airplanes-diagnostics.timer"
systemctl daemon-reload || true

# Named-path artifacts written by update.sh outside $IPATH. The IPATH wipe
# below handles everything inside it.
rm -f "$LOCAL_BIN_APL_FEED"
rm -f "$IMAGE_INSTALL_MARKER"
# State directory for the diagnostics oneshot (last-success timestamp file).
# Created by systemd's StateDirectory=airplanes on first fire of the unit;
# nothing in it is user-supplied, so remove wholesale.
rm -rf "$(airplanes_path /var/lib/airplanes)"

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
