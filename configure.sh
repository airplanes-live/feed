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

# Derive MLAT_USER from the sanitized user-supplied feeder name. Empty
# input falls back to DEFAULT_MLAT_NAME. This function does not set
# MLAT_ENABLED — that's the caller's job (set explicitly from
# AIRPLANES_MLAT_ENABLED in non-interactive mode, defaulted to "true"
# in the interactive flow).
derive_mlat_keys() {
    if [[ -z "$NOSPACENAME" ]]; then
        MLAT_USER="$DEFAULT_MLAT_NAME"
    else
        MLAT_USER="$NOSPACENAME"
    fi
}

write_feed_env() {
    derive_mlat_keys
    mkdir -p "$ETC_AIRPLANES"
    tee "$FEED_ENV" >/dev/null <<EOF
INPUT="$INPUT"
REDUCE_INTERVAL="0.5"

# Display name on the MLAT map. Used as the --user argument to mlat-client.
MLAT_USER="$MLAT_USER"
# Explicit on/off toggle for MLAT. When false, airplanes-mlat exits early.
MLAT_ENABLED="$MLAT_ENABLED"

LATITUDE="$RECEIVERLATITUDE"
LONGITUDE="$RECEIVERLONGITUDE"

ALTITUDE="$RECEIVERALTITUDE"

# this is the source for 978 data, use port 30978 from dump978 --raw-port
# if you're not receiving 978, don't worry about it, not doing any harm!
UAT_INPUT="127.0.0.1:30978"

RESULTS="--results beast,connect,127.0.0.1:30104"
RESULTS2="--results basestation,listen,31015"
RESULTS3="--results beast,listen,30157"
RESULTS4="--results beast,connect,127.0.0.1:30187"
# add --privacy between the quotes below to disable having the feed name shown on the mlat map
# (position is never shown accurately no matter the settings)
PRIVACY=""
INPUT_TYPE="$INPUT_TYPE"

MLATSERVER="feed.airplanes.live:31090"
TARGET="--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"
NET_OPTIONS="--net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.2 --net-ro-port 0 --net-sbs-port 0 --net-bi-port 30187 --net-bo-port 0 --net-ri-port 0"
JSON_OPTIONS="--max-range 450 --json-location-accuracy 2 --range-outline-hours 24"
EOF
}

has_noninteractive_config_env() {
    [[ -v AIRPLANES_MLAT_USER || -v AIRPLANES_MLAT_ENABLED \
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
    # via derive_mlat_keys (which write_feed_env calls).
    ADSBFIUSERNAME="${AIRPLANES_MLAT_USER:-}"
    NOSPACENAME="$(sanitize_mlat_user "$ADSBFIUSERNAME")"

    # MLAT_ENABLED is optional and defaults to "true". Only "true" or
    # "false" are accepted; silently coercing other values would mask
    # operator typos.
    case "${AIRPLANES_MLAT_ENABLED:-true}" in
        true|false) MLAT_ENABLED="${AIRPLANES_MLAT_ENABLED:-true}" ;;
        *)
            echo "AIRPLANES_MLAT_ENABLED must be 'true' or 'false' (got: '${AIRPLANES_MLAT_ENABLED:-}')" >&2
            exit 1
            ;;
    esac

    RECEIVERLATITUDE="$AIRPLANES_LATITUDE"
    RECEIVERLONGITUDE="$AIRPLANES_LONGITUDE"
    ALT="$AIRPLANES_ALTITUDE"

    valid_latitude "$RECEIVERLATITUDE" || { echo "Latitude must be a decimal number between -90 and 90." >&2; exit 1; }
    valid_longitude "$RECEIVERLONGITUDE" || { echo "Longitude must be a decimal number between -180 and 180." >&2; exit 1; }
    valid_altitude "$ALT" || { echo "Altitude must be an integer with optional ft or m suffix." >&2; exit 1; }

    RECEIVERALTITUDE="$(normalize_altitude "$ALT")"
    detect_receiver_input
    write_feed_env
}

if has_noninteractive_config_env || airplanes_is_build_mode; then
    configure_noninteractive
    exit 0
fi

whiptail --backtitle "$BACKTITLETEXT" --title "$BACKTITLETEXT" --yesno "Thanks for choosing to share your data with airplanes.live!\n\nairplanes.live is a co-op of ADS-B/Mode S/MLAT feeders from around the world. This script will configure your current ADS-B receiver to feed data to airplanes.live.\n\nWould you like to continue setup?" 13 78 || abort

ADSBFIUSERNAME=$(whiptail --backtitle "$BACKTITLETEXT" --title "Feeder MLAT Name" --nocancel --inputbox "\nPlease enter a unique name to be shown on the MLAT map (the pin will be offset for privacy).\n\nExample: \"william34-london\", \"william34-jersey\", etc.\n\nLeave blank to use the default name \"$DEFAULT_MLAT_NAME\".\n\n(To disable MLAT after setup, run: sudo apl-feed mlat disable)" 14 78 3>&1 1>&2 2>&3) || abort

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

ALT="$(normalize_altitude "$ALT")"

RECEIVERALTITUDE="$ALT"

#RECEIVERPORT=$(whiptail --backtitle "$BACKTITLETEXT" --title "Receiver Feed Port" --nocancel --inputbox "\nChange only if you were assigned a custom feed port.\nFor most all users it is required this port remain set to port 30005." 10 78 "30005" 3>&1 1>&2 2>&3)

# Interactive setup always enables MLAT. Operators who want it off run
# `sudo apl-feed mlat disable` after setup completes.
MLAT_ENABLED="true"

detect_receiver_input
write_feed_env
