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

# 978 is opt-in: empty/unset UAT_INPUT means "don't even wire up the
# uat_in net-connector." The previous always-on default ("127.0.0.1:30978")
# meant a 1090-only feeder still asked the feeder binary to keep an idle
# connector around (silent_fail kept it harmless on the wire), but it also
# hid the user's intent and tripped the image-side dump978-fa wrapper into
# a restart loop on hardware without a 978 SDR. Opt in via `apl-feed 978
# enable` (CLI) or the 978 section in webconfig (image users).
UAT_SOURCE=""
if [[ -n ${UAT_INPUT-} ]]; then
    UAT_IP=$(echo $UAT_INPUT | cut -d: -f1)
    UAT_PORT=$(echo $UAT_INPUT | cut -d: -f2)
    UAT_SOURCE="--net-connector $UAT_IP,$UAT_PORT,uat_in,silent_fail"
fi

REDUCE_INTERVAL="${REDUCE_INTERVAL:-0.5}"
JSON_OPTIONS="${JSON_OPTIONS:-"--max-range 450 --json-location-accuracy 2 --range-outline-hours 24"}"
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

# Brand endpoint + readsb tuning defaults. Apply outside the image
# branch so fresh non-image installs (which no longer have these keys
# in feed.env after configure.sh slimming) still produce a working
# daemon. The image branch keeps its leaner FEED_NET_OPTIONS override
# and adds FEED_IMAGE_OPTIONS for the baked-decoder case.
TARGET="${TARGET:-"--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"}"
NET_OPTIONS="${NET_OPTIONS:-"--net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.2 --net-ro-port 0 --net-sbs-port 0 --net-bo-port 0 --net-ri-port 0"}"

if [[ "$IMAGE_INSTALL" == "1" ]]; then
    FEED_NET_OPTIONS="${FEED_NET_OPTIONS:-"--net-ro-interval 0.2"}"
    FEED_IMAGE_OPTIONS="${FEED_IMAGE_OPTIONS:-"--db-file=none --max-range 450"}"
else
    FEED_NET_OPTIONS="${FEED_NET_OPTIONS:-$NET_OPTIONS}"
    FEED_IMAGE_OPTIONS=""
fi

# State writer (defensive: a partial install where this script is in
# place but the lib isn't yet must not take down the daemon).
STATE_WRITER="$(airplanes_path /usr/local/share/airplanes/lib/state-writer.sh)"
if [[ -r "$STATE_WRITER" ]]; then
    # shellcheck source=lib/state-writer.sh
    source "$STATE_WRITER"
else
    airplanes_write_state() { return 0; }
fi

# Feed has no MLAT-style disable predicate; it's essentially always-on
# once the daemon reaches this point. State file is mostly diagnostic
# (effective config + binary path) for consumers. Forward-compatible
# with future signals (e.g. an explicit FEED_ENABLED=false toggle
# would add a reason token without bumping schema_version).
STATE_FILE="$(airplanes_path /run/airplanes-feed/state)"
mkdir -p "$(dirname "$STATE_FILE")"
airplanes_write_state "$STATE_FILE" \
    "service=airplanes-feed" \
    "state=enabled" \
    "reason=ok" \
    "decided_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "latitude=${LATITUDE:-}" \
    "longitude=${LONGITUDE:-}" \
    "input=${INPUT:-}" \
    "feed_bin=$FEED_BIN" || true

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
