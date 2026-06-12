#!/bin/bash

#####################################################################################
#                        airplanes.live SETUP SCRIPT                                #
#####################################################################################
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#                                                                                   #
# Copyright (c) 2023 AirDG                                                          #
#                                                                                   #
# Permission is hereby granted, free of charge, to any person obtaining a copy      #
# of this software and associated documentation files (the "Software"), to deal     #
# in the Software without restriction, including without limitation the rights      #
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell         #
# copies of the Software, and to permit persons to whom the Software is             #
# furnished to do so, subject to the following conditions:                          #
#                                                                                   #
# The above copyright notice and this permission notice shall be included in all    #
# copies or substantial portions of the Software.                                   #
#                                                                                   #
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR        #
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,          #
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE       #
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER            #
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,     #
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE     #
# SOFTWARE.                                                                         #
#                                                                                   #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR
renice 10 $$ &>/dev/null || true

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/install-update-common.sh
source "$SCRIPT_DIR/scripts/lib/install-update-common.sh"
# shellcheck source=scripts/lib/configure-validators.sh
source "$SCRIPT_DIR/scripts/lib/configure-validators.sh"
# feed-env-keys.sh + feed-env-apply.sh are sourced for the feed.meta.json
# sidecar helpers (read/write/iso-now/tracked-keys) used by write_feed_env
# to stamp feeder-edit metadata. Both are side-effect-free to source.
# shellcheck source=scripts/lib/feed-env-keys.sh
source "$SCRIPT_DIR/scripts/lib/feed-env-keys.sh"
# shellcheck source=scripts/lib/feed-env-apply.sh
source "$SCRIPT_DIR/scripts/lib/feed-env-apply.sh"
airplanes_enable_build_mode_from_args "$@"
airplanes_init_paths

# Fallback name used when the operator doesn't supply one (empty or unset
# AIRPLANES_MLAT_USER, or blank input in the interactive prompt). Multiple
# feeders sharing this name on the MLAT map is the expected outcome.
DEFAULT_MLAT_NAME="Anonymous"

function abort() {
    echo ------------
    echo "Setup canceled (probably using Esc button)!"
    echo "Please re-run this setup if this wasn't your intention."
    echo ------------
    exit 1
}

## WHIPTAIL DIALOGS

BACKTITLETEXT="airplanes.live Setup Script"

detect_receiver_input() {
    INPUT="127.0.0.1:30005"
    INPUT_TYPE="dump1090"

    # `hostname` and `pgrep` (procps) are absent on some minimal images — guard both.
    HOSTNAME_VAL="$(hostname 2>/dev/null || uname -n 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
    if [[ "$HOSTNAME_VAL" == "radarcape" ]] || { command -v pgrep &>/dev/null && pgrep rcd &>/dev/null; }; then
        INPUT="127.0.0.1:10003"
        INPUT_TYPE="radarcape_gps"
    fi
}

# Derive MLAT_USER from the sanitized user-supplied feeder name. A
# supplied name is used verbatim. Empty input falls back to
# DEFAULT_MLAT_NAME — except in build mode, where it is left empty so a
# generic baked image defers to airplanes-mlat's per-device
# "Anonymous-<short-id>" runtime fallback instead of freezing one shared
# literal name into every flashed card. On a re-run, write_feed_env
# overrides the empty-input fallback with a valid existing on-disk name.
# This function does not set MLAT_ENABLED — that's resolved in
# write_feed_env (explicit AIRPLANES_MLAT_ENABLED wins, else a valid
# existing on-disk value is preserved, else "true").
derive_mlat_keys() {
    if [[ -n "$NOSPACENAME" ]]; then
        MLAT_USER="$NOSPACENAME"
    elif airplanes_is_build_mode 2>/dev/null; then
        MLAT_USER=""
    else
        MLAT_USER="$DEFAULT_MLAT_NAME"
    fi
}

# Heuristic: treat (0, 0) as the legacy/placeholder sentinel pair (image
# freeze writes both as 0). A single zero axis is a legitimate coordinate
# (equator at lon!=0, or prime meridian at lat!=0) and counts as
# configured. The Atlantic (0,0) point is uninhabited so the false-
# negative blast radius is empty in practice. Recognizes decimal/signed
# zero forms (0.00000, +0, -0) so a noninteractive AIRPLANES_LATITUDE that
# uses a decimal-zero placeholder isn't misclassified as configured.
_geo_axis_unset_or_zero() {
    [[ -z "$1" ]] && return 0
    [[ "$1" =~ ^[+-]?0+(\.0+)?$ ]] && return 0
    return 1
}
derive_geo_configured() {
    if _geo_axis_unset_or_zero "$RECEIVERLATITUDE" \
        && _geo_axis_unset_or_zero "$RECEIVERLONGITUDE"; then
        GEO_CONFIGURED="false"
    else
        GEO_CONFIGURED="true"
    fi
}

# Keys write_feed_env re-derives and emits via its template. Any other
# KEY= line in an existing feed.env is operator data (backend overrides
# like TARGET/MLATSERVER/APL_FEED_WEBSITE_URL, or apl-feed-apply-written
# keys like GAIN/REPORT_STATUS) and is carried over verbatim on rewrite.
# Spaces around each name make the `case` containment match exact.
WRITE_FEED_ENV_OWNED_KEYS=" LATITUDE LONGITUDE ALTITUDE GEO_CONFIGURED MLAT_USER MLAT_ENABLED MLAT_PRIVATE INPUT INPUT_TYPE "

# Strict single-key read from an existing feed.env: double-quoted,
# single-quoted, or bare-until-whitespace/comment forms; last occurrence
# wins (matches `source` last-write-wins). Leading whitespace is
# tolerated, mirroring harvest_feed_env_overrides' owned-key match (an
# indented owned key must be readable here, or it would be neither
# carried nor preserved). Deliberately NOT `source` — configure.sh must
# not execute operator-supplied shell content. Returns 1 when the key is
# absent, empty, or doesn't match a strict form.
read_existing_feed_env_value() {
    local key="$1" file="$2" output
    [[ -f "$file" ]] || return 1
    output="$(sed -n \
        -e "s/^[[:space:]]*${key}=\"\\(.*\\)\"[[:space:]]*$/\\1/p" \
        -e "s/^[[:space:]]*${key}='\\(.*\\)'[[:space:]]*$/\\1/p" \
        -e "s/^[[:space:]]*${key}=\\([^#[:space:]]*\\).*$/\\1/p" \
        "$file" | tail -n 1)"
    [[ -n "$output" ]] || return 1
    printf '%s' "$output"
}

# Collect unowned KEY= lines from the existing feed.env into the
# caller-visible CARRIED_FEED_ENV_LINES array — verbatim bytes, original
# order, duplicates kept (`source` last-write-wins still applies). The
# key is extracted after stripping leading whitespace so an indented
# owned key (e.g. "  LATITUDE=…") counts as owned and cannot ride along
# to shadow the freshly templated value. Comments and non-KEY= lines are
# not carried.
harvest_feed_env_overrides() {
    local file="$1" line stripped key
    CARRIED_FEED_ENV_LINES=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        [[ "$stripped" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        key="${BASH_REMATCH[1]}"
        case "$WRITE_FEED_ENV_OWNED_KEYS" in
            *" $key "*) continue ;;
        esac
        CARRIED_FEED_ENV_LINES+=("$line")
    done < "$file"
}

# Resolve a true/false toggle: explicit caller choice wins, else a valid
# existing on-disk value is preserved, else the default. An existing
# value that doesn't strictly parse as true|false (hand-edited junk, or
# a quoted value with a trailing comment) falls back to the default.
resolve_feed_env_toggle() {
    local explicit="$1" key="$2" file="$3" default="$4" existing
    case "$explicit" in
        true|false)
            printf '%s' "$explicit"
            return 0
            ;;
    esac
    if existing="$(read_existing_feed_env_value "$key" "$file")"; then
        case "$existing" in
            true|false)
                printf '%s' "$existing"
                return 0
                ;;
        esac
    fi
    printf '%s' "$default"
}

# Stamp feeder-edit metadata into feed.meta.json for tracked keys whose
# value changed in this rewrite. Without fresh stamps, a feeder with
# REMOTE_CONFIG_ENABLED=true would let the next config sync overwrite
# just-entered values: absent sidecar metadata sorts as the legacy epoch,
# so the server's tuple would win last-write-wins against this setup run.
# Sidecar failure is a warning, not fatal — feed.env is already written
# and must not be held hostage by an informational sidecar.
stamp_feed_env_sidecar() {
    # shellcheck disable=SC2178  # nameref to the caller's assoc array
    local -n prev_ref="$1"
    local meta_path key new_value now_iso changed=0
    meta_path="$(dirname "$FEED_ENV")/$APL_FEED_APPLY_META_BASENAME"
    local -A meta_at=() meta_by=()
    _apl_feed_apply_read_meta "$meta_path" meta_at meta_by
    now_iso="$(_apl_feed_apply_iso_now)"
    for key in "${APL_FEED_APPLY_META_TRACKED_KEYS[@]}"; do
        case "$key" in
            LATITUDE) new_value="$RECEIVERLATITUDE" ;;
            LONGITUDE) new_value="$RECEIVERLONGITUDE" ;;
            ALTITUDE) new_value="$RECEIVERALTITUDE" ;;
            MLAT_USER) new_value="$MLAT_USER" ;;
            MLAT_ENABLED) new_value="$MLAT_ENABLED" ;;
            MLAT_PRIVATE) new_value="$MLAT_PRIVATE" ;;
            *) continue ;;
        esac
        if [[ -z "${prev_ref[$key]+set}" || "${prev_ref[$key]}" != "$new_value" ]]; then
            meta_at[$key]="$now_iso"
            meta_by[$key]="feeder"
            changed=1
        fi
    done
    (( changed )) || return 0
    if ! _apl_feed_apply_write_meta "$meta_path" "$FEED_ENV" meta_at meta_by; then
        echo "configure: warning: could not update feed.meta.json (feed.env was written)" >&2
    fi
}

write_feed_env() {
    derive_mlat_keys
    derive_geo_configured
    mkdir -p "$ETC_AIRPLANES"
    # Hold /run/airplanes/feed-env.lock for the whole read-then-rewrite
    # window so a concurrent apl-feed apply (privileged writer in
    # webconfig and the CLI) cannot land an update between the harvest
    # below and the final rename. Build mode and missing-/run rootfs skip
    # the lock; acquired but timed-out is a hard failure to prevent
    # silent interleaving.
    local _feed_lock_fd=""
    if ! airplanes_is_build_mode 2>/dev/null \
        && command -v flock >/dev/null 2>&1 \
        && [[ -d /run ]]; then
        mkdir -p /run/airplanes 2>/dev/null || true
        if exec {_feed_lock_fd}>/run/airplanes/feed-env.lock 2>/dev/null; then
            if ! flock -w 30 "$_feed_lock_fd"; then
                eval "exec ${_feed_lock_fd}>&-"
                echo "configure: could not acquire /run/airplanes/feed-env.lock after 30s" >&2
                exit 1
            fi
        else
            _feed_lock_fd=""
        fi
    fi

    # All reads of the previous file happen inside the lock window:
    # carried operator lines, toggle preservation, receiver-input
    # preservation, and the pre-rewrite snapshot of sidecar-tracked
    # values used to decide which metadata stamps to refresh.
    harvest_feed_env_overrides "$FEED_ENV"
    MLAT_ENABLED="$(resolve_feed_env_toggle "${MLAT_ENABLED:-}" MLAT_ENABLED "$FEED_ENV" true)"
    MLAT_PRIVATE="$(resolve_feed_env_toggle "${MLAT_PRIVATE:-}" MLAT_PRIVATE "$FEED_ENV" false)"
    # An existing feeder name survives a re-run when the operator didn't
    # supply one (blank prompt input or unset AIRPLANES_MLAT_USER would
    # otherwise reset the map name to the default).
    local _existing
    if [[ -z "$NOSPACENAME" ]] \
        && _existing="$(read_existing_feed_env_value MLAT_USER "$FEED_ENV")" \
        && valid_mlat_user_strict "$_existing"; then
        MLAT_USER="$_existing"
    fi
    # A hand-set receiver override (custom INPUT/INPUT_TYPE) survives a
    # setup re-run; detect_receiver_input's heuristic only fills keys the
    # operator never set. Charset-guarded: the preserved value is
    # re-emitted inside double quotes by the template, so anything that
    # could change meaning there (quotes, $, backticks, whitespace) falls
    # back to detection instead of being rewritten into a live shape.
    if _existing="$(read_existing_feed_env_value INPUT "$FEED_ENV")" \
        && [[ "$_existing" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        INPUT="$_existing"
    fi
    if _existing="$(read_existing_feed_env_value INPUT_TYPE "$FEED_ENV")" \
        && [[ "$_existing" =~ ^[A-Za-z0-9_]+$ ]]; then
        INPUT_TYPE="$_existing"
    fi
    local -A _prev_tracked=()
    local _tk _tv
    for _tk in "${APL_FEED_APPLY_META_TRACKED_KEYS[@]}"; do
        if _tv="$(read_existing_feed_env_value "$_tk" "$FEED_ENV")"; then
            _prev_tracked[$_tk]="$_tv"
        fi
    done

    # Compose the whole new file in a temp sibling and rename it into
    # place: the daemons `source` feed.env directly at activation and
    # must never observe a truncated half-written file.
    local _tmp
    _tmp="$(mktemp "${FEED_ENV}.XXXXXX")"
    cat > "$_tmp" <<EOF
# /etc/airplanes/feed.env — operator-supplied configuration for the
# airplanes.live feeder daemons. Product-side defaults (brand endpoints,
# readsb tuning, the local RESULTS output bundle, REDUCE_INTERVAL) live
# in the daemon scripts; add overrides here only if you run a custom
# airplanes.live backend or non-default decoder hardware.
#
# Format contract: one KEY=value or KEY="value" per line, plain scalar
# values only — no shell expansion or escapes, no 'export' prefix, no
# comment on a value's line, no line continuations. This file has
# several consumers (shell, systemd, the apl-feed CLI); other shapes
# parse differently between them and may be dropped on rewrite. Read
# values with 'apl-feed config show' instead of parsing this file.

LATITUDE="$RECEIVERLATITUDE"
LONGITUDE="$RECEIVERLONGITUDE"
ALTITUDE="$RECEIVERALTITUDE"
# Explicit "user has provided real coordinates" flag. The daemon refuses
# to start MLAT until this is true; the legacy "LATITUDE=0 means unset"
# sentinel is retired. Image freeze writes false; configure.sh writes
# true when both coords are non-zero (Atlantic 0,0 placeholders stay
# false). The webconfig UI writes this explicitly when the user saves.
GEO_CONFIGURED=$GEO_CONFIGURED

# Display name shown on the MLAT map. Used as mlat-client's --user.
MLAT_USER="$MLAT_USER"
# Explicit on/off toggle. When false, airplanes-mlat exits early.
MLAT_ENABLED="$MLAT_ENABLED"
# Hide the feed name on the public MLAT map. true|false. Position is
# never shown accurately no matter the setting. Toggle with:
#   sudo apl-feed mlat private enable
#   sudo apl-feed mlat private disable
MLAT_PRIVATE=$MLAT_PRIVATE

# Diagnostics push: every 10 minutes the feeder reports anonymized CPU,
# temperature, disk, memory, uptime, service health, and version info to
# airplanes.live. Visible only on your own logged-in dashboard. The
# schema excludes hostname, MAC, LAN IP, SSID, and Pi serial number.
#
# Default: enabled. Toggle via the CLI (the canonical writer, which also
# runs through validation + the apply lock):
#   sudo apl-feed diagnostics enable
#   sudo apl-feed diagnostics disable
# Don't hand-edit REPORT_STATUS below — direct edits bypass validation
# and the lock that webconfig holds during concurrent writes.
#REPORT_STATUS=true
EOF

    # Write INPUT + INPUT_TYPE only when they differ from the daemon
    # defaults (127.0.0.1:30005 / dump1090). detect_receiver_input sets
    # both together (Radarcape uses 127.0.0.1:10003 / radarcape_gps),
    # so emit them as a pair to keep the override consistent.
    if [[ "$INPUT" != "127.0.0.1:30005" ]] || [[ "$INPUT_TYPE" != "dump1090" ]]; then
        cat >> "$_tmp" <<EOF

# Non-default receiver decoder. Defaults are 127.0.0.1:30005 / dump1090.
INPUT="$INPUT"
INPUT_TYPE="$INPUT_TYPE"
EOF
    fi

    if (( ${#CARRIED_FEED_ENV_LINES[@]} > 0 )); then
        {
            printf '\n# Carried over from the previous feed.env by setup. Keys not managed\n'
            printf '# by setup are preserved verbatim; comments around them are not.\n'
            printf '%s\n' "${CARRIED_FEED_ENV_LINES[@]}"
        } >> "$_tmp"
    fi

    if [[ -f "$FEED_ENV" ]]; then
        chmod --reference="$FEED_ENV" "$_tmp" 2>/dev/null || chmod 0644 "$_tmp" || true
        chown --reference="$FEED_ENV" "$_tmp" 2>/dev/null || true
    else
        chmod 0644 "$_tmp" 2>/dev/null || true
    fi
    mv -f "$_tmp" "$FEED_ENV"

    # Stamp sidecar metadata for tracked keys this rewrite changed, while
    # still holding the lock. Skipped in build mode — the image freeze is
    # not an operator edit and the chroot has no /run.
    if ! airplanes_is_build_mode 2>/dev/null; then
        stamp_feed_env_sidecar _prev_tracked
    fi

    if [[ -n "$_feed_lock_fd" ]]; then
        eval "exec ${_feed_lock_fd}>&-"
    fi
}

has_noninteractive_config_env() {
    [[ -v AIRPLANES_MLAT_USER || -v AIRPLANES_MLAT_ENABLED || -v AIRPLANES_MLAT_PRIVATE \
       || -v AIRPLANES_LATITUDE || -v AIRPLANES_LONGITUDE || -v AIRPLANES_ALTITUDE ]]
}

configure_noninteractive() {
    local missing=0 name
    for name in AIRPLANES_LATITUDE AIRPLANES_LONGITUDE AIRPLANES_ALTITUDE; do
        if [[ ! -v "$name" ]]; then
            echo "Missing required non-interactive configure value: $name" >&2
            missing=1
        fi
    done
    [[ "$missing" == "0" ]] || exit 1

    # MLAT_USER is optional. Empty / unset falls back to DEFAULT_MLAT_NAME
    # via derive_mlat_keys (which write_feed_env calls) — except in build
    # mode, where it stays empty for the daemon's per-device fallback.
    ADSBFIUSERNAME="${AIRPLANES_MLAT_USER:-}"
    NOSPACENAME="$(sanitize_mlat_user "$ADSBFIUSERNAME")"

    # MLAT_ENABLED is optional. Unset or empty → preserve an existing
    # valid value from feed.env, falling back to "true" (resolved inside
    # write_feed_env's lock window). Set non-empty → strict true|false;
    # silently coercing other values would mask operator typos.
    if [[ -n "${AIRPLANES_MLAT_ENABLED:-}" ]]; then
        case "$AIRPLANES_MLAT_ENABLED" in
            true|false) MLAT_ENABLED="$AIRPLANES_MLAT_ENABLED" ;;
            *)
                echo "AIRPLANES_MLAT_ENABLED must be 'true' or 'false' (got: '$AIRPLANES_MLAT_ENABLED')" >&2
                exit 1
                ;;
        esac
    else
        MLAT_ENABLED=""
    fi

    # MLAT_PRIVATE is optional; same preserve-or-default contract as
    # MLAT_ENABLED, with "false" (name shown on the MLAT map) as default.
    if [[ -n "${AIRPLANES_MLAT_PRIVATE:-}" ]]; then
        case "$AIRPLANES_MLAT_PRIVATE" in
            true|false) MLAT_PRIVATE="$AIRPLANES_MLAT_PRIVATE" ;;
            *)
                echo "AIRPLANES_MLAT_PRIVATE must be 'true' or 'false' (got: '$AIRPLANES_MLAT_PRIVATE')" >&2
                exit 1
                ;;
        esac
    else
        MLAT_PRIVATE=""
    fi

    RECEIVERLATITUDE="$AIRPLANES_LATITUDE"
    RECEIVERLONGITUDE="$AIRPLANES_LONGITUDE"
    ALT="$AIRPLANES_ALTITUDE"

    valid_latitude "$RECEIVERLATITUDE" || { echo "Latitude must be a decimal number between -90 and 90." >&2; exit 1; }
    valid_longitude "$RECEIVERLONGITUDE" || { echo "Longitude must be a decimal number between -180 and 180." >&2; exit 1; }
    valid_altitude "$ALT" || { echo "Altitude must be an integer with optional ft or m suffix." >&2; exit 1; }

    RECEIVERALTITUDE="$(altitude_to_bare_metres "$ALT")"
    detect_receiver_input
    write_feed_env
}

if has_noninteractive_config_env || airplanes_is_build_mode; then
    configure_noninteractive
    exit 0
fi

whiptail --backtitle "$BACKTITLETEXT" --title "$BACKTITLETEXT" --yesno "Thanks for choosing to share your data with airplanes.live!\n\nairplanes.live is a co-op of ADS-B/Mode S/MLAT feeders from around the world. This script will configure your current ADS-B receiver to feed data to airplanes.live.\n\nWould you like to continue setup?" 13 78 || abort

# On a re-run, blank input keeps the existing name (write_feed_env
# preserves it); tell the operator which behavior blank gets them.
EXISTING_MLAT_USER="$(read_existing_feed_env_value MLAT_USER "$FEED_ENV" 2>/dev/null || true)"
if [[ -n "$EXISTING_MLAT_USER" ]] && valid_mlat_user_strict "$EXISTING_MLAT_USER"; then
    MLAT_NAME_BLANK_HINT="Leave blank to keep the current name \"$EXISTING_MLAT_USER\"."
else
    MLAT_NAME_BLANK_HINT="Leave blank to use the default name \"$DEFAULT_MLAT_NAME\"."
fi

ADSBFIUSERNAME=$(whiptail --backtitle "$BACKTITLETEXT" --title "Feeder MLAT Name" --nocancel --inputbox "\nPlease enter a unique name to be shown on the MLAT map (the pin will be offset for privacy).\n\nExample: \"william34-london\", \"william34-jersey\", etc.\n\n$MLAT_NAME_BLANK_HINT\n\n(To disable MLAT after setup, run: sudo apl-feed mlat disable)" 14 78 3>&1 1>&2 2>&3) || abort

NOSPACENAME="$(sanitize_mlat_user "$ADSBFIUSERNAME")"

whiptail --backtitle "$BACKTITLETEXT" --title "$BACKTITLETEXT" \
    --msgbox "For MLAT the precise location of your antenna is required.\
    \n\nA small error of 15m/45ft will cause issues with MLAT!\
    \n\nTo get your location, use any online map service or this website: https://www.mapcoordinates.net/en" 12 78 || abort

#((-90 <= RECEIVERLATITUDE <= 90))
LAT_OK=0
until [ "$LAT_OK" -eq 1 ]; do
    RECEIVERLATITUDE=$(whiptail --backtitle "$BACKTITLETEXT" --title "Antenna Latitude ${RECEIVERLATITUDE}" --nocancel --inputbox "\nEnter the latitude of your antenna in degrees with 5 decimal places.\n(Example: 32.36291)" 12 78 3>&1 1>&2 2>&3) || abort
    if valid_latitude "$RECEIVERLATITUDE"; then
        LAT_OK=1
    else
        LAT_OK=0
        if [[ ! "$RECEIVERLATITUDE" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
            whiptail --backtitle "$BACKTITLETEXT" --title "Invalid latitude" --msgbox "Latitude must be a decimal number." 10 60 || abort
        fi
    fi
done


#((-180<= RECEIVERLONGITUDE <= 180))
LON_OK=0
until [ "$LON_OK" -eq 1 ]; do
    RECEIVERLONGITUDE=$(whiptail --backtitle "$BACKTITLETEXT" --title "Antenna Longitude ${RECEIVERLONGITUDE}" --nocancel --inputbox "\nEnter the longitude of your antenna in degrees with 5 decimal places.\n(Example: -64.71492)" 12 78 3>&1 1>&2 2>&3) || abort
    if valid_longitude "$RECEIVERLONGITUDE"; then
        LON_OK=1
    else
        LON_OK=0
        if [[ ! "$RECEIVERLONGITUDE" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
            whiptail --backtitle "$BACKTITLETEXT" --title "Invalid longitude" --msgbox "Longitude must be a decimal number." 10 60 || abort
        fi
    fi
done

ALT=0
until [[ $ALT =~ ^-?[0-9]+ft$ ]] || [[ $ALT =~ ^-?[0-9]+m$ ]]; do
    ALT=$(whiptail --backtitle "$BACKTITLETEXT" --title "Altitude above sea level (at the antenna):" \
        --nocancel --inputbox \
"\nEnter the altitude of your antenna, above sea level, including the unit with no spaces:\n\n\
in feet like this:                   255ft\n\
or in meters like this:               78m\n" \
        12 78 3>&1 1>&2 2>&3) || abort
done

ALT="$(altitude_to_bare_metres "$ALT")"

RECEIVERALTITUDE="$ALT"

#RECEIVERPORT=$(whiptail --backtitle "$BACKTITLETEXT" --title "Receiver Feed Port" --nocancel --inputbox "\nChange only if you were assigned a custom feed port.\nFor most all users it is required this port remain set to port 30005." 10 78 "30005" 3>&1 1>&2 2>&3)

# Interactive setup takes no explicit MLAT toggle choice: an existing
# MLAT_ENABLED/MLAT_PRIVATE survives a re-run (so fixing coordinates
# doesn't undo `apl-feed mlat disable` / `mlat private enable`); first
# setup defaults to enabled + name shown on the map.
MLAT_ENABLED=""
MLAT_PRIVATE=""

detect_receiver_input
write_feed_env
