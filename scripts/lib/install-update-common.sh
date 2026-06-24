#!/usr/bin/env bash
# Shared helpers for the installer and updater. The scripts are still usable
# when downloaded standalone; install.sh and update.sh keep a small fallback for
# that bootstrap case.

AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"
AIRPLANES_FEED_REPO="${AIRPLANES_FEED_REPO:-https://github.com/airplanes-live/feed.git}"

# Resolve the latest semver-strict release tag from the feed remote.
# Strict format: vMAJOR.MINOR.PATCH with no leading zeroes, no prereleases.
# Echoes the tag name on success.
# Returns 0 = found, 1 = lookup OK but no matching tags, 2 = lookup itself failed.
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

# Resolve AIRPLANES_FEED_BRANCH from the channel sentinel "stable" to the
# actual latest tag. No-op if AIRPLANES_FEED_BRANCH is already a concrete
# ref (a tag name, branch, or SHA). Aborts loudly with distinct messages
# for "lookup failed" (network/DNS/TLS) versus "no matching tags exist".
#
# Must be called AFTER bootstrap deps (git) are installed — the resolver
# uses git ls-remote.
airplanes_resolve_feed_branch() {
    if [[ "${AIRPLANES_FEED_BRANCH:-}" != "stable" ]]; then
        return 0
    fi
    local resolved rc=0
    resolved="$(airplanes_resolve_latest_stable_tag "$AIRPLANES_FEED_REPO")" || rc=$?
    case $rc in
        0)
            # Export so the resolved tag survives update.sh's self-replace
            # re-exec. Without this, a default-stable install re-resolves on
            # every self-replace and could install a different tag if a new
            # release lands mid-update (or thrash on a transient ls-remote
            # failure between invocations).
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
# /etc/airplanes/release-channel. Allowlist: stable, dev, main. Manual
# installs without the file default to the stable channel.
#
# 'main' is accepted as a legacy alias for 'stable'. Pre-stable-release
# images may have written 'main' to the file before this script learned
# about stable-tag resolution; treating it as an alias keeps those
# images updatable without forcing a re-flash.
#
# For the stable channel, AIRPLANES_FEED_BRANCH is set to the literal
# string "stable" as a sentinel. The actual tag is resolved later by
# airplanes_resolve_feed_branch (which calls git ls-remote, so it must
# be invoked AFTER bootstrap deps install). This keeps the source-time
# block cheap and lets curl-pipe-bash bootstrap reach deps install
# before any network resolution.
#
# An explicit AIRPLANES_FEED_BRANCH env var bypasses this entire
# mechanism so operators can pin to any ref for testing/recovery.
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
    PREFIX="$(airplanes_path /opt/airplanes/current)"
    IPATH="$PREFIX/share/airplanes"
    BIN="$PREFIX/bin"
    STATE="$(airplanes_path /var/lib/airplanes/runtime)"
    GIT="$STATE/git"
    LOGFILE="$STATE/lastlog"
    BOOT_CONFIG="$(airplanes_path /boot/airplanes-config.txt)"
    BOOT_ENV="$(airplanes_path /boot/airplanes-env)"
    ETC_AIRPLANES="$(airplanes_path /etc/airplanes)"
    FEED_ENV="$ETC_AIRPLANES/feed.env"
    FEEDER_ID_FILE="$ETC_AIRPLANES/feeder-id"
    LEGACY_UUID_FILE="$STATE/airplanes-uuid"
    BOOT_UUID_FILE="$(airplanes_path /boot/airplanes-uuid)"
    LEGACY_FEED_ENV="$(airplanes_path /etc/default/airplanes)"
    LOCAL_BIN="$(airplanes_path /usr/local/bin)"
    SYSTEMD_DIR="$(airplanes_path /etc/systemd/system)"
}

# An image install is either the new overlay image (which lays the
# /etc/airplanes/image-install marker) or a legacy image (which ships the baked
# /usr/bin/airplanes-feeder binary but predates the marker). Detecting the
# legacy binary is a READ of a file the legacy rootfs already carries — it does
# not write into /usr/bin, so it does not conflict with the FHS de-squat. Both
# require a config source so a bare rootfs isn't mistaken for a configured image.
airplanes_is_image_install() {
    [[ -f "$(airplanes_path /etc/airplanes/image-install)" && ( -f "$FEED_ENV" || -f "$BOOT_CONFIG" ) ]] \
        || [[ -x "$(airplanes_path /usr/bin/airplanes-feeder)" && ( -f "$FEED_ENV" || -f "$BOOT_CONFIG" ) ]]
}

airplanes_image_feed_bin_default() {
    printf '%s' "$(airplanes_path /opt/airplanes/current/bin/feed-airplanes)"
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

# Returns 0 if the current rootfs is managed by the airplanes-live runtime
# overlay (atomic delivery of feed scripts, decoders, webconfig, mlat-client
# venv as a single signed payload), and 1 otherwise.
#
# Detection: presence of /etc/airplanes/runtime-manifest.json, which the
# overlay's install pipeline writes in both build mode (regular file copy of
# the active release manifest) and runtime mode (symlink to the current
# release's manifest.json). Both `-e` and `-L` cover the symlink form,
# including the brief mid-flip window when the link may dangle.
#
# Legacy images and manual installs do not carry this marker.
airplanes_is_overlay_managed_root() {
    local manifest
    manifest="$(airplanes_path /etc/airplanes/runtime-manifest.json)"
    [[ -e "$manifest" || -L "$manifest" ]]
}

# Aborts with EX_CONFIG (78) if the rootfs is overlay-managed, so feed's
# install.sh / update.sh cannot replace overlay-owned symlinks (apl-feed,
# airplanes-feed.sh, airplanes-mlat.sh, the readsb feed client, the mlat-
# client venv) with stale real files. Stomping those symlinks breaks the
# next overlay update.
#
# Bypasses:
#   - Build mode (AIRPLANES_BUILD_MODE=1). Image-build pipelines run feed's
#     install.sh --build-mode against a rootfs they own; the overlay stage
#     runs later in the same pipeline. Skipping the guard keeps build
#     orchestration clean.
#   - AIRPLANES_ALLOW_OVERLAY_BYPASS=1. Explicit recovery / development
#     override. Emits a stderr warning when it fires.
airplanes_guard_overlay_managed_root() {
    local script_name="${1:-this feed script}"
    if airplanes_is_build_mode; then
        return 0
    fi
    if [[ "${AIRPLANES_ALLOW_OVERLAY_BYPASS:-0}" == "1" ]]; then
        if airplanes_is_overlay_managed_root; then
            echo "WARNING: AIRPLANES_ALLOW_OVERLAY_BYPASS=1 - proceeding on an overlay-managed root" >&2
        fi
        return 0
    fi
    if ! airplanes_is_overlay_managed_root; then
        return 0
    fi
    local manifest
    manifest="$(airplanes_path /etc/airplanes/runtime-manifest.json)"
    cat >&2 <<MSG
ERROR: This system is managed by the airplanes-live runtime overlay
       ($manifest is present). The overlay delivers and updates feed
       scripts (apl-feed, airplanes-feed, airplanes-mlat, the readsb feed
       client, and the mlat-client venv) atomically as part of an overlay
       refresh.

       Running $script_name directly would replace overlay-owned files
       with stale copies and break the next overlay update.

       To update this feeder, use the web UI's "Update System" button
       (which invokes airplanes-update-orchestrator), or run that
       orchestrator manually if you have shell access.

       To override this guard for recovery or development, set
       AIRPLANES_ALLOW_OVERLAY_BYPASS=1.
MSG
    exit 78
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
