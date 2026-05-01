#!/bin/bash
SERVICE="/lib/systemd/system/airplanes-mlat2.service"

if [[ -z ${1} ]]; then
    echo --------------
    echo ERROR: requires a parameter
    exit 1
fi

cat >"$SERVICE" <<"EOF"
[Unit]
Description=airplanes-mlat2
Wants=network.target
After=network.target

[Service]
User=airplanes
EnvironmentFile=/etc/airplanes/feed.env
ExecStart=/usr/local/share/airplanes/venv/bin/mlat-client \
    --input-type $INPUT_TYPE --no-udp \
    --input-connect $INPUT \
    --server feed.airplanes.live:SERVERPORT \
    --user $USER \
    --lat $LATITUDE \
    --lon $LONGITUDE \
    --alt $ALTITUDE \
    --uuid-file /etc/airplanes/feeder-id \
    $PRIVACY \
    $RESULTS
Type=simple
Restart=always
RestartSec=30
StartLimitInterval=1
StartLimitBurst=100
SyslogIdentifier=airplanes-mlat2
Nice=-1

[Install]
WantedBy=default.target
EOF

sed -i -e "s/SERVERPORT/${1}/" "$SERVICE"
if [[ -n ${2} ]]; then
    sed -i -e "s/\$RESULTS/${2}/" "$SERVICE"
fi

systemctl enable airplanes-mlat2
systemctl restart airplanes-mlat2
