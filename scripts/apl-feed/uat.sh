#!/usr/bin/env bash

# 978 UAT enable/disable management. Operator-facing alternative to editing
# /etc/airplanes/feed.env by hand for users not on the new feeder image
# (image users have the same surface in webconfig).
#
# Like mlat.sh, every public function constructs a sparse update payload
# and routes it through apl_feed_apply. The library locks
# /run/airplanes/feed-env.lock, validates UAT_INPUT / DUMP978_*, atomically
# rewrites feed.env, and restarts airplanes-feed / airplanes-978 /
# dump978-fa as appropriate.
#
# UAT is opt-in: an empty UAT_INPUT means "no 978 connector wired at all".
# Enable writes UAT_INPUT="127.0.0.1:30978" (the well-known local
# dump978-fa endpoint, the only value accepted by airplanes-978.sh and
# webconfig's validator) and optionally pins DUMP978_SDR_SERIAL /
# DUMP978_GAIN — both wrapper fallbacks (978 / 42.1) are sensible
# defaults that get used when the keys are absent.

DEFAULT_DUMP978_SDR_SERIAL="978"
DEFAULT_DUMP978_GAIN="42.1"
LOCAL_UAT_ENDPOINT="127.0.0.1:30978"

# Image-only systemd units. On a standalone-feed install these are
# either absent or — name collision — belong to a third-party package
# (dump978-fa is also FlightAware's unit name); the apply library's
# unit-ownership gate skips both cases silently. status inspection
# still uses these helpers.
_UAT_OPTIONAL_UNITS=(dump978-fa.service airplanes-978.service)

_uat_unit_exists() {
    local unit="$1"
    systemctl cat "$unit" >/dev/null 2>&1
}

_uat_check_universal() {
    local key="$1" value="$2"
    if [[ "$value" =~ [\"\\\$\`\;\&\|\<\>\#\'$'\n'$'\r'] ]]; then
        die "$key contains a forbidden shell metacharacter"
    fi
}

_uat_validate_serial() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    valid_dump978_serial "$v" || die "DUMP978_SDR_SERIAL must match [0-9A-Za-z_-]{1,32}; reject \"$v\""
    _uat_check_universal DUMP978_SDR_SERIAL "$v"
}

_uat_validate_gain() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    valid_dump978_gain "$v" || die "DUMP978_GAIN must be a number in [0, 60]; reject \"$v\""
}

_uat_probe_serial() {
    local serial="$1"
    [[ -n "$serial" ]] || return 1
    # APL_FEED_UAT_USB_SERIAL_GLOB overrides the /sys path for tests; default
    # matches what dump978-fa-wrapper probes on the real device.
    local glob="${APL_FEED_UAT_USB_SERIAL_GLOB:-/sys/bus/usb/devices/*/serial}"
    local sys
    for sys in $glob; do
        [[ -r "$sys" ]] || continue
        # /sys serial files have no trailing newline, so `read` would
        # return non-zero on EOF. tr-strip is unconditional and robust.
        local s
        s="$(tr -d '\n\r' < "$sys")"
        [[ "$s" == "$serial" ]] && return 0
    done
    return 1
}

_uat_emit_result() {
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

_uat_apply() {
    feed_env_ensure_canonical_for_write
    local -a args=()
    args+=(--feed-env "$(feed_env_write_path)")
    args+=(--lock-file "$(feed_env_lock_path)")
    if [[ "$ROOT" != "/" ]]; then
        args+=(--no-restart --no-audit)
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
    fi
    UAT_APPLY_RC=0
    apl_feed_apply "${args[@]}" "$@" || UAT_APPLY_RC=$?
}

apl_feed_uat_enable() {
    local serial="" gain=""
    local serial_set=0 gain_set=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_uat_enable; exit 0 ;;
            --serial)
                [[ $# -ge 2 ]] || die "--serial requires VALUE"
                serial="$2"; serial_set=1; shift 2 ;;
            --gain)
                [[ $# -ge 2 ]] || die "--gain requires VALUE"
                gain="$2"; gain_set=1; shift 2 ;;
            *)
                local opt_rc
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for 978 enable: $1" ;;
                esac
                ;;
        esac
    done

    (( serial_set )) && _uat_validate_serial "$serial"
    (( gain_set )) && _uat_validate_gain "$gain"

    local -a pairs=(UAT_INPUT="$LOCAL_UAT_ENDPOINT")
    (( serial_set )) && pairs+=(DUMP978_SDR_SERIAL="$serial")
    (( gain_set )) && pairs+=(DUMP978_GAIN="$gain")

    _uat_apply "${pairs[@]}"
    local result_msg="UAT_INPUT set to \"$LOCAL_UAT_ENDPOINT\""
    (( serial_set )) && result_msg+=$'\n'"DUMP978_SDR_SERIAL set to \"$serial\""
    (( gain_set )) && result_msg+=$'\n'"DUMP978_GAIN set to \"$gain\""
    _uat_emit_result "$result_msg"
}

apl_feed_uat_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in -h|--help) usage_uat_disable; exit 0 ;; esac
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for 978 disable: $1" ;;
        esac
    done

    _uat_apply UAT_INPUT=
    _uat_emit_result "UAT_INPUT cleared (978 disabled)"
}

apl_feed_uat_setup() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in -h|--help) usage_uat_setup; exit 0 ;; esac
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for 978 setup: $1" ;;
        esac
    done

    if [[ ! -t 0 ]]; then
        die "978 setup is interactive; pipe answers via apl-feed 978 enable [--serial S] [--gain G] for non-interactive use"
    fi

    echo
    echo "Configure 978 UAT reception."
    echo "  978 needs a second RTL-SDR dongle with its EEPROM serial set to a known string."
    echo "  Convention: flash the dongle's serial with: sudo rtl_eeprom -s 00000978"
    echo
    local reply
    read -r -p "Do you have a 978 SDR plugged in? [y/N] " reply
    case "${reply,,}" in
        y|yes) ;;
        *)
            echo "Aborted — re-run \`apl-feed 978 setup\` after plugging in the dongle."
            return 0
            ;;
    esac

    local serial gain
    read -r -p "SDR serial [$DEFAULT_DUMP978_SDR_SERIAL]: " serial
    serial="${serial:-$DEFAULT_DUMP978_SDR_SERIAL}"
    _uat_validate_serial "$serial"

    read -r -p "Gain (dB) [$DEFAULT_DUMP978_GAIN]: " gain
    gain="${gain:-$DEFAULT_DUMP978_GAIN}"
    _uat_validate_gain "$gain"

    if _uat_probe_serial "$serial"; then
        echo "Probe: found a USB device with serial=\"$serial\". Proceeding."
    else
        echo "WARNING: no USB device with serial=\"$serial\" detected." >&2
        echo "         The 978 service will self-disable as no_hardware until the dongle is plugged in." >&2
    fi

    apl_feed_uat_enable --serial "$serial" --gain "$gain"
}

apl_feed_uat_status() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in -h|--help) usage_uat_status; exit 0 ;; esac
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for 978 status: $1" ;;
        esac
    done

    local uat serial gain
    uat="$(feed_env_get UAT_INPUT 2>/dev/null || true)"
    serial="$(feed_env_get DUMP978_SDR_SERIAL 2>/dev/null || true)"
    gain="$(feed_env_get DUMP978_GAIN 2>/dev/null || true)"

    if [[ -z "$uat" ]]; then
        echo "978: disabled (UAT_INPUT is empty in feed.env)"
    else
        echo "978: enabled (UAT_INPUT=$uat)"
    fi
    echo "  DUMP978_SDR_SERIAL: ${serial:-<default 978>}"
    echo "  DUMP978_GAIN:       ${gain:-<default 42.1>}"

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    echo
    local unit
    for unit in "${_UAT_OPTIONAL_UNITS[@]}"; do
        if _apl_feed_apply_unit_is_ours "$unit"; then
            local active
            active="$(systemctl is-active "$unit" 2>/dev/null || true)"
            printf '  %-26s %s\n' "$unit" "${active:-unknown}"
        elif _uat_unit_exists "$unit"; then
            # Name collision: the unit exists but belongs to a third-party
            # package (e.g. FlightAware's dump978-fa). Its systemd state
            # says nothing about our 978 chain — don't present it as ours.
            printf '  %-26s %s\n' "$unit" "owned by another package (not managed)"
        else
            printf '  %-26s %s\n' "$unit" "not installed (image-only)"
        fi
    done
}

usage_uat() {
    cat <<'USAGE'
Usage: apl-feed 978 <subcommand> [options]

Subcommands:
  enable [--serial S] [--gain G]   Enable 978 MHz UAT reception
  disable                          Disable 978 UAT
  setup                            Interactive 978 configuration
  status                           Show 978 UAT configuration and services

Run 'apl-feed 978 <subcommand> --help' for details.
USAGE
}

usage_uat_enable() {
    cat <<'USAGE'
Usage: apl-feed 978 enable [--serial SERIAL] [--gain GAIN]

Enables 978 MHz UAT reception (points UAT_INPUT at the local dump978-fa
endpoint). --serial pins the 978 SDR's EEPROM serial; --gain pins the
dump978 gain. Omitting either leaves any stored value unchanged; the
dump978 wrapper applies its built-in defaults when the value is unset.
USAGE
}

usage_uat_disable() {
    cat <<'USAGE'
Usage: apl-feed 978 disable

Disables 978 UAT reception by clearing UAT_INPUT.
USAGE
}

usage_uat_setup() {
    cat <<'USAGE'
Usage: apl-feed 978 setup

Interactive prompt for the 978 SDR serial and gain, then enables 978.
Requires a TTY; for non-interactive use run
'apl-feed 978 enable [--serial S] [--gain G]'.
USAGE
}

usage_uat_status() {
    cat <<'USAGE'
Usage: apl-feed 978 status

Shows whether 978 UAT is enabled, the configured SDR serial and gain, and
the state of the dump978-fa / airplanes-978 services.
USAGE
}

dispatch_uat() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || usage_error usage_uat
    if [[ "$sub" == "-h" || "$sub" == "--help" ]]; then
        usage_uat
        return 0
    fi
    shift || true
    case "$sub" in
        enable)  apl_feed_uat_enable  "$@" ;;
        disable) apl_feed_uat_disable "$@" ;;
        setup)   apl_feed_uat_setup   "$@" ;;
        status)  apl_feed_uat_status  "$@" ;;
        *) usage_error usage_uat "unknown 978 subcommand: $sub" ;;
    esac
}
