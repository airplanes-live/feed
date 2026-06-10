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

# Unset USER (and the privacy / geo keys) before sourcing so the process
# env can't bleed into any of the legacy fallbacks below. systemd's User=
# sets $USER for airplanes-mlat.service; an env-supplied MLAT_PRIVATE /
# PRIVACY / MLAT_MARKER / GEO_CONFIGURED (e.g. from a Drop-In) would
# otherwise mask the on-disk value.
unset USER MLAT_USER MLAT_ENABLED MLAT_PRIVATE PRIVACY MLAT_MARKER GEO_CONFIGURED
# _mlat_config_sources records which files govern this activation so the
# disabled branch's watch below only restarts on changes the next
# activation would actually see. The legacy branch also watches feed.env
# (its creation flips the feeder to the canonical branch); the canonical
# branch does NOT watch the boot files — the legacy web UI keeps writing
# /boot/airplanes-config.txt on migrated feeders, and those writes are
# invisible to a feed.env-governed daemon.
if [[ -f "$FEED_ENV" ]]; then
    source "$FEED_ENV"
    _mlat_config_sources=("$FEED_ENV")
elif [[ -x "$(airplanes_path /usr/bin/airplanes-feeder)" && -f "$BOOT_CONFIG" ]]; then
    source "$BOOT_CONFIG"
    [[ -f "$BOOT_ENV" ]] && source "$BOOT_ENV"
    _mlat_config_sources=("$FEED_ENV" "$BOOT_CONFIG" "$BOOT_ENV")
else
    source "$FEED_ENV"
    _mlat_config_sources=("$FEED_ENV")
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

# MLAT display name is optional. When unset or empty, derive a per-device
# fallback from the canonical feeder-id so each feeder still gets a distinct
# map identity instead of every blank-name feeder aggregating under a shared
# anonymous pin. webconfig writes a user-supplied MLAT_USER directly when
# the operator provides one. Falls back to plain "Anonymous" when the
# feeder-id file is missing, a symlink, or doesn't contain a canonical UUID
# — guards against a symlink-swap that would otherwise let the first 8 bytes
# of an unrelated file leak into the public state file as MLAT_USER, and
# against malformed content (control bytes, BOM) reaching mlat-client.
if [[ -z "$MLAT_USER" ]]; then
    _mlat_user_short_id=""
    if [[ -f "$FEEDER_ID_FILE" && ! -L "$FEEDER_ID_FILE" && -r "$FEEDER_ID_FILE" ]]; then
        _mlat_user_candidate="$(tr -d '\r\n' < "$FEEDER_ID_FILE" 2>/dev/null || true)"
        if [[ "$_mlat_user_candidate" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]]; then
            _mlat_user_short_id="${_mlat_user_candidate:0:8}"
        fi
        unset _mlat_user_candidate
    fi
    if [[ -n "$_mlat_user_short_id" ]]; then
        MLAT_USER="Anonymous-$_mlat_user_short_id"
    else
        MLAT_USER="Anonymous"
    fi
    unset _mlat_user_short_id
fi

# Legacy PRIVACY / MLAT_MARKER read fallback. update.sh's
# migrate_privacy_to_mlat_private converts these to canonical
# MLAT_PRIVATE on every update; this in-memory derivation handles a
# daemon restart that races ahead of the next update.sh. The single
# source of truth for the parsing rules lives in
# scripts/lib/legacy-mlat-translation.sh; the daemon sources it
# defensively (a partial install where this script is in place but the
# lib isn't yet must not take down the daemon — same pattern as the
# state-writer source below). Unrecognised values leave MLAT_PRIVATE
# unset so MLAT_MARKER can fall through, and ultimately the default
# false applies.
LEGACY_MLAT_TR="$(airplanes_path /usr/local/share/airplanes/lib/legacy-mlat-translation.sh)"
if [[ -r "$LEGACY_MLAT_TR" ]]; then
    # shellcheck source=lib/legacy-mlat-translation.sh
    source "$LEGACY_MLAT_TR"
else
    derive_mlat_private_from_privacy() { return 1; }
    derive_mlat_private_from_marker()  { return 1; }
fi
unset LEGACY_MLAT_TR

if [[ ! -v MLAT_PRIVATE && -v PRIVACY ]]; then
    if _v="$(derive_mlat_private_from_privacy "$PRIVACY")"; then
        MLAT_PRIVATE="$_v"
    fi
    unset _v
fi
if [[ ! -v MLAT_PRIVATE && -v MLAT_MARKER ]]; then
    if _v="$(derive_mlat_private_from_marker "$MLAT_MARKER")"; then
        MLAT_PRIVATE="$_v"
    fi
    unset _v
fi
MLAT_PRIVATE="${MLAT_PRIVATE:-false}"

# Legacy GEO_CONFIGURED read fallback. A feed.env predating the explicit
# flag won't have GEO_CONFIGURED set. update.sh's migrate_geo_to_configured_flag
# adds it on every update; this in-memory derivation handles a daemon
# restart that races ahead. Heuristic: BOTH coords numerically zero (or
# empty) → false; anything else → true. The (0,0) point is uninhabited so
# the placeholder pair is unambiguous; a single zero axis is a legitimate
# coordinate (equator at lon!=0, or prime meridian at lat!=0) and counts
# as configured. Matches configure.sh's writer-side heuristic exactly.
_geo_axis_unset_or_zero() {
    [[ -z "$1" ]] && return 0
    [[ "$1" =~ ^[+-]?0+(\.0+)?$ ]] && return 0
    return 1
}
if [[ ! -v GEO_CONFIGURED ]]; then
    if _geo_axis_unset_or_zero "${LATITUDE:-}" && _geo_axis_unset_or_zero "${LONGITUDE:-}"; then
        GEO_CONFIGURED="false"
    else
        GEO_CONFIGURED="true"
    fi
fi

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
#
# These are receive-side endpoints — mlat-client delivers computed MLAT
# positions here for local display only (tar1090/graphs1090 read from
# 30104; the listen ports are for downstream consumers that poll
# mlat-client directly). Upstream contribution flows via mlat-client's
# own --server connection to MLATSERVER, not through any of these.
if [[ ! -v RESULTS && ! -v RESULTS1 && ! -v RESULTS2 && ! -v RESULTS3 && ! -v RESULTS4 ]]; then
    RESULTS="--results beast,connect,127.0.0.1:30104"
    RESULTS2="--results basestation,listen,31015"
    RESULTS3="--results beast,listen,30157"
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
# MLAT off on a fresh feeder before configuring geo sees reason=
# mlat_enabled_false rather than reason=geo_not_configured), then the
# explicit geo flag, then the empty-ALTITUDE strict-fail. MLAT_USER is
# no longer a classifier input — empty values are substituted with a
# per-device Anonymous-<short-id> fallback above. ALTITUDE has no
# fallback: mlat-client gets `--alt ""` if we let an empty value
# through and would silently fail at connect time; fail loud at
# classify time so the state file + journalctl tell the operator
# what's actually missing.
_mlat_classify() {
    case "$MLAT_PRIVATE" in
        true|false) ;;
        *) printf 'misconfigured mlat_private_invalid\n'; return ;;
    esac
    if [[ "$MLAT_ENABLED" != "true" ]]; then printf 'disabled mlat_enabled_false\n'; return; fi
    if [[ "$GEO_CONFIGURED" != "true" ]]; then printf 'disabled geo_not_configured\n'; return; fi
    if [[ -z "$ALTITUDE" ]]; then printf 'misconfigured altitude_empty\n'; return; fi
    printf 'enabled ok\n'
}

# Watch poll interval for the disabled branch below; 0 is a test-only knob
# that makes the branch single-pass (bats). Do not set 0 in production:
# 0 + Restart=always = restart storm. Non-integer values fall back to the
# default rather than crashing `sleep`; the base-10 normalization collapses
# leading zeros ("00" → "0") so the single-pass comparison can't be
# bypassed into a zero-second loop.
AIRPLANES_MLAT_DISABLED_SLEEP="${AIRPLANES_MLAT_DISABLED_SLEEP:-60}"
if [[ "$AIRPLANES_MLAT_DISABLED_SLEEP" =~ ^[0-9]+$ ]]; then
    AIRPLANES_MLAT_DISABLED_SLEEP=$((10#$AIRPLANES_MLAT_DISABLED_SLEEP))
    # An absurd digit string overflows bash arithmetic to a negative
    # value, and a failing `sleep -N` would hot-loop the watch (no set -e
    # here to stop it).
    if (( AIRPLANES_MLAT_DISABLED_SLEEP < 0 )); then
        echo "AIRPLANES_MLAT_DISABLED_SLEEP overflowed; using 60." >&2
        AIRPLANES_MLAT_DISABLED_SLEEP=60
    fi
else
    echo "AIRPLANES_MLAT_DISABLED_SLEEP='$AIRPLANES_MLAT_DISABLED_SLEEP' is not a non-negative integer; using 60." >&2
    AIRPLANES_MLAT_DISABLED_SLEEP=60
fi

# Fingerprint of the config sources governing this activation (see
# _mlat_config_sources above). device:inode:size plus nanosecond
# mtime/ctime catch atomic-rename replacement, in-place rewrites, and
# creation/deletion ("missing", so a file appearing counts as a change).
# stat needs only search permission on the parent directory, so this
# works for the unprivileged service user.
_mlat_config_fingerprint() {
    local f out=""
    for f in "${_mlat_config_sources[@]}"; do
        out+="$(stat -c '%d:%i:%s:%y:%z' "$f" 2>/dev/null || printf 'missing');"
    done
    printf '%s' "$out"
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
    "geo_configured=${GEO_CONFIGURED:-}" \
    "latitude=${LATITUDE:-}" \
    "longitude=${LONGITUDE:-}" \
    "altitude=${ALTITUDE:-}" || true

case "$STATE" in
    disabled)
        echo MLAT DISABLED
        # Idle until a config source changes, then exit 0 so Restart=always
        # re-execs the wrapper against the fresh config. The supported
        # config tools (webconfig, apl-feed apply) restart this unit
        # explicitly when relevant keys change, so the watch only serves
        # hand-edited files. The previous blind hourly exit climbed the
        # systemd restart counter forever on every MLAT-disabled feeder —
        # including every feeder without configured coordinates.
        _mlat_config_baseline="$(_mlat_config_fingerprint)"
        while :; do
            sleep "$AIRPLANES_MLAT_DISABLED_SLEEP"
            if [[ "$(_mlat_config_fingerprint)" != "$_mlat_config_baseline" ]]; then
                exit 0
            fi
            # Test knob: interval 0 means single-pass.
            if [[ "$AIRPLANES_MLAT_DISABLED_SLEEP" == "0" ]]; then
                exit 0
            fi
        done
        ;;
    misconfigured)
        # Matches RestartPreventExitStatus=64 in the unit file so
        # systemd marks the unit failed instead of restart-looping.
        case "$REASON" in
            mlat_private_invalid)
                echo "MLAT_PRIVATE must be 'true' or 'false' (got: '${MLAT_PRIVATE:-}'); refusing to start mlat-client." >&2
                ;;
            altitude_empty)
                echo "MLAT_ENABLED=true but ALTITUDE is empty; refusing to start mlat-client." >&2
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
