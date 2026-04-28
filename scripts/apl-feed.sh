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

# shellcheck source=scripts/apl-feed/common.sh
source "$APL_FEED_LIB_DIR/common.sh"
# shellcheck source=scripts/apl-feed/http.sh
source "$APL_FEED_LIB_DIR/http.sh"
# shellcheck source=scripts/apl-feed/claim.sh
source "$APL_FEED_LIB_DIR/claim.sh"
# shellcheck source=scripts/apl-feed/status.sh
source "$APL_FEED_LIB_DIR/status.sh"
# shellcheck source=scripts/apl-feed/backup.sh
source "$APL_FEED_LIB_DIR/backup.sh"

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
        backup)
            shift
            config_backup "$@"
            ;;
        restore)
            shift
            config_restore "$@"
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
