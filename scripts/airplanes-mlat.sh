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

# Unset USER (and the privacy keys) before sourcing so the process env
# can't bleed into the legacy-USER, legacy-PRIVACY, or legacy-MLAT_MARKER
# fallbacks below. systemd's User= sets $USER for airplanes-mlat.service;
# an env-supplied MLAT_PRIVATE / PRIVACY / MLAT_MARKER (e.g. from a
# Drop-In) would otherwise mask the on-disk value.
unset USER MLAT_USER MLAT_ENABLED MLAT_PRIVATE PRIVACY MLAT_MARKER
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

# Legacy PRIVACY read fallback. update.sh's migrate_privacy_to_mlat_private
# converts PRIVACY=--privacy to MLAT_PRIVATE=true on every run; this in-
# memory derivation handles a daemon restart that races ahead of the next
# update.sh. Validation of MLAT_PRIVATE happens in the classifier below
# so an invalid hand-edit fails loud.
if [[ ! -v MLAT_PRIVATE && -v PRIVACY ]]; then
    case "$PRIVACY" in
        --privacy) MLAT_PRIVATE="true" ;;
        *)         MLAT_PRIVATE="false" ;;
    esac
fi

# Legacy MLAT_MARKER read fallback. PHP webconfig still writes MLAT_MARKER
# in /boot/airplanes-config.txt via its yes/no dropdown — inverted polarity
# where "no" means privacy ON. Without this fallback a legacy-image feeder
# would silently lose privacy on first daemon start under the new schema,
# even though their stored preference says "private". The webconfig-side
# migrator translation closes the window on the next save/update.
if [[ ! -v MLAT_PRIVATE && -v MLAT_MARKER ]]; then
    case "$MLAT_MARKER" in
        no) MLAT_PRIVATE="true" ;;
        *)  MLAT_PRIVATE="false" ;;
    esac
fi
MLAT_PRIVATE="${MLAT_PRIVATE:-false}"

# Product-side defaults. feed.env holds operator data; brand endpoints
# and the local result-output bundle default here so a slim feed.env
# still produces a working daemon, and an airplanes.live-side endpoint
# change ships with the next feed update rather than requiring an
# in-field config rewrite.
MLATSERVER="${MLATSERVER:-feed.airplanes.live:31090}"
INPUT="${INPUT:-127.0.0.1:30005}"
INPUT_TYPE="${INPUT_TYPE:-dump1090}"

# RESULTS bundle: only apply the default outputs when none of the
# RESULTS* slots are set on disk. Legacy single-line feed.env may carry
# a combined `RESULTS="--results ... --results ..."` and we must not
# duplicate outputs by stacking individual defaults on top.
if [[ ! -v RESULTS && ! -v RESULTS1 && ! -v RESULTS2 && ! -v RESULTS3 && ! -v RESULTS4 ]]; then
    RESULTS="--results beast,connect,127.0.0.1:30104"
    RESULTS2="--results basestation,listen,31015"
    RESULTS3="--results beast,listen,30157"
    RESULTS4="--results beast,connect,127.0.0.1:30187"
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

# Classify the daemon's config decision. Order matters: invalid
# MLAT_PRIVATE is checked first (fail-loud rather than silently
# defaulting), then explicit MLAT_ENABLED disable (so a user who turns
# MLAT off on a fresh feeder with lat/lon still 0 sees reason=
# mlat_enabled_false rather than reason=latitude_zero), then geo
# sentinels, then the empty-MLAT_USER check. The misconfigured branch
# is the strict-fail-with-exit-64 shape.
_mlat_classify() {
    case "$MLAT_PRIVATE" in
        true|false) ;;
        *) printf 'misconfigured mlat_private_invalid\n'; return ;;
    esac
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
    "mlat_private=${MLAT_PRIVATE:-}" \
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
        case "$REASON" in
            mlat_private_invalid)
                echo "MLAT_PRIVATE must be 'true' or 'false' (got: '${MLAT_PRIVATE:-}'); refusing to start mlat-client." >&2
                ;;
            mlat_user_empty)
                echo "MLAT_ENABLED=true but MLAT_USER is empty; refusing to start mlat-client." >&2
                ;;
            *)
                echo "Misconfigured ($REASON); refusing to start mlat-client." >&2
                ;;
        esac
        exit 64
        ;;
    enabled)
        ;;
esac

# Build the mlat-client privacy flag from the canonical boolean. The
# literal --privacy flag string never appears on disk anywhere; storing
# CLI fragments in feed.env was the legacy PRIVACY pattern this refactor
# retired.
PRIVACY_ARG=""
if [[ "$MLAT_PRIVATE" == "true" ]]; then
    PRIVACY_ARG="--privacy"
fi

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
    $PRIVACY_ARG \
    ${UUID_FILE:-} \
    $RESULTS $RESULTS1 $RESULTS2 $RESULTS3 $RESULTS4
