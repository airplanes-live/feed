#!/usr/bin/env bash

# Diagnostics push enable/disable. Operator-facing alternative to editing
# REPORT_STATUS in /etc/airplanes/feed.env by hand. The on-device webconfig
# UI writes through the same canonical path (apl_feed_apply), so this CLI
# and the webconfig stay byte-identical on disk.
#
# Each public function constructs a sparse update payload and routes it
# through apl_feed_apply (scripts/lib/feed-env-apply.sh) — the single
# privileged writer. The library locks /run/airplanes/feed-env.lock,
# validates per-key, and atomically rewrites feed.env. REPORT_STATUS is
# registered as a no-restart key in feed-env-keys.sh; the airplanes-
# diagnostics.timer self-gates on the value at every tick, so flipping
# the toggle takes effect on the next push without restarting anything.

# Translate the library's APL_APPLY_* result globals into operator-facing
# output. Mirrors apl-feed/mlat.sh's _mlat_emit_result; kept separate so
# message phrasing can diverge from mlat's wording without churn.
_diagnostics_emit_result() {
    local success_msg="$1"
    case "$APL_APPLY_STATUS" in
        applied)
            echo "$success_msg"
            if (( ${#APL_APPLY_PENDING_RESTART[@]} > 0 )); then
                echo "Warning: failed to restart ${APL_APPLY_PENDING_RESTART[*]} — re-run: sudo systemctl restart ${APL_APPLY_PENDING_RESTART[*]}" >&2
            fi
            apl_feed_apply_emit_meta_warning
            return 0
            ;;
        no_change)
            return 0
            ;;
        rejected)
            local k
            for k in "${!APL_APPLY_ERRORS[@]}"; do
                echo "ERROR: $k: ${APL_APPLY_ERRORS[$k]}" >&2
            done
            return 1
            ;;
        lock_timeout)
            echo "ERROR: could not acquire feed.env lock: $APL_APPLY_ERROR_MESSAGE" >&2
            return 1
            ;;
        filesystem_error)
            echo "ERROR: $APL_APPLY_ERROR_MESSAGE" >&2
            return 1
            ;;
        *)
            echo "ERROR: ${APL_APPLY_ERROR_MESSAGE:-apply failed with status ${APL_APPLY_STATUS:-<unset>}}" >&2
            return 1
            ;;
    esac
}

# Wrap apl_feed_apply with the canonical CLI paths and the ROOT-based
# restart-skip decision. Same shape as _mlat_apply.
_diagnostics_apply() {
    feed_env_ensure_canonical_for_write
    local -a args=()
    args+=(--feed-env "$(feed_env_write_path)")
    args+=(--lock-file "$(feed_env_lock_path)")
    if [[ "$ROOT" != "/" ]]; then
        args+=(--no-restart --no-audit)
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
    fi
    DIAGNOSTICS_APPLY_RC=0
    apl_feed_apply "${args[@]}" "$@" || DIAGNOSTICS_APPLY_RC=$?
}

apl_feed_diagnostics_enable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for diagnostics enable: $1" ;;
        esac
    done

    _diagnostics_apply REPORT_STATUS=true
    _diagnostics_emit_result "REPORT_STATUS set to true (diagnostics push enabled; next tick within ~10 min)"
}

apl_feed_diagnostics_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for diagnostics disable: $1" ;;
        esac
    done

    _diagnostics_apply REPORT_STATUS=false
    _diagnostics_emit_result "REPORT_STATUS set to false (diagnostics push disabled; the next tick within ~10 min sends one final muted signal to airplanes.live, then the collector exits silently)"
}

dispatch_diagnostics() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "diagnostics requires a subcommand (enable|disable)"
    shift || true
    case "$sub" in
        enable)  apl_feed_diagnostics_enable  "$@" ;;
        disable) apl_feed_diagnostics_disable "$@" ;;
        -h|--help) usage ;;
        *) die "unknown diagnostics subcommand: $sub" ;;
    esac
}
