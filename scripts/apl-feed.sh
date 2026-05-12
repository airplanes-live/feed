#!/usr/bin/env bash
# apl-feed - feeder-side management CLI for airplanes.live.

set -euo pipefail

resolve_lib_dir() {
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/apl-feed" ]]; then
        printf '%s\n' "$script_dir/apl-feed"
    else
        printf '%s\n' '/usr/local/share/airplanes/apl-feed'
    fi
}

APL_FEED_LIB_DIR="${APL_FEED_LIB_DIR:-$(resolve_lib_dir)}"

# Resolve the daemon-lib directory ($IPATH/lib in production, ../lib in the
# repo checkout) so apl-feed can source pure-function libs like
# configure-validators.sh that ship alongside the daemons.
resolve_daemon_lib_dir() {
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/lib" ]]; then
        printf '%s\n' "$script_dir/lib"
    else
        printf '%s\n' '/usr/local/share/airplanes/lib'
    fi
}
APL_FEED_DAEMON_LIB_DIR="${APL_FEED_DAEMON_LIB_DIR:-$(resolve_daemon_lib_dir)}"

# Pure-function validators shared with configure.sh. Sourced defensively
# (mirrors apl-feed/status.sh's state-reader fallback) so a partial install
# missing the lib produces a clear error at first use rather than failing
# every CLI invocation.
if [[ -r "$APL_FEED_DAEMON_LIB_DIR/configure-validators.sh" ]]; then
    # shellcheck source=scripts/lib/configure-validators.sh
    source "$APL_FEED_DAEMON_LIB_DIR/configure-validators.sh"
else
    valid_latitude()     { echo "configure-validators.sh missing at $APL_FEED_DAEMON_LIB_DIR; reinstall feed" >&2; return 2; }
    valid_longitude()    { valid_latitude "$@"; }
    valid_altitude()     { valid_latitude "$@"; }
    normalize_altitude() { valid_latitude "$@"; }
    sanitize_mlat_user() { valid_latitude "$@"; }
fi

# shellcheck source=scripts/apl-feed/common.sh
source "$APL_FEED_LIB_DIR/common.sh"
# shellcheck source=scripts/apl-feed/http.sh
source "$APL_FEED_LIB_DIR/http.sh"
# shellcheck source=scripts/apl-feed/claim.sh
source "$APL_FEED_LIB_DIR/claim.sh"
# shellcheck source=scripts/apl-feed/id.sh
source "$APL_FEED_LIB_DIR/id.sh"
# shellcheck source=scripts/apl-feed/status.sh
source "$APL_FEED_LIB_DIR/status.sh"
# shellcheck source=scripts/apl-feed/backup.sh
source "$APL_FEED_LIB_DIR/backup.sh"
# shellcheck source=scripts/apl-feed/mlat.sh
source "$APL_FEED_LIB_DIR/mlat.sh"
# shellcheck source=scripts/apl-feed/uat.sh
source "$APL_FEED_LIB_DIR/uat.sh"

main() {
    local cmd="${1:-}"
    case "$cmd" in
        status)
            shift
            feed_status "$@"
            ;;
        claim)
            shift
            dispatch_claim "$@"
            ;;
        id)
            shift
            dispatch_id "$@"
            ;;
        backup)
            shift
            config_backup "$@"
            ;;
        restore)
            shift
            config_restore "$@"
            ;;
        mlat)
            shift
            dispatch_mlat "$@"
            ;;
        978)
            shift
            dispatch_uat "$@"
            ;;
        -h|--help|'')
            usage
            ;;
        *)
            die "unknown command: $cmd"
            ;;
    esac
}

main "$@"
