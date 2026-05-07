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
FEEDER_ID_FILE="$(airplanes_path /etc/airplanes/feeder-id)"
IMAGE_FEED_BIN="$(airplanes_path /usr/bin/airplanes-feeder)"
IMAGE_INSTALL_MARKER="$(airplanes_path /etc/airplanes/image-install)"

IMAGE_INSTALL=0
if [[ -x "$IMAGE_FEED_BIN" || -f "$IMAGE_INSTALL_MARKER" ]]; then
    IMAGE_INSTALL=1
fi

if [[ -f "$FEED_ENV" ]]; then
    source "$FEED_ENV"
elif [[ "$IMAGE_INSTALL" == "1" && -f "$BOOT_CONFIG" ]]; then
    source "$BOOT_CONFIG"
    [[ -f "$BOOT_ENV" ]] && source "$BOOT_ENV"
else
    source "$FEED_ENV"
fi

if [[ -z $INPUT ]]; then
    INPUT="127.0.0.1:30005"
fi

INPUT_IP=$(echo $INPUT | cut -d: -f1)
INPUT_PORT=$(echo $INPUT | cut -d: -f2)
SOURCE="--net-connector $INPUT_IP,$INPUT_PORT,beast_in,silent_fail"

if [[ -z $UAT_INPUT ]]; then
    UAT_INPUT="127.0.0.1:30978"
fi

UAT_IP=$(echo $UAT_INPUT | cut -d: -f1)
UAT_PORT=$(echo $UAT_INPUT | cut -d: -f2)
UAT_SOURCE="--net-connector $UAT_IP,$UAT_PORT,uat_in,silent_fail"

REDUCE_INTERVAL="${REDUCE_INTERVAL:-0.5}"
JSON_OPTIONS="${JSON_OPTIONS:-"--json-location-accuracy 2"}"
MODEAC_OPTION=""
if [[ "${MODEAC:-}" == "yes" ]]; then
    MODEAC_OPTION="--modeac"
fi

if [[ -x "$IMAGE_FEED_BIN" ]]; then
    DEFAULT_FEED_BIN="$IMAGE_FEED_BIN"
else
    DEFAULT_FEED_BIN="$(airplanes_path /usr/local/share/airplanes/feed-airplanes)"
fi
FEED_BIN="${AIRPLANES_FEED_BIN:-$DEFAULT_FEED_BIN}"

if [[ "$IMAGE_INSTALL" == "1" ]]; then
    TARGET="${TARGET:-"--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"}"
    FEED_NET_OPTIONS="${FEED_NET_OPTIONS:-"--net-ro-interval 0.2"}"
    FEED_IMAGE_OPTIONS="${FEED_IMAGE_OPTIONS:-"--db-file=none --max-range 450"}"
else
    FEED_NET_OPTIONS="${FEED_NET_OPTIONS:-$NET_OPTIONS}"
    FEED_IMAGE_OPTIONS=""
fi

exec "$FEED_BIN" --net --net-only --quiet \
    "--uuid-file=$FEEDER_ID_FILE" \
    $FEED_IMAGE_OPTIONS \
    --net-beast-reduce-interval $REDUCE_INTERVAL \
    $TARGET $FEED_NET_OPTIONS \
    --lat "$LATITUDE" --lon "$LONGITUDE" \
    $JSON_OPTIONS \
    $UAT_SOURCE \
    $SOURCE \
    $MODEAC_OPTION
