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
trap 'echo "------------"; echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR
renice 10 $$ &>/dev/null || true

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/scripts/lib/install-update-common.sh" ]]; then
    # shellcheck source=scripts/lib/install-update-common.sh
    source "$SCRIPT_DIR/scripts/lib/install-update-common.sh"
else
    AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"
    AIRPLANES_FEED_REPO="${AIRPLANES_FEED_REPO:-https://github.com/airplanes-live/feed.git}"
    AIRPLANES_FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-main}"

    airplanes_path() {
        local path="$1"
        if [[ "$AIRPLANES_ROOT" == "/" ]]; then
            printf '%s' "$path"
        else
            printf '%s%s' "${AIRPLANES_ROOT%/}" "$path"
        fi
    }

    airplanes_init_paths() {
        IPATH="$(airplanes_path /usr/local/share/airplanes)"
        GIT="$IPATH/git"
        LOGFILE="$IPATH/lastlog"
        BOOT_CONFIG="$(airplanes_path /boot/airplanes-config.txt)"
        BOOT_ENV="$(airplanes_path /boot/airplanes-env)"
        ETC_AIRPLANES="$(airplanes_path /etc/airplanes)"
        FEED_ENV="$ETC_AIRPLANES/feed.env"
        FEEDER_ID_FILE="$ETC_AIRPLANES/feeder-id"
        LEGACY_UUID_FILE="$IPATH/airplanes-uuid"
        BOOT_UUID_FILE="$(airplanes_path /boot/airplanes-uuid)"
        LEGACY_FEED_ENV="$(airplanes_path /etc/default/airplanes)"
        LOCAL_BIN="$(airplanes_path /usr/local/bin)"
        SYSTEMD_DIR="$(airplanes_path /lib/systemd/system)"
    }

    airplanes_is_image_install() {
        [[ -x "$(airplanes_path /usr/bin/airplanes-feeder)" && ( -f "$FEED_ENV" || -f "$BOOT_CONFIG" ) ]]
    }

    airplanes_image_target_default() {
        printf '%s' '--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004'
    }

    airplanes_is_build_mode() {
        [[ "${AIRPLANES_BUILD_MODE:-0}" == "1" || "${AIRPLANES_BUILD_MODE:-}" == "true" || "${AIRPLANES_BUILD_MODE:-}" == "yes" ]]
    }

    airplanes_enable_build_mode_from_args() {
        local arg
        for arg in "$@"; do
            if [[ "$arg" == "--build-mode" ]]; then
                AIRPLANES_BUILD_MODE=1
                export AIRPLANES_BUILD_MODE
            fi
        done
    }

    airplanes_require_root() {
        if [[ "${AIRPLANES_SKIP_ROOT_CHECK:-0}" == "1" ]]; then
            return 0
        fi
        if [[ "$(id -u)" != "0" ]]; then
            echo -e "\033[33m"
            echo "This script must be ran using sudo or as root."
            echo -e "\033[37m"
            exit 1
        fi
    }

    airplanes_apt_install() {
        if ! apt-get install -y --no-install-recommends --no-install-suggests "$@"; then
            apt-get update || true
            if ! apt-get install -y --no-install-recommends --no-install-suggests "$@"; then
                apt-get clean || true
                apt-get -f install -y || true
                apt-get install --no-install-recommends --no-install-suggests -y "$@"
            fi
        fi
    }

    airplanes_is_legacy_os() {
        grep -E 'wheezy|jessie' "$(airplanes_path /etc/os-release)" -qs
    }

    airplanes_update_packages() {
        local packages
        packages="git wget unzip curl jq build-essential pkg-config python3-dev socat python3-venv ncurses-dev ncurses-bin uuid-runtime zlib1g-dev zlib1g whiptail mawk"
        if ! airplanes_is_legacy_os; then
            packages+=" libzstd-dev libzstd1"
        fi
        printf '%s' "$packages"
    }

    airplanes_install_update_deps() {
        local packages package_manager
        packages="$(airplanes_update_packages)"
        package_manager="${AIRPLANES_PACKAGE_MANAGER:-auto}"

        if [[ "$package_manager" == "apt" ]] || { [[ "$package_manager" == "auto" ]] && command -v apt-get &>/dev/null; }; then
            # shellcheck disable=SC2086
            airplanes_apt_install $packages
            if ! command -v nc &>/dev/null; then
                airplanes_apt_install netcat-openbsd || true
            fi
        elif [[ "$package_manager" == "dnf" ]] || { [[ "$package_manager" == "auto" ]] && command -v dnf &>/dev/null; }; then
            dnf install -y git wget unzip curl jq socat python3-virtualenv python3-devel gcc make pkgconf-pkg-config ncurses-devel newt gawk nc uuid zlib-devel zlib libzstd-devel libzstd
        elif [[ "$package_manager" == "yum" ]] || { [[ "$package_manager" == "auto" ]] && command -v yum &>/dev/null; }; then
            yum install -y git wget unzip curl jq socat python3-virtualenv python3-devel gcc make pkgconfig ncurses-devel newt gawk nc uuid zlib-devel zlib libzstd-devel libzstd
        elif [[ "$package_manager" != "none" ]]; then
            echo "No supported package manager found; continuing with existing system packages." >&2
        fi
    }

    revision() {
        git rev-parse HEAD 2>/dev/null || echo "$RANDOM-$RANDOM"
    }

    getGIT() {
        local repo branch target tmp previous_dir
        if [[ -z "$1" ]] || [[ -z "$2" ]] || [[ -z "$3" ]]; then
            echo "getGIT wrong usage, check your script or tell the author!" 1>&2
            return 1
        fi
        repo="$1"
        branch="$2"
        target="$3"
        previous_dir="$(pwd)"
        tmp="/tmp/getGIT-tmp.$RANDOM.$RANDOM"

        if cd "$target" &>/dev/null && [[ "$(git remote get-url origin)" == "$repo" ]] && git fetch --depth 1 origin "$branch" && git reset --hard FETCH_HEAD; then
            cd "$previous_dir" || return 1
            return 0
        fi

        cd "$previous_dir" || return 1
        if ! cd /tmp || ! rm -rf "$target"; then
            return 1
        fi
        if git clone --depth 1 --single-branch --branch "$branch" "$repo" "$target"; then
            cd "$previous_dir" || return 1
            return 0
        fi
        if wget -O "$tmp" "${repo%".git"}/archive/$branch.zip" && unzip "$tmp" -d "$tmp.folder"; then
            local entries
            mapfile -t entries < <(find "$tmp.folder" -mindepth 1 -maxdepth 1 -print)
            if [[ "${#entries[@]}" -eq 1 ]] && mv -fT "${entries[0]}" "$target"; then
                rm -rf "$tmp" "$tmp.folder"
                cd "$previous_dir" || return 1
                return 0
            fi
        fi
        rm -rf "$tmp" "$tmp.folder"
        cd "$previous_dir" || return 1
        return 1
    }
fi

airplanes_enable_build_mode_from_args "$@"

if [[ $1 == reinstall ]]; then
    REINSTALL=yes
fi

airplanes_init_paths
airplanes_require_root

IMAGE_INSTALL=0
if airplanes_is_image_install; then
    IMAGE_INSTALL=1
fi
IMAGE_SERVICE_LAYOUT=0
if [[ "$IMAGE_INSTALL" == "1" ]] || airplanes_is_build_mode; then
    IMAGE_SERVICE_LAYOUT=1
fi

mkdir -p "$IPATH"
rm -f "$LOGFILE"
touch "$LOGFILE"

airplanes_install_update_deps
hash -r

if [[ "$1" == "test" ]]; then
    TEST_GIT="${AIRPLANES_TEST_GIT:-/tmp/ax_test}"
    cp -T -a ./ "$TEST_GIT"
    GIT="$TEST_GIT"
else
    getGIT "$AIRPLANES_FEED_REPO" "$AIRPLANES_FEED_BRANCH" "$GIT" >> "$LOGFILE"
fi
cd "$GIT"

if [[ -f "$GIT/scripts/lib/install-update-common.sh" ]]; then
    # shellcheck source=scripts/lib/install-update-common.sh
    source "$GIT/scripts/lib/install-update-common.sh"
    airplanes_init_paths
fi

if [[ "$1" != "test" ]] && { [[ ! -f "$IPATH/update.sh" ]] || ! diff "$GIT/update.sh" "$IPATH/update.sh" &>/dev/null; }; then
    rm -f "$IPATH/update.sh"
    cp "$GIT/update.sh" "$IPATH/update.sh"
    bash "$IPATH/update.sh" "$@"
    exit $?
fi
if [[ "$IMAGE_SERVICE_LAYOUT" == "1" ]]; then
    # Images ship these units in /etc/systemd/system, which overrides /lib.
    SYSTEMD_DIR="$(airplanes_path /etc/systemd/system)"
fi

# shellcheck source=scripts/lib/systemd-helpers.sh
source "$GIT/scripts/lib/systemd-helpers.sh"
# shellcheck source=scripts/lib/claim-registration.sh
source "$GIT/scripts/lib/claim-registration.sh"

if [[ "$IMAGE_INSTALL" == "1" ]]; then
    if [[ -f "$FEED_ENV" ]]; then
        source "$FEED_ENV"
    else
        source "$BOOT_CONFIG"
        [[ -f "$BOOT_ENV" ]] && source "$BOOT_ENV"
    fi

    USER="${USER:-airplanes_initial}"
    LATITUDE="${LATITUDE:-0}"
    LONGITUDE="${LONGITUDE:-0}"
    ALTITUDE="${ALTITUDE:-0}"
    INPUT="${INPUT:-127.0.0.1:30005}"
    INPUT_TYPE="${INPUT_TYPE:-dump1090}"
    REDUCE_INTERVAL="${REDUCE_INTERVAL:-0.5}"
    MLATSERVER="${MLATSERVER:-feed.airplanes.live:31090}"
    TARGET="${TARGET:-$(airplanes_image_target_default)}"
    JSON_OPTIONS="${JSON_OPTIONS:-"--json-location-accuracy 2"}"
else
    # Migrate the env file from /etc/default/airplanes to /etc/airplanes/feed.env.
    # Idempotent: only fires when a regular file still exists at the legacy path.
    mkdir -p "$ETC_AIRPLANES"
    if [[ -f "$LEGACY_FEED_ENV" && ! -L "$LEGACY_FEED_ENV" ]]; then
        cp -fp "$LEGACY_FEED_ENV" "$FEED_ENV"
    fi

    if [[ -f "$FEED_ENV" ]]; then
        sed -i -e 's/beast_reduce_out,/beast_reduce_plus_out,/g' "$FEED_ENV" || true
        sed -i -e 's/beast_reduce_plus_out,feed\.airplanes\.live,64004/beast_reduce_plus_out,feed2.airplanes.live,64004/g' "$FEED_ENV" || true
        sed -i -E 's/[[:space:]]*--uuid-file(=|[[:space:]]+)(\/usr\/local\/share\/airplanes\/airplanes-uuid|\/boot\/airplanes-uuid)//g' "$FEED_ENV" || true
    fi

    if [[ -f "$FEED_ENV" ]]; then
        source "$FEED_ENV"
        if ! grep -qs -e UAT_INPUT "$FEED_ENV"; then
            cat >> "$FEED_ENV" <<"EOF"

# this is the source for 978 data, use port 30978 from dump978 --raw-port
# if you're not receiving 978, don't worry about it, not doing any harm!
UAT_INPUT="127.0.0.1:30978"
EOF
        fi
    elif [[ -f "$BOOT_ENV" ]]; then
        source "$BOOT_ENV"
    fi
fi
if [[ -z $INPUT ]] || [[ -z $INPUT_TYPE ]] || [[ -z $USER ]] \
    || [[ -z $LATITUDE ]] || [[ -z $LONGITUDE ]] || [[ -z $ALTITUDE ]] \
    || [[ -z $MLATSERVER ]] || [[ -z $TARGET ]] \
    || { [[ "$IMAGE_INSTALL" != "1" ]] && [[ -z $NET_OPTIONS ]]; }; then
    if [[ "$IMAGE_INSTALL" == "1" ]]; then
        echo "Image configuration is incomplete; refusing to run interactive setup on an image." >&2
        exit 1
    fi
    bash "$GIT/setup.sh"
    exit 0
fi

if [[ "$LATITUDE" == 0 ]] || [[ "$LONGITUDE" == 0 ]] || [[ "$USER" == 0 ]] || [[ "$USER" == "disable" ]]; then
    MLAT_DISABLED=1
else
    MLAT_DISABLED=0
fi

cp "$GIT/uninstall.sh" "$IPATH"
cp "$GIT"/scripts/*.sh "$IPATH"
install -d -m 0755 "$IPATH/apl-feed"
install -m 0644 "$GIT"/scripts/apl-feed/*.sh "$IPATH/apl-feed"
mkdir -p "$LOCAL_BIN"
install -m 0755 "$GIT/scripts/apl-feed.sh" "$LOCAL_BIN/apl-feed"

UNAME=airplanes
if ! id -u "${UNAME}" &>/dev/null
then
    # Try Debian-style adduser, then Fedora-style adduser, then useradd.
    # `||` chains are set -e safe; the trailing block makes the all-failed case explicit.
    adduser --system --home "$IPATH" --no-create-home --quiet "$UNAME" \
        || adduser --system --home-dir "$IPATH" --no-create-home "$UNAME" \
        || useradd --system --home-dir "$IPATH" --no-create-home "$UNAME" \
        || { echo "ERROR: failed to create user '$UNAME' (no working adduser/useradd)." >&2; exit 1; }
fi

echo 4
sleep 0.25

# BUILD AND CONFIGURE THE MLAT-CLIENT PACKAGE

echo
bash "$GIT/create-uuid.sh"

VENV=$IPATH/venv
if [[ -f "$VENV/bin/python3.7" ]] && command -v python3.9 &>/dev/null;
then
    rm -rf "$VENV"
fi

MLAT_REPO="${AIRPLANES_MLAT_REPO:-https://github.com/airplanes-live/mlat-client}"
MLAT_BRANCH="${AIRPLANES_MLAT_BRANCH:-master}"
MLAT_VERSION="$(git ls-remote "$MLAT_REPO" "$MLAT_BRANCH" | cut -f1 || echo "$RANDOM-$RANDOM" )"
if [[ $REINSTALL != yes ]] && grep -e "$MLAT_VERSION" -qs "$IPATH/mlat_version" \
    && grep -qs -e '#!' "$VENV/bin/mlat-client" && { airplanes_is_build_mode || systemctl is-active airplanes-mlat &>/dev/null || [[ "${MLAT_DISABLED}" == "1" ]]; }
then
    echo
    echo "mlat-client already installed, git hash:"
    cat "$IPATH/mlat_version"
    echo
else
    echo
    echo "Installing mlat-client to virtual environment"
    echo
    # Check if the mlat-client git repository already exists.

    MLAT_GIT="$IPATH/mlat-client-git"

    # getGIT REPO BRANCH TARGET-DIR
    getGIT "$MLAT_REPO" "$MLAT_BRANCH" "$MLAT_GIT" &> "$LOGFILE"

    cd "$MLAT_GIT"

    echo 34

    rm "$VENV-backup" -rf
    mv "$VENV" "$VENV-backup" -f &>/dev/null || true
    if /usr/bin/python3 -m venv "$VENV" >> "$LOGFILE" \
        && echo 36 \
        && source "$VENV/bin/activate" >> "$LOGFILE" \
        && echo 37 \
        && python3 -c "import setuptools" || python3 -m pip install setuptools \
        && echo 39 \
        && python3 -c "import asyncore" || python3 -m pip install pyasyncore \
        && python3 -m pip install wheel \
        && echo 40 \
        && pip install . \
        && echo 46 \
        && revision > "$IPATH/mlat_version" || rm -f "$IPATH/mlat_version" \
        && echo 48 \
    ; then
        rm "$VENV-backup" -rf
    else
        rm "$VENV" -rf
        mv "$VENV-backup" "$VENV" &>/dev/null || true
        echo "--------------------"
        echo "Installing mlat-client failed, if there was an old version it has been restored."
        echo "Will continue installation to try and get at least the feed client working."
        echo "Please report this error on Discord."
        echo "--------------------"
    fi
fi

echo 50

# copy airplanes-feed and airplanes-mlat service files
mkdir -p "$SYSTEMD_DIR"
cp "$GIT"/scripts/airplanes-mlat.service "$SYSTEMD_DIR"
cp "$GIT"/scripts/airplanes-feed.service "$SYSTEMD_DIR"
if [[ "$IMAGE_SERVICE_LAYOUT" == "1" ]]; then
    sed -i '/^\[Service\]$/i After=airplanes-first-run.service' "$SYSTEMD_DIR/airplanes-mlat.service"
    sed -i '/^\[Service\]$/i After=airplanes-first-run.service' "$SYSTEMD_DIR/airplanes-feed.service"
fi
if ! airplanes_is_build_mode; then
    systemctl daemon-reload >> "$LOGFILE" || true
fi

echo 60

if airplanes_is_build_mode; then
    systemctl enable airplanes-mlat >> "$LOGFILE" || true
elif is_unit_masked airplanes-mlat.service; then
    echo "--------------------"
    echo "CAUTION, airplanes-mlat is masked and won't run!"
    echo "If this is unexpected for you, please report this issue."
    echo "--------------------"
    sleep 3
else
    if [[ "${MLAT_DISABLED}" == "1" ]]; then
        systemctl disable airplanes-mlat || true
        systemctl stop airplanes-mlat || true
    else
        # Enable airplanes-mlat service
        systemctl enable airplanes-mlat >> "$LOGFILE" || true
        # Start or restart airplanes-mlat service
        systemctl restart airplanes-mlat || true
    fi
fi

echo 70

# SETUP FEEDER TO SEND DUMP1090 DATA TO airplanes.live

if [[ "$IMAGE_INSTALL" == "1" ]]; then
    READSB_BIN="$(airplanes_path /usr/bin/airplanes-feeder)"
    if [[ ! -x "$READSB_BIN" ]]; then
        echo "Image feed binary missing at $READSB_BIN; run the image updater first." >&2
        exit 1
    fi
    echo
    echo "Using image-provided feed client: $READSB_BIN"
    echo
else
    READSB_REPO="${AIRPLANES_READSB_REPO:-https://github.com/airplanes-live/readsb.git}"
    READSB_BRANCH="${AIRPLANES_READSB_BRANCH:-dev}"
    if airplanes_is_legacy_os; then
        READSB_BRANCH="jessie"
    fi
    READSB_VERSION="$(git ls-remote "$READSB_REPO" "$READSB_BRANCH" | cut -f1 || echo "$RANDOM-$RANDOM" )"
    READSB_GIT="$IPATH/readsb-git"
    READSB_BIN="$IPATH/feed-airplanes"
    if [[ $REINSTALL != yes ]] && grep -e "$READSB_VERSION" -qs "$IPATH/readsb_version" \
        && "$READSB_BIN" -V && { airplanes_is_build_mode || systemctl is-active airplanes-feed &>/dev/null; }
    then
        echo
        echo "Feed client already installed, git hash:"
        cat "$IPATH/readsb_version"
        echo
    else
        echo
        echo "Compiling / installing the readsb based feed client"
        echo

        #compile readsb
        echo 72

        # getGIT REPO BRANCH TARGET-DIR
        getGIT "$READSB_REPO" "$READSB_BRANCH" "$READSB_GIT" &> "$LOGFILE"

        cd "$READSB_GIT"

        echo "-----------------------------------------------"
        echo "Now compiling code can take a few minutes"
        echo "-----------------------------------------------"

        echo 74

        make clean
        make -j2 AIRCRAFT_HASH_BITS=12 >> "$LOGFILE"
        echo 80
        rm -f "$READSB_BIN"
        cp readsb "$READSB_BIN"
        revision > "$IPATH/readsb_version" || rm -f "$IPATH/readsb_version"

        echo
    fi
fi

#end compile readsb

echo 82

if airplanes_is_build_mode; then
    systemctl enable airplanes-feed >> "$LOGFILE" || true
    echo 92
elif ! is_unit_masked airplanes-feed.service; then
    # Enable airplanes-feed service
    systemctl enable airplanes-feed >> "$LOGFILE" || true
    echo 92
    # Start or restart airplanes-feed service
    systemctl restart airplanes-feed || true
else
    echo "--------------------"
    echo "CAUTION, airplanes-feed.service is masked and won't run!"
    echo "If this is unexpected for you, please report this issue."
    echo "--------------------"
    sleep 3
fi

echo 94

if ! airplanes_is_build_mode; then
    systemctl is-active airplanes-feed &>/dev/null || {
        rm -f "$IPATH/readsb_version"
        echo "---------------------------------"
        journalctl -u airplanes-feed | tail -n10
        echo "---------------------------------"
        echo "airplanes-feed service couldn't be started, please report this error on Discord."
        echo "Try an copy as much of the output above and include it in your report, thank you!"
        echo "---------------------------------"
        exit 1
    }
fi

echo 96

if ! airplanes_is_build_mode; then
    [[ "${MLAT_DISABLED}" == "1" ]] || systemctl is-active airplanes-mlat &>/dev/null || {
        rm -f "$IPATH/mlat_version"
        echo "---------------------------------"
        journalctl -u airplanes-mlat | tail -n10
        echo "---------------------------------"
        echo "airplanes-mlat service couldn't be started, please report this error on Discord."
        echo "Try an copy as much of the output above and include it in your report, thank you!"
        echo "---------------------------------"
        exit 1
    }

    register_claim_secret
fi

# Remove old method of starting the feed scripts if present from rc.local
# Kill the old airplanes.live scripts in case they are still running from a previous install including spawned programs
RC_LOCAL="$(airplanes_path /etc/rc.local)"
if ! airplanes_is_build_mode; then
    for name in airplanes-netcat_maint.sh airplanes-socat_maint.sh airplanes-mlat_maint.sh; do
        if [[ -f "$RC_LOCAL" ]] && grep -qs -e "$name" "$RC_LOCAL"; then
            sed -i -e "/$name/d" "$RC_LOCAL" || true
        fi
        if PID="$(pgrep -f "$name" 2>/dev/null)" && PIDS="$PID $(pgrep -P "$PID" 2>/dev/null)"; then
            echo killing: "$PIDS" >> "$LOGFILE" 2>&1 || true
            kill -9 $PIDS >> "$LOGFILE" 2>&1 || true
        fi
    done
fi

# in case the mlat-client service using /etc/default/mlat-client as config is using airplanes.live as a host, disable the service
MLAT_CLIENT_DEFAULT="$(airplanes_path /etc/default/mlat-client)"
if ! airplanes_is_build_mode && grep -qs 'SERVER_HOSTPORT.*feed.airplanes.live' "$MLAT_CLIENT_DEFAULT" &>/dev/null; then
    systemctl disable --now mlat-client >> "$LOGFILE" 2>&1 || true
fi

if [[ "$IMAGE_INSTALL" != "1" ]]; then
    # Replace the legacy regular file with a compat symlink, only after the
    # services have been restarted using the new path (above). Idempotent:
    # ln -sfn updates an existing symlink in place.
    mkdir -p "$(dirname "$LEGACY_FEED_ENV")"
    if [[ -f "$LEGACY_FEED_ENV" && ! -L "$LEGACY_FEED_ENV" ]]; then
        rm -f "$LEGACY_FEED_ENV"
    fi
    ln -sfn "$FEED_ENV" "$LEGACY_FEED_ENV"
fi

echo 100
echo "---------------------"
echo "---------------------"

## SETUP COMPLETE

ENDTEXT="
Thanks for choosing to share your data with airplanes.live!

Check https://airplanes.live/myfeed/ for feeder status!

Your feed should be active within 5 minutes, you can confirm by running the following command and looking for the IP address 78.46.234.18
netstat -t -n | grep -E '30004|31090'

Question? Issues? Go here:
https://discord.gg/jfVRF2XRwF

Web interface to show the data transmitted? Run this command:
sudo bash /usr/local/share/airplanes/git/install-or-update-interface.sh
"

INPUT_IP=$(echo "$INPUT" | cut -d: -f1)
INPUT_PORT=$(echo "$INPUT" | cut -d: -f2)

ENDTEXT2="
---------------------
No data available from IP $INPUT_IP on port $INPUT_PORT!
---------------------
"
if [[ -f "$(airplanes_path /etc/fr24feed.ini)" ]] || [[ -f "$(airplanes_path /etc/rb24.ini)" ]]; then
    ENDTEXT2+="
It looks like you are running FR24 or RB24
This means you will need to install a stand-alone decoder so data are avaible on port 30005!

If you have the SDR connected to this device, we recommend using this script to install and configure a stand-alone decoder:

https://github.com/wiedehopf/adsb-scripts/wiki/Automatic-installation-for-readsb
---------------------
"
else
    ENDTEXT2+="
If you have connected an SDR but not yet installed an ADS-B decoder for it,
we recommend this script:

https://github.com/wiedehopf/adsb-scripts/wiki/Automatic-installation-for-readsb
---------------------
"
fi

if airplanes_is_build_mode; then
    echo "Build mode setup complete; skipping receiver connectivity probe."
elif ! timeout 5 nc -z "$INPUT_IP" "$INPUT_PORT" && command -v nc &>/dev/null; then
    #whiptail --title "airplanes.live Setup Script" --msgbox "$ENDTEXT2" 24 73
    echo -e "$ENDTEXT2"
else
    # Display the thank you message box.
    #whiptail --title "airplanes.live Setup Script" --msgbox "$ENDTEXT" 24 73
    echo -e "$ENDTEXT"
fi
