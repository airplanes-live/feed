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

# Unset USER (and the new keys) before sourcing so the process env's $USER
# (systemd User= sets it to airplanes-feed) can't be mistaken for a legacy
# boot-config key.
unset USER MLAT_USER MLAT_ENABLED
if [[ -f "$FEED_ENV" ]]; then
    source "$FEED_ENV"
elif [[ -x "$(airplanes_path /usr/bin/airplanes-feeder)" && -f "$BOOT_CONFIG" ]]; then
    source "$BOOT_CONFIG"
    [[ -f "$BOOT_ENV" ]] && source "$BOOT_ENV"
else
    source "$FEED_ENV"
fi

# Schema guard: this wrapper requires the new MLAT_USER + MLAT_ENABLED
# schema. The legacy USER= → MLAT_USER translation is owned by airplanes-
# webconfig's migrate-config.sh (also vendored into airplanes-update's
# skeleton). Reaching this state means a config source has USER= but the
# migrator never ran against it.
if [[ -v USER && ! -v MLAT_USER && ! -v MLAT_ENABLED ]]; then
    echo "ERROR: legacy USER= schema detected without MLAT_USER. " >&2
    echo "Run 'Update Webconfig' to migrate the boot config, then restart this service." >&2
    exit 64
fi
MLAT_ENABLED="${MLAT_ENABLED:-true}"
MLAT_USER="${MLAT_USER-}"

if [[ "${MLAT_MARKER:-}" == "no" ]]; then
    PRIVACY="--privacy"
elif [[ -n "${MLAT_MARKER:-}" ]]; then
    PRIVACY=""
else
    PRIVACY="${PRIVACY:-}"
fi

UUID_FILE="--uuid-file $FEEDER_ID_FILE"

# State writer (defensive: a partial install where this script is in
# place but the lib isn't yet must not take down the daemon).
STATE_WRITER="$(airplanes_path /usr/local/share/airplanes/lib/state-writer.sh)"
if [[ -r "$STATE_WRITER" ]]; then
    # shellcheck source=lib/state-writer.sh
    source "$STATE_WRITER"
else
    airplanes_write_state() { return 0; }
fi

# Classify the daemon's config decision. Order matters: explicit
# MLAT_ENABLED disable is checked before geo so a user who turns MLAT
# off on a fresh feeder (lat/lon still 0) sees reason=mlat_enabled_false
# rather than reason=latitude_zero. The misconfigured branch only
# triggers when the user opted INTO MLAT but left MLAT_USER empty —
# that's the strict-fail-with-exit-64 shape.
_mlat_classify() {
    if [[ "$MLAT_ENABLED" != "true" ]]; then printf 'disabled mlat_enabled_false\n'; return; fi
    if [[ "$LATITUDE" == 0 ]]; then printf 'disabled latitude_zero\n'; return; fi
    if [[ "$LONGITUDE" == 0 ]]; then printf 'disabled longitude_zero\n'; return; fi
    if [[ -z "$MLAT_USER" ]]; then printf 'misconfigured mlat_user_empty\n'; return; fi
    printf 'enabled ok\n'
}

read -r STATE REASON < <(_mlat_classify)
STATE_FILE="$(airplanes_path /run/airplanes-mlat/state)"
mkdir -p "$(dirname "$STATE_FILE")"
airplanes_write_state "$STATE_FILE" \
    "service=airplanes-mlat" \
    "state=$STATE" \
    "reason=$REASON" \
    "decided_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "mlat_enabled=${MLAT_ENABLED:-}" \
    "mlat_user=${MLAT_USER:-}" \
    "latitude=${LATITUDE:-}" \
    "longitude=${LONGITUDE:-}" || true

case "$STATE" in
    disabled)
        echo MLAT DISABLED
        sleep 3600
        exit
        ;;
    misconfigured)
        # Matches RestartPreventExitStatus=64 in the unit file so
        # systemd marks the unit failed instead of restart-looping.
        echo "MLAT_ENABLED=true but MLAT_USER is empty; refusing to start mlat-client." >&2
        exit 64
        ;;
    enabled)
        ;;
esac

INPUT_IP=$(echo $INPUT | cut -d: -f1)
INPUT_PORT=$(echo $INPUT | cut -d: -f2)

sleep 2

while command -v nc &>/dev/null && ! nc -z "$INPUT_IP" "$INPUT_PORT"; do
    echo "Could not connect to $INPUT_IP:$INPUT_PORT, retry in 10 seconds."
    sleep 10
done

exec "$(airplanes_path /usr/local/share/airplanes/venv/bin/mlat-client)" \
    --input-type "$INPUT_TYPE" --no-udp \
    --input-connect "$INPUT" \
    --server "$MLATSERVER" \
    --user "$MLAT_USER" \
    --lat "$LATITUDE" \
    --lon "$LONGITUDE" \
    --alt "$ALTITUDE" \
    $PRIVACY \
    ${UUID_FILE:-} \
    $RESULTS $RESULTS1 $RESULTS2 $RESULTS3 $RESULTS4
