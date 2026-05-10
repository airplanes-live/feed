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

    airplanes_resolve_latest_stable_tag() {
        local repo="${1:-$AIRPLANES_FEED_REPO}"
        local refs latest=""
        if ! refs="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$repo" 2>/dev/null)"; then
            return 2
        fi
        if [[ -z "$refs" ]]; then
            return 1
        fi
        local _sha _refname _tag
        while IFS=$'\t' read -r _sha _refname; do
            _tag="${_refname#refs/tags/}"
            if [[ "$_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
                if [[ -z "$latest" ]]; then
                    latest="$_tag"
                else
                    latest="$(printf '%s\n%s\n' "$latest" "$_tag" | sort -V | tail -n 1)"
                fi
            fi
        done <<< "$refs"
        if [[ -z "$latest" ]]; then
            return 1
        fi
        printf '%s' "$latest"
        return 0
    }

    airplanes_resolve_feed_branch() {
        if [[ "${AIRPLANES_FEED_BRANCH:-}" != "stable" ]]; then
            return 0
        fi
        local resolved rc=0
        resolved="$(airplanes_resolve_latest_stable_tag "$AIRPLANES_FEED_REPO")" || rc=$?
        case $rc in
            0)
                AIRPLANES_FEED_BRANCH="$resolved"
                export AIRPLANES_FEED_BRANCH
                ;;
            1)
                echo "ERROR: stable release channel selected but no v[MAJOR].[MINOR].[PATCH] tags exist at $AIRPLANES_FEED_REPO." >&2
                echo "       Keeping current install unchanged." >&2
                exit 1
                ;;
            2)
                echo "ERROR: could not query release tags from $AIRPLANES_FEED_REPO (network/DNS/TLS failure)." >&2
                echo "       Keeping current install unchanged." >&2
                exit 1
                ;;
        esac
    }

    # Image-built feeders pin their runtime-update channel via
    # /etc/airplanes/release-channel. Allowlist: stable, dev, main. 'main'
    # is accepted as a legacy alias for 'stable' so pre-stable images stay
    # updatable without a re-flash. Manual installs without the file
    # default to the stable channel.
    #
    # For the stable channel, AIRPLANES_FEED_BRANCH is set to the literal
    # "stable" sentinel here; the actual tag is resolved later by
    # airplanes_resolve_feed_branch (which calls git ls-remote).
    if [[ -z "${AIRPLANES_FEED_BRANCH:-}" ]]; then
        _release_channel_file="${AIRPLANES_ROOT%/}/etc/airplanes/release-channel"
        if [[ -r "$_release_channel_file" ]]; then
            _release_channel="$(head -n1 "$_release_channel_file" | tr -d '[:space:]')"
            case "$_release_channel" in
                stable|main) AIRPLANES_FEED_BRANCH="stable" ;;
                dev) AIRPLANES_FEED_BRANCH="dev" ;;
                *)
                    echo "ERROR: $_release_channel_file contains '$_release_channel' (expected one of: stable, dev, main)" >&2
                    exit 1
                    ;;
            esac
            unset _release_channel
        fi
        unset _release_channel_file
    fi
    AIRPLANES_FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-stable}"

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
        [[ -x "$(airplanes_path /usr/bin/airplanes-feeder)" && ( -f "$FEED_ENV" || -f "$BOOT_CONFIG" ) ]] \
            || [[ -f "$(airplanes_path /etc/airplanes/image-install)" && -f "$FEED_ENV" ]]
    }

    airplanes_image_feed_bin_default() {
        local legacy
        legacy="$(airplanes_path /usr/bin/airplanes-feeder)"
        if [[ -x "$legacy" ]]; then
            printf '%s' "$legacy"
        else
            printf '%s' "$(airplanes_path /usr/local/share/airplanes/feed-airplanes)"
        fi
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

# Resolve the "stable" channel sentinel into a concrete tag now that git is
# guaranteed installed. No-op if AIRPLANES_FEED_BRANCH is already a concrete
# ref (an explicit env override, "dev", or a tag the caller supplied).
airplanes_resolve_feed_branch

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
    # Atomic rename via same-dir tempfile so we don't overwrite the file
    # currently being interpreted, and 0755 is set explicitly (downstream
    # callers exec this path directly).
    update_tmp="$(mktemp "$IPATH/update.sh.XXXXXX")"
    install -m 0755 "$GIT/update.sh" "$update_tmp"
    mv -fT "$update_tmp" "$IPATH/update.sh"
    bash "$IPATH/update.sh" "$@"
    exit $?
fi
if [[ "$IMAGE_SERVICE_LAYOUT" == "1" ]]; then
    # Images ship these units in /etc/systemd/system, which overrides /lib.
    SYSTEMD_DIR="$(airplanes_path /etc/systemd/system)"
fi

# Migration helpers: legacy retirements, env-file rewrites, manifest-based
# pruning, finalize symlinks. See scripts/lib/update-migrations.sh for the
# function definitions and the migration ordering contract.
# shellcheck source=scripts/lib/update-migrations.sh
source "$GIT/scripts/lib/update-migrations.sh"

# Pre-config retirements run before the config-incomplete setup.sh dispatch
# below: an operator with a stale legacy unit but missing config still gets
# it cleaned up.
run_pre_config_legacy_retirements

# shellcheck source=scripts/lib/systemd-helpers.sh
source "$GIT/scripts/lib/systemd-helpers.sh"
# shellcheck source=scripts/lib/claim-registration.sh
source "$GIT/scripts/lib/claim-registration.sh"
# shellcheck source=scripts/lib/service-account.sh
source "$GIT/scripts/lib/service-account.sh"
# shellcheck source=scripts/lib/update-builds.sh
source "$GIT/scripts/lib/update-builds.sh"

if [[ "$IMAGE_INSTALL" == "1" ]]; then
    # Unset USER before sourcing so a process-environment $USER (e.g. the
    # systemd User= or the login shell) can't bleed into the legacy-USER
    # detection below. Same precaution applies in the manual-install branch.
    unset USER MLAT_USER MLAT_ENABLED
    if [[ -f "$FEED_ENV" ]]; then
        # Migrate legacy USER if present before sourcing so the shell sees
        # the new schema directly. No-op when feed.env was written by a
        # post-split writer (configure.sh, image first-run, new webconfig).
        migrate_user_to_mlat_split "$FEED_ENV"
        source "$FEED_ENV"
    else
        source "$BOOT_CONFIG"
        [[ -f "$BOOT_ENV" ]] && source "$BOOT_ENV"
    fi

    # Legacy-boot-config feeders may carry USER= in airplanes-config.txt /
    # airplanes-env. Derive the new schema in-shell so the completeness
    # check below sees MLAT_USER/MLAT_ENABLED. The boot config itself is
    # left alone (it's the user's edit surface and must keep working as-is
    # for users who hand-edit it).
    if [[ ! -v MLAT_USER && ! -v MLAT_ENABLED && -v USER ]]; then
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

    LATITUDE="${LATITUDE:-0}"
    LONGITUDE="${LONGITUDE:-0}"
    ALTITUDE="${ALTITUDE:-0}"
    INPUT="${INPUT:-127.0.0.1:30005}"
    INPUT_TYPE="${INPUT_TYPE:-dump1090}"
    REDUCE_INTERVAL="${REDUCE_INTERVAL:-0.5}"
    MLATSERVER="${MLATSERVER:-feed.airplanes.live:31090}"
    TARGET="${TARGET:-$(airplanes_image_target_default)}"
    JSON_OPTIONS="${JSON_OPTIONS:-"--json-location-accuracy 2"}"
    MLAT_USER="${MLAT_USER-}"
    MLAT_ENABLED="${MLAT_ENABLED:-true}"
else
    prepare_legacy_feed_env_migration "$LEGACY_FEED_ENV" "$FEED_ENV" "$ETC_AIRPLANES"
    run_config_file_migrations "$FEED_ENV"

    unset USER MLAT_USER MLAT_ENABLED
    if [[ -f "$FEED_ENV" ]]; then
        source "$FEED_ENV"
        migrate_add_uat_input_default "$FEED_ENV"
    elif [[ -f "$BOOT_ENV" ]]; then
        source "$BOOT_ENV"
    fi
    MLAT_USER="${MLAT_USER-}"
    MLAT_ENABLED="${MLAT_ENABLED:-true}"
fi
if [[ -z $INPUT ]] || [[ -z $INPUT_TYPE ]] \
    || [[ -z $LATITUDE ]] || [[ -z $LONGITUDE ]] || [[ -z $ALTITUDE ]] \
    || [[ -z $MLATSERVER ]] || [[ -z $TARGET ]] \
    || { [[ "$MLAT_ENABLED" == "true" ]] && [[ -z $MLAT_USER ]]; } \
    || { [[ "$IMAGE_INSTALL" != "1" ]] && [[ -z $NET_OPTIONS ]]; }; then
    if [[ "$IMAGE_INSTALL" == "1" ]]; then
        echo "Image configuration is incomplete; refusing to run interactive setup on an image." >&2
        exit 1
    fi
    bash "$GIT/setup.sh"
    exit 0
fi

if [[ "$LATITUDE" == 0 ]] || [[ "$LONGITUDE" == 0 ]] || [[ "$MLAT_ENABLED" != "true" ]]; then
    MLAT_DISABLED=1
else
    MLAT_DISABLED=0
fi

cp "$GIT/uninstall.sh" "$IPATH"
cp "$GIT"/scripts/*.sh "$IPATH"
install -d -m 0755 "$IPATH/apl-feed"
install -m 0644 "$GIT"/scripts/apl-feed/*.sh "$IPATH/apl-feed"
install -d -m 0755 "$IPATH/lib"
# Runtime libs: sourced at runtime by daemons (state-writer) and CLI tools
# like apl-feed status (state-reader). Distinct from update-time-only libs
# (install-update-common.sh, update-migrations.sh, update-builds.sh, etc.)
# which are sourced ONLY by update.sh from $GIT/scripts/lib/ at update time
# and are NOT installed at $IPATH; copy selectively rather than wildcard.
install -m 0644 "$GIT"/scripts/lib/state-writer.sh "$IPATH/lib"
install -m 0644 "$GIT"/scripts/lib/state-reader.sh "$IPATH/lib"

# Historical-ship manifests for the wildcard cp/install above. Each entry is
# a script we have ever shipped to $IPATH (top-level) or $IPATH/apl-feed/.
# The prune loops below remove any installed file whose source counterpart
# is gone from the current $GIT/scripts tree — symmetric to the wildcard
# cp/install which only ADD files, never remove them.
#
# Maintenance rule: NEVER remove an entry from these arrays. Add a new
# entry whenever a new script ships from scripts/ or scripts/apl-feed/.
# Removing an entry would leak the stale file on already-upgraded feeders.
# CI guards both directions: presence of every currently-shipped name, and
# retention of known-historical names.
historical_top_level_scripts=(
    airplanes-feed.sh
    airplanes-mlat.sh
    apl-feed.sh
    second-mlat.sh
)
historical_apl_feed_modules=(
    backup.sh
    claim.sh
    common.sh
    http.sh
    id.sh
    mlat.sh
    status.sh
)
historical_daemon_libs=(
    state-reader.sh
    state-writer.sh
)

prune_installed_script_artifacts "$IPATH" "$GIT/scripts" historical_top_level_scripts
if [[ -d "$IPATH/apl-feed" ]]; then
    prune_installed_script_artifacts "$IPATH/apl-feed" "$GIT/scripts/apl-feed" historical_apl_feed_modules
fi
if [[ -d "$IPATH/lib" ]]; then
    prune_installed_script_artifacts "$IPATH/lib" "$GIT/scripts/lib" historical_daemon_libs
fi
mkdir -p "$LOCAL_BIN"
install -m 0755 "$GIT/scripts/apl-feed.sh" "$LOCAL_BIN/apl-feed"

# Daemon user/group. Renamed from "airplanes" to avoid collision with what
# users typically pick as their console/SSH login on a fresh image flash.
# Existing installs keep their orphan "airplanes" user in /etc/passwd;
# deleting it would risk breaking unknown local references (custom drop-ins,
# an airplanes-mlat2.service generated by the now-removed legacy
# second-mlat.sh that still pins User=airplanes, etc.).
#
# A private airplanes-feed group is created so other service accounts can
# read claim-state files (mode 0640) without escalating to root. Membership
# in this group grants read access to /etc/airplanes/feeder-claim-secret;
# only add service accounts that legitimately need to reveal claim secrets.
#
# See scripts/lib/service-account.sh for the create/repair logic and the
# heal_claim_state_ownership chown step.
ensure_airplanes_feed_account airplanes-feed airplanes-feed "$IPATH" "$ETC_AIRPLANES"

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
MLAT_GIT="$IPATH/mlat-client-git"

install_mlat_client \
    "$MLAT_REPO" \
    "$MLAT_BRANCH" \
    "$VENV" \
    "$IPATH" \
    "$MLAT_GIT" \
    "$LOGFILE" \
    "$REINSTALL" \
    "$MLAT_DISABLED"

echo 50

# copy airplanes-feed and airplanes-mlat service files
mkdir -p "$SYSTEMD_DIR"
cp "$GIT"/scripts/airplanes-mlat.service "$SYSTEMD_DIR"
cp "$GIT"/scripts/airplanes-feed.service "$SYSTEMD_DIR"
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
    # The daemon classifies disabled-by-config and self-disables via
    # sleep+exit; systemd Restart=always re-runs it. This keeps the
    # daemon-owned state-file pattern coherent: apl-feed status and the
    # dashboards trust the daemon's published /run/airplanes-mlat/state
    # rather than re-deriving the predicate from feed.env.
    systemctl enable airplanes-mlat >> "$LOGFILE" || true
    systemctl restart airplanes-mlat || true
fi

echo 70

# SETUP FEEDER TO SEND DUMP1090 DATA TO airplanes.live

if [[ "$IMAGE_INSTALL" == "1" ]]; then
    READSB_BIN="$(airplanes_image_feed_bin_default)"
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
    READSB_GIT="$IPATH/readsb-git"
    READSB_BIN="$IPATH/feed-airplanes"

    build_readsb_feed_client \
        "$READSB_REPO" \
        "$READSB_BRANCH" \
        "$READSB_GIT" \
        "$READSB_BIN" \
        "$IPATH" \
        "$LOGFILE" \
        "$REINSTALL"
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

RC_LOCAL="$(airplanes_path /etc/rc.local)"
MLAT_CLIENT_DEFAULT="$(airplanes_path /etc/default/mlat-client)"
run_post_update_legacy_cleanup "$RC_LOCAL" "$MLAT_CLIENT_DEFAULT" "$LOGFILE"

if [[ "$IMAGE_INSTALL" != "1" ]]; then
    finalize_legacy_feed_env_migration "$LEGACY_FEED_ENV" "$FEED_ENV"
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

Want a local web map? Install wiedehopf/tar1090 directly:
https://github.com/wiedehopf/tar1090
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
    # Persistent on-disk signal that this filesystem was produced via
    # --build-mode. Runtime scripts use this to detect image installs that
    # don't ship the legacy /usr/bin/airplanes-feeder binary.
    mkdir -p "$ETC_AIRPLANES"
    : > "$ETC_AIRPLANES/image-install"
    echo "Build mode setup complete; skipping receiver connectivity probe."
elif command -v nc &>/dev/null && command -v timeout &>/dev/null && ! timeout 5 nc -z "$INPUT_IP" "$INPUT_PORT"; then
    #whiptail --title "airplanes.live Setup Script" --msgbox "$ENDTEXT2" 24 73
    echo -e "$ENDTEXT2"
else
    # Display the thank you message box.
    #whiptail --title "airplanes.live Setup Script" --msgbox "$ENDTEXT" 24 73
    echo -e "$ENDTEXT"
fi
