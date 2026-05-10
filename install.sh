#!/bin/bash
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/scripts/lib/install-update-common.sh" ]]; then
    # shellcheck source=scripts/lib/install-update-common.sh
    source "$SCRIPT_DIR/scripts/lib/install-update-common.sh"
else
    AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"
    AIRPLANES_FEED_REPO="${AIRPLANES_FEED_REPO:-https://github.com/airplanes-live/feed.git}"

    # The next line carries the release-CI template marker. CI replaces
    # ONLY THE FIRST occurrence of the marker string in this file (via
    # str.replace count=1), so this assignment is the substitution target.
    # The unrendered sentinel below is split across shell concatenation
    # so the substitution doesn't match it and the post-render comparison
    # stays meaningful. See docs/RELEASE_CHECKLIST.md.
    #
    # An explicit AIRPLANES_FEED_BRANCH env var still wins (image-build use,
    # operator overrides). Source-clone use sources install-update-common.sh,
    # which defines airplanes_resolve_feed_branch for stable-channel tag
    # resolution; the inline fallback doesn't do channel resolution and
    # provides a no-op stub so call sites work uniformly.
    AIRPLANES_RELEASE_REF='__FEED_REF__'
    _airplanes_unrendered_marker='__''FEED_REF__'
    if [[ "$AIRPLANES_RELEASE_REF" == "$_airplanes_unrendered_marker" ]]; then
        AIRPLANES_RELEASE_REF=""
    fi
    unset _airplanes_unrendered_marker
    AIRPLANES_FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-${AIRPLANES_RELEASE_REF:-main}}"
    unset AIRPLANES_RELEASE_REF

    airplanes_resolve_feed_branch() { :; }

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

airplanes_init_paths
airplanes_require_root
mkdir -p "$IPATH"
airplanes_install_bootstrap_deps

# Resolve the "stable" channel sentinel into a concrete tag now that git is
# available. No-op in inline-fallback mode (the stub returns immediately) and
# no-op in lib-sourced mode when AIRPLANES_FEED_BRANCH is already concrete.
airplanes_resolve_feed_branch

getGIT "$AIRPLANES_FEED_REPO" "$AIRPLANES_FEED_BRANCH" "$GIT"

cd "$GIT"
bash "$GIT/setup.sh" "$@"
