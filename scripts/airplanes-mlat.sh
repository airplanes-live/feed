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
# (systemd User= sets it to airplanes-feed) can't bleed into the legacy-USER
# fallback below.
unset USER MLAT_USER MLAT_ENABLED
if [[ -f "$FEED_ENV" ]]; then
    source "$FEED_ENV"
elif [[ -x "$(airplanes_path /usr/bin/airplanes-feeder)" && -f "$BOOT_CONFIG" ]]; then
    source "$BOOT_CONFIG"
    [[ -f "$BOOT_ENV" ]] && source "$BOOT_ENV"
else
    source "$FEED_ENV"
fi

# Legacy USER read fallback. update.sh's migrate_user_to_mlat_split splits
# USER into MLAT_USER + MLAT_ENABLED on every run, but a daemon restart
# triggered by the legacy PHP webconfig (which still writes USER=) can race
# ahead of the next update. When that happens, derive MLAT_USER/MLAT_ENABLED
# in-memory so the daemon doesn't strict-fail on missing config. Removed
# when airplanes-update is archived.
#
# Test "set vs unset" rather than "non-empty" — an explicit MLAT_USER=""
# written by a future-aware writer is respected as "user opted in but left
# the name blank" and triggers the strict-fail below. The `${VAR+x}` form
# is portable to bash 3.2 (macOS); `[[ -v VAR ]]` would be cleaner but
# is bash 4+.
if [[ -z "${MLAT_USER+x}" && -z "${MLAT_ENABLED+x}" && -n "${USER+x}" ]]; then
    case "$USER" in
        0|disable)
            MLAT_USER=""
            MLAT_ENABLED="false"
            ;;
        *)
            MLAT_USER="$USER"
            MLAT_ENABLED="true"
            ;;
    esac
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

if [[ "$LATITUDE" == 0 ]] || [[ "$LONGITUDE" == 0 ]] || [[ "$MLAT_ENABLED" != "true" ]]; then
    echo MLAT DISABLED
    sleep 3600
    exit
fi

# Strict misconfigure exit. Matches RestartPreventExitStatus=64 in the unit
# file so systemd marks the unit failed instead of restart-looping.
if [[ -z "$MLAT_USER" ]]; then
    echo "MLAT_ENABLED=true but MLAT_USER is empty; refusing to start mlat-client." >&2
    exit 64
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
    --user "$MLAT_USER" \
    --lat "$LATITUDE" \
    --lon "$LONGITUDE" \
    --alt "$ALTITUDE" \
    $PRIVACY \
    ${UUID_FILE:-} \
    $RESULTS $RESULTS1 $RESULTS2 $RESULTS3 $RESULTS4
