#!/bin/bash
set -x

IPATH=/usr/local/share/airplanes
FEEDER_ID=/etc/airplanes/feeder-id
LEGACY_UUID="$IPATH/airplanes-uuid"

systemctl disable --now airplanes-mlat
systemctl disable --now airplanes-mlat2 &>/dev/null
systemctl disable --now airplanes-feed

# Legacy cleanup: earlier releases shipped install-or-update-interface.sh, which
# installed wiedehopf/tar1090 with the "airplanes" URL prefix. The installer is
# gone, but existing systems may still have it set up — keep removing it here.
if [[ -d /usr/local/share/tar1090/html-airplanes ]]; then
    bash /usr/local/share/tar1090/uninstall.sh airplanes
fi

rm -f /lib/systemd/system/airplanes-mlat.service
rm -f /lib/systemd/system/airplanes-mlat2.service
rm -f /lib/systemd/system/airplanes-feed.service

if [[ -f "$FEEDER_ID" ]]; then
    cp -f "$FEEDER_ID" /tmp/airplanes-feeder-id
elif [[ -f "$LEGACY_UUID" ]]; then
    cp -f "$LEGACY_UUID" /tmp/airplanes-feeder-id
fi
rm -rf "$IPATH"
mkdir -p "$IPATH"
if [[ -f /tmp/airplanes-feeder-id ]]; then
    mkdir -p "$(dirname "$FEEDER_ID")"
    mv -f /tmp/airplanes-feeder-id "$FEEDER_ID"
    ln -sfn '../../../../etc/airplanes/feeder-id' "$LEGACY_UUID"
fi

set +x

echo -----
echo "airplanes.live feed scripts have been uninstalled!"
