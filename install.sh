#!/bin/bash
set -e

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

    airplanes_install_bootstrap_deps() {
        if ! command -v git &>/dev/null || ! command -v wget &>/dev/null || ! command -v unzip &>/dev/null || ! command -v whiptail &>/dev/null || ! command -v awk &>/dev/null; then
            apt-get update || true
            apt-get install -y --no-install-recommends --no-install-suggests git wget unzip whiptail mawk || true
        fi
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
            if mv -fT "$tmp.folder/$(ls "$tmp.folder")" "$target"; then
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

airplanes_init_paths
airplanes_require_root
mkdir -p "$IPATH"
airplanes_install_bootstrap_deps
getGIT "$AIRPLANES_FEED_REPO" "$AIRPLANES_FEED_BRANCH" "$GIT"

cd "$GIT"
bash "$GIT/setup.sh"
