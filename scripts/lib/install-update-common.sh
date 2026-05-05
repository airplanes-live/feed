#!/usr/bin/env bash
# Shared helpers for the installer and updater. The scripts are still usable
# when downloaded standalone; install.sh and update.sh keep a small fallback for
# that bootstrap case.

AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"
AIRPLANES_FEED_REPO="${AIRPLANES_FEED_REPO:-https://github.com/airplanes-live/feed.git}"

# Image-built feeders pin their runtime-update branch to the channel they were
# built from via /etc/airplanes/release-channel. Without this, a dev-channel
# image falls back to feed/main on the first webconfig-triggered update and
# self-replaces update.sh with the older main version (sticky regression: the
# pin is never re-asserted because main's update.sh has no awareness of it).
# Manual installs without the file get the historical "main" default.
if [[ -z "${AIRPLANES_FEED_BRANCH:-}" ]]; then
    _release_channel_file="${AIRPLANES_ROOT%/}/etc/airplanes/release-channel"
    if [[ -r "$_release_channel_file" ]]; then
        AIRPLANES_FEED_BRANCH="$(head -n1 "$_release_channel_file" | tr -d '[:space:]')"
    fi
    unset _release_channel_file
fi
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

airplanes_install_bootstrap_deps() {
    if ! command -v git &>/dev/null || ! command -v wget &>/dev/null || ! command -v unzip &>/dev/null || ! command -v whiptail &>/dev/null || ! command -v awk &>/dev/null; then
        apt-get update || true
        apt-get install -y --no-install-recommends --no-install-suggests git wget unzip whiptail mawk || true
    fi
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
    # getGIT REPO BRANCH TARGET-DIR
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
