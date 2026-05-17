#!/usr/bin/env bash

# MLAT enable/disable + configuration. Operator-facing alternative to
# editing /etc/airplanes/feed.env by hand for users not on the new feeder
# image (image users have the same surface in webconfig).
#
# Every public function constructs a sparse update payload and routes it
# through apl_feed_apply (scripts/lib/feed-env-apply.sh) — the single
# privileged writer. The library locks /run/airplanes/feed-env.lock,
# validates per-key, atomically rewrites feed.env, and restarts the
# services in APL_FEED_KEY_RESTART for whichever keys actually changed.
# This module is now a thin facade: it parses CLI arguments, prompts the
# operator when interactive, and translates the library's structured
# result into human-friendly output.

# MLAT_USER strict shape — mirrors webconfig configspec.go's mlatUserRE.
# CLI rejects mismatched input rather than mangling it via sanitize_mlat_user
# (which silently rewrites disallowed characters to `_`).
_MLAT_USER_RE='^[A-Za-z0-9_-]{1,64}$'

# Translate the library's APL_APPLY_* result globals into operator-facing
# output. `success_msg` is printed on status=applied; status=no_change is a
# silent success; everything else writes a diagnostic to stderr and exits
# non-zero. Returns the appropriate exit code so the caller's `set -e`
# semantics propagate.
_mlat_emit_result() {
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
# restart-skip decision. Captures the library's exit code into MLAT_APPLY_RC
# rather than returning it directly — public callers run under `set -e` from
# apl-feed.sh, so a non-zero return here would exit before _mlat_emit_result
# can surface the structured error to the operator.
_mlat_apply() {
    feed_env_ensure_canonical_for_write
    local -a args=()
    args+=(--feed-env "$(feed_env_write_path)")
    args+=(--lock-file "$(feed_env_lock_path)")
    if [[ "$ROOT" != "/" ]]; then
        args+=(--no-restart --no-audit)
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
    fi
    MLAT_APPLY_RC=0
    apl_feed_apply "${args[@]}" "$@" || MLAT_APPLY_RC=$?
}

# Friendly pre-check for `apl-feed mlat enable`. The library enforces the
# same MLAT_ENABLED=true → geo-configured rule, but its per-field error
# fires after the lock + read; this gate is purely UX so the operator
# sees a clear "run mlat geo / mlat setup first" message before any
# write attempt.
_mlat_require_geo() {
    local feed_env="$1"
    local geo lat lon alt
    geo="$(feed_env_get GEO_CONFIGURED 2>/dev/null || true)"
    lat="$(feed_env_get LATITUDE 2>/dev/null || true)"
    lon="$(feed_env_get LONGITUDE 2>/dev/null || true)"
    alt="$(feed_env_get ALTITUDE 2>/dev/null || true)"
    if [[ "$geo" != "true" ]]; then
        die "location not configured (GEO_CONFIGURED=${geo:-<unset>}); run \`sudo apl-feed mlat setup\` or \`sudo apl-feed mlat geo <lat> <lon> <alt>\` first"
    fi
    [[ -n "$lat" ]] || die "LATITUDE is empty in $feed_env; run \`sudo apl-feed mlat geo <lat> <lon> <alt>\`"
    [[ -n "$lon" ]] || die "LONGITUDE is empty in $feed_env; run \`sudo apl-feed mlat geo <lat> <lon> <alt>\`"
    [[ -n "$alt" ]] || die "ALTITUDE is empty in $feed_env; run \`sudo apl-feed mlat geo <lat> <lon> <alt>\`"
}

apl_feed_mlat_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat disable: $1" ;;
        esac
    done

    _mlat_apply MLAT_ENABLED=false
    _mlat_emit_result "MLAT_ENABLED set to false (daemon will sleep while disabled)"
}

apl_feed_mlat_enable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat enable: $1" ;;
        esac
    done

    # Bootstrap canonical feed.env first so the geo-gate below reads
    # imported state on a bridged-legacy box rather than firing
    # "feed.env not found" or "GEO_CONFIGURED=<unset>" against the
    # never-canonicalised legacy file.
    feed_env_ensure_canonical_for_write

    local feed_env
    feed_env="$(feed_env_path)"
    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"
    _mlat_require_geo "$feed_env"

    _mlat_apply MLAT_ENABLED=true
    _mlat_emit_result "MLAT_ENABLED set to true"
}

apl_feed_mlat_private_enable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat private enable: $1" ;;
        esac
    done

    _mlat_apply MLAT_PRIVATE=true
    _mlat_emit_result "MLAT_PRIVATE set to true (feed name will be hidden on the public MLAT map)"
}

apl_feed_mlat_private_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat private disable: $1" ;;
        esac
    done

    _mlat_apply MLAT_PRIVATE=false
    _mlat_emit_result "MLAT_PRIVATE set to false (feed name will be shown on the public MLAT map)"
}

apl_feed_mlat_user() {
    local clear=0 name="" name_set=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clear)
                clear=1
                shift ;;
            *)
                local opt_rc
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0)
                        if (( name_set )); then
                            die "mlat user takes a single positional name; got extra arg: $1"
                        fi
                        name="$1"
                        name_set=1
                        shift ;;
                esac
                ;;
        esac
    done

    if (( clear )); then
        (( name_set )) && die "mlat user: --clear and a positional name are mutually exclusive"
    else
        (( name_set )) || die "mlat user: provide a name or use --clear"
        [[ "$name" =~ $_MLAT_USER_RE ]] || die "MLAT_USER must match [A-Za-z0-9_-]{1,64}; reject \"$name\""
    fi

    _mlat_apply MLAT_USER="$name"
    if (( clear )); then
        _mlat_emit_result "MLAT_USER cleared (daemon will use Anonymous-<short-feeder-id> when MLAT is enabled)"
    else
        _mlat_emit_result "MLAT_USER set to \"$name\""
    fi
}

apl_feed_mlat_geo() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -[0-9]*|-.[0-9]*)
                positional+=("$1"); shift ;;
            --|-h|--help|--root|--website-url|--max-retry-time)
                local opt_rc
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for mlat geo: $1" ;;
                esac
                ;;
            -*)
                die "unknown flag for mlat geo: $1" ;;
            *)
                positional+=("$1")
                shift ;;
        esac
    done

    (( ${#positional[@]} == 3 )) || die "mlat geo requires exactly three positional args: <lat> <lon> <alt>"
    local lat="${positional[0]}" lon="${positional[1]}" alt="${positional[2]}"

    valid_latitude  "$lat"  || die "LATITUDE must be a decimal number in [-90, 90]"
    valid_longitude "$lon"  || die "LONGITUDE must be a decimal number in [-180, 180]"
    valid_altitude  "$alt"  || die "ALTITUDE must match -?\\d+(\\.\\d+)?(m|ft)? in [-1000, 10000]"

    local norm_alt
    norm_alt="$(normalize_altitude "$alt")"

    # The library auto-derives GEO_CONFIGURED from (lat, lon) when neither
    # is explicitly set by the payload. Identical to configure.sh /
    # webconfig semantics: both axes numerically zero → false, anything
    # else → true.
    _mlat_apply LATITUDE="$lat" LONGITUDE="$lon" ALTITUDE="$norm_alt"
    _mlat_emit_result "LATITUDE=\"$lat\" LONGITUDE=\"$lon\" ALTITUDE=\"$norm_alt\""
}

# Interactive setup. Collects every input first (no partial writes if the
# operator Ctrl-Cs mid-prompt), validates each before any disk mutation,
# then commits the full new state via a single apl_feed_apply call. The
# library's lock-+-atomic-write guarantees no other writer can interleave
# with the seven-key transaction.
apl_feed_mlat_setup() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat setup: $1" ;;
        esac
    done

    if [[ ! -t 0 ]]; then
        die "mlat setup is interactive; for non-interactive use, run \`apl-feed mlat geo <lat> <lon> <alt>\` then \`apl-feed mlat user <name>\` (optional) then \`apl-feed mlat enable\`"
    fi

    if ! valid_latitude "0" >/dev/null 2>&1; then
        die "configure-validators.sh missing from \$APL_FEED_DAEMON_LIB_DIR; reinstall feed before running \`apl-feed mlat setup\`"
    fi

    # Bootstrap canonical feed.env from /boot/airplanes-config.txt on
    # bridged-legacy boxes before reading defaults — otherwise the
    # whiptail prompts pre-populate from the legacy schema (USER,
    # MLAT_MARKER) instead of the canonical one, silently dropping the
    # operator's existing name / privacy preference at the first ENTER.
    feed_env_ensure_canonical_for_write

    local feed_env
    feed_env="$(feed_env_path)"
    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"

    echo
    echo "Configure MLAT (multilateration) reception."
    echo "  MLAT needs your antenna position. The values you enter are used as"
    echo "  mlat-client's --lat/--lon/--alt. Real coordinates are required;"
    echo "  the Atlantic (0,0) placeholder will not be accepted."
    echo

    local lat lon alt name reply
    local current_lat current_lon current_alt current_user current_private
    current_lat="$(feed_env_get LATITUDE 2>/dev/null || true)"
    current_lon="$(feed_env_get LONGITUDE 2>/dev/null || true)"
    current_alt="$(feed_env_get ALTITUDE 2>/dev/null || true)"
    current_user="$(feed_env_get MLAT_USER 2>/dev/null || true)"
    current_private="$(feed_env_get MLAT_PRIVATE 2>/dev/null || true)"

    while :; do
        read -r -p "Latitude  (decimal, -90..90)${current_lat:+ [$current_lat]}: " lat
        lat="${lat:-$current_lat}"
        valid_latitude "$lat" && break
        echo "  Invalid; try again (e.g. 52.51666)." >&2
    done
    while :; do
        read -r -p "Longitude (decimal, -180..180)${current_lon:+ [$current_lon]}: " lon
        lon="${lon:-$current_lon}"
        valid_longitude "$lon" && break
        echo "  Invalid; try again (e.g. 13.37777)." >&2
    done
    # Refuse (0,0) explicitly; library would reject MLAT_ENABLED=true at
    # the consistency check, but flagging early gives a clearer reason.
    if awk -v LAT="$lat" -v LON="$lon" 'BEGIN { exit !(LAT + 0 == 0 && LON + 0 == 0) }'; then
        die "lat=$lat lon=$lon: refusing to enable MLAT at the Atlantic (0,0) placeholder"
    fi
    while :; do
        read -r -p "Altitude  (integer; m or ft suffix, e.g. 120m, 400ft)${current_alt:+ [$current_alt]}: " alt
        alt="${alt:-$current_alt}"
        valid_altitude "$alt" && break
        echo "  Invalid; try again (e.g. 120m or 400ft)." >&2
    done

    # MLAT name prompt. Blank input keeps the current value only when the
    # current value already passes the strict regex — otherwise the prompt
    # forces the operator to either supply a valid name or `-` to clear.
    local current_user_valid=0
    if [[ -z "$current_user" || "$current_user" =~ $_MLAT_USER_RE ]]; then
        current_user_valid=1
    fi
    while :; do
        local default_user_display
        if (( current_user_valid )); then
            default_user_display="${current_user:-<empty — daemon picks Anonymous-<short-feeder-id>>}"
        else
            default_user_display="<current \"$current_user\" is invalid; supply a new name or '-' to clear>"
        fi
        read -r -p "MLAT name (1-64 chars in [A-Za-z0-9_-], blank to keep current, '-' to clear) [$default_user_display]: " name
        if [[ -z "$name" ]]; then
            if (( current_user_valid )); then
                name="$current_user"
                break
            else
                echo "  Current MLAT_USER is invalid; please type a new name or '-' to clear." >&2
                continue
            fi
        elif [[ "$name" == "-" ]]; then
            name=""
            break
        elif [[ "$name" =~ $_MLAT_USER_RE ]]; then
            break
        else
            echo "  Invalid; try again (or blank to keep current, or '-' to clear)." >&2
        fi
    done

    local private="${current_private:-false}"
    case "$private" in
        true|false) ;;
        *) private="false" ;;
    esac
    local privacy_prompt_default privacy_prompt_yes_no
    if [[ "$private" == "true" ]]; then
        privacy_prompt_default="Y"
        privacy_prompt_yes_no="[Y/n]"
    else
        privacy_prompt_default="N"
        privacy_prompt_yes_no="[y/N]"
    fi
    read -r -p "Hide name on the public MLAT map? $privacy_prompt_yes_no " reply
    case "${reply,,}" in
        ""|"${privacy_prompt_default,,}") ;;
        y|yes) private="true" ;;
        n|no)  private="false" ;;
        *)
            echo "  Unrecognized answer; keeping MLAT_PRIVATE=$private." >&2
            ;;
    esac

    local norm_alt
    norm_alt="$(normalize_altitude "$alt")"

    echo
    echo "About to write:"
    echo "  LATITUDE=$lat"
    echo "  LONGITUDE=$lon"
    echo "  ALTITUDE=$norm_alt"
    echo "  GEO_CONFIGURED=true"
    echo "  MLAT_USER=\"$name\""
    echo "  MLAT_PRIVATE=$private"
    echo "  MLAT_ENABLED=true"
    read -r -p "Proceed? [Y/n] " reply
    case "${reply,,}" in
        ""|y|yes) ;;
        *) echo "Aborted — no changes written."; return 0 ;;
    esac

    _mlat_apply \
        LATITUDE="$lat" \
        LONGITUDE="$lon" \
        ALTITUDE="$norm_alt" \
        GEO_CONFIGURED=true \
        MLAT_USER="$name" \
        MLAT_PRIVATE="$private" \
        MLAT_ENABLED=true
    _mlat_emit_result "feed.env updated; MLAT enabled."
}

dispatch_mlat_private() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "mlat private requires a subcommand (enable|disable)"
    shift || true
    case "$sub" in
        enable)  apl_feed_mlat_private_enable  "$@" ;;
        disable) apl_feed_mlat_private_disable "$@" ;;
        -h|--help) usage ;;
        *) die "unknown mlat private subcommand: $sub" ;;
    esac
}

dispatch_mlat() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "mlat requires a subcommand (enable|disable|setup|user|geo|private)"
    shift || true
    case "$sub" in
        enable)  apl_feed_mlat_enable  "$@" ;;
        disable) apl_feed_mlat_disable "$@" ;;
        setup)   apl_feed_mlat_setup   "$@" ;;
        user)    apl_feed_mlat_user    "$@" ;;
        geo)     apl_feed_mlat_geo     "$@" ;;
        private) dispatch_mlat_private "$@" ;;
        -h|--help) usage ;;
        *) die "unknown mlat subcommand: $sub" ;;
    esac
}

# Status reporting lives in `apl-feed status`, which reads the daemon's
# runtime state file via scripts/lib/state-reader.sh.
