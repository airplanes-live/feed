#!/bin/bash
set -x

IPATH=/usr/local/share/airplanes

systemctl disable --now airplanes-mlat
systemctl disable --now airplanes-mlat2 &>/dev/null
systemctl disable --now airplanes-feed

if [[ -d /usr/local/share/tar1090/html-airplanes ]]; then
    bash /usr/local/share/tar1090/uninstall.sh airplanes
fi

rm -f /lib/systemd/system/airplanes-mlat.service
rm -f /lib/systemd/system/airplanes-mlat2.service
rm -f /lib/systemd/system/airplanes-feed.service

cp -f "$IPATH/airplanes-uuid" /tmp/airplanes-uuid
rm -rf "$IPATH"
mkdir -p "$IPATH"
mv -f /tmp/airplanes-uuid "$IPATH/airplanes-uuid"

set +x

echo -----
echo "airplanes.live feed scripts have been uninstalled!"
