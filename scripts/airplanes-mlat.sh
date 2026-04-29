#!/bin/bash

AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"
airplanes_path() {
    local path="$1"
    if [[ "$AIRPLANES_ROOT" == "/" ]]; then
        printf '%s' "$path"
    else
        printf '%s%s' "${AIRPLANES_ROOT%/}" "$path"
    fi
}

BOOT_CONFIG="$(airplanes_path /boot/airplanes-config.txt)"
BOOT_ENV="$(airplanes_path /boot/airplanes-env)"
FEED_ENV="$(airplanes_path /etc/airplanes/feed.env)"

if [[ -f "$BOOT_CONFIG" && -x "$(airplanes_path /usr/bin/airplanes-feeder)" ]]; then
    source "$BOOT_CONFIG"
    [[ -f "$BOOT_ENV" ]] && source "$BOOT_ENV"
else
    source "$FEED_ENV"
fi

if [[ "${MLAT_MARKER:-}" == "no" ]]; then
    PRIVACY="--privacy"
elif [[ -n "${MLAT_MARKER:-}" ]]; then
    PRIVACY=""
else
    PRIVACY="${PRIVACY:-}"
fi

if [[ "$LATITUDE" == 0 ]] || [[ "$LONGITUDE" == 0 ]] || [[ "$USER" == 0 ]] || [[ "$USER" == "disable" ]]; then
    echo MLAT DISABLED
    sleep 3600
    exit
fi

INPUT_IP=$(echo $INPUT | cut -d: -f1)
INPUT_PORT=$(echo $INPUT | cut -d: -f2)

sleep 2

while ! nc -z "$INPUT_IP" "$INPUT_PORT" && command -v nc &>/dev/null; do
    echo "Could not connect to $INPUT_IP:$INPUT_PORT, retry in 10 seconds."
    sleep 10
done

exec "$(airplanes_path /usr/local/share/airplanes/venv/bin/mlat-client)" \
    --input-type "$INPUT_TYPE" --no-udp \
    --input-connect "$INPUT" \
    --server "$MLATSERVER" \
    --user "$USER" \
    --lat "$LATITUDE" \
    --lon "$LONGITUDE" \
    --alt "$ALTITUDE" \
    $PRIVACY \
    ${UUID_FILE:-} \
    $RESULTS $RESULTS1 $RESULTS2 $RESULTS3 $RESULTS4
