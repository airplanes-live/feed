#!/usr/bin/env bash

# 978 UAT enable/disable management. Operator-facing alternative to editing
# /etc/airplanes/feed.env by hand for users not on the new feeder image
# (image users have the same surface in webconfig).
#
# UAT is opt-in: an empty UAT_INPUT means "no 978 connector wired at all".
# Enable writes UAT_INPUT="127.0.0.1:30978" (the well-known local
# dump978-fa endpoint, the only value accepted by airplanes-978.sh and
# webconfig's validator) and optionally pins DUMP978_SDR_SERIAL /
# DUMP978_GAIN — both wrapper fallbacks (978 / 42.1) are sensible
# defaults that get used when the keys are absent, so emitting them is
# only required when the operator wants a different SDR serial or gain.

DEFAULT_DUMP978_SDR_SERIAL="978"
DEFAULT_DUMP978_GAIN="42.1"
LOCAL_UAT_ENDPOINT="127.0.0.1:30978"

# Image-only systemd units. On a standalone-feed install these don't exist;
# _uat_unit_exists gates each restart so the CLI works the same way on both.
# `airplanes-feed.service` is always restarted (it reads UAT_INPUT from feed.env
# and must re-render its argv on toggle).
_UAT_OPTIONAL_UNITS=(dump978-fa.service airplanes-978.service)
_UAT_ALWAYS_UNITS=(airplanes-feed.service)

# Same skip rules as _mlat_should_skip_restart — keep the two helpers in
# lockstep so a future change to the "skip systemctl" predicate applies
# uniformly. Returns 0 (skip) or 1 (proceed).
_uat_should_skip_restart() {
    if [[ "$ROOT" != "/" ]]; then
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
        return 0
    fi
    case "${AIRPLANES_BUILD_MODE:-}" in
        1|true|yes)
            echo "Skipping service restart (AIRPLANES_BUILD_MODE set)" >&2
            return 0
            ;;
    esac
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Probe whether a given systemd unit file is installed on the host. Used
# to skip restart of image-only units on standalone-feed installs. `cat`
# returns rc 0 if the unit's drop-in stack is readable, non-zero otherwise.
_uat_unit_exists() {
    local unit="$1"
    systemctl cat -- "$unit" >/dev/null 2>&1
}

_uat_restart_services() {
    if _uat_should_skip_restart; then
        return 0
    fi
    local unit any_failed=0
    for unit in "${_UAT_ALWAYS_UNITS[@]}"; do
        if ! systemctl restart "$unit" 2>&1; then
            echo "service restart failed for $unit; recent journal output:" >&2
            journalctl -u "$unit" -n 10 --no-pager 2>/dev/null >&2 || true
            any_failed=1
        fi
    done
    for unit in "${_UAT_OPTIONAL_UNITS[@]}"; do
        if _uat_unit_exists "$unit"; then
            if ! systemctl restart "$unit" 2>&1; then
                echo "service restart failed for $unit; recent journal output:" >&2
                journalctl -u "$unit" -n 10 --no-pager 2>/dev/null >&2 || true
                any_failed=1
            fi
        fi
    done
    return "$any_failed"
}

# Validators. Mirror image-side configspec.go shapes so a value accepted
# here will also pass webconfig's check on the same feeder. The image's
# bash wrapper (dump978-fa.sh) reads these via shell sourcing of feed.env,
# so we additionally reject every byte in universalReject to prevent shell
# injection on a feeder that's later updated to a webconfig-shipping image.
_uat_check_universal() {
    local key="$1" value="$2"
    # Char-class match. Bash's =~ uses ERE; bracket expressions tolerate
    # most metas as literals. Newline/CR are added via $'…' so they appear
    # as actual bytes in the class, not as escape sequences. Null byte is
    # not separately matched — bash variables can't hold \0 (the read
    # truncates at it), so an injected NUL never reaches this function.
    if [[ "$value" =~ [\"\\\$\`\;\&\|\<\>\#\'$'\n'$'\r'] ]]; then
        die "$key contains a forbidden shell metacharacter"
    fi
}

# DUMP978_SDR_SERIAL: empty or [0-9A-Za-z_-]{1,32} (matches dump978SerialRE
# in configspec.go).
_uat_validate_serial() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    [[ "$v" =~ ^[0-9A-Za-z_-]{1,32}$ ]] || die "DUMP978_SDR_SERIAL must match [0-9A-Za-z_-]{1,32} or be empty"
    _uat_check_universal DUMP978_SDR_SERIAL "$v"
}

# DUMP978_GAIN: numeric 0..60. dump978-fa's --sdr-gain takes a numeric dB
# value; readsb's auto/min/max strings are NOT accepted by FA's binary, so
# we reject them even though the readsb-side GAIN validator allows them.
_uat_validate_gain() {
    local v="$1"
    [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || die "DUMP978_GAIN must be a number in [0, 60]"
    # Use awk so we don't depend on bc.
    awk -v g="$v" 'BEGIN{ if (g < 0 || g > 60) exit 1; exit 0 }' \
        || die "DUMP978_GAIN must be in [0, 60]"
    _uat_check_universal DUMP978_GAIN "$v"
}

# Non-mutating USB serial probe. Mirrors the image wrapper's probe so the
# CLI and the wrapper agree on what "matches" means. Returns 0 when at
# least one /sys/bus/usb/devices/*/serial file contains the requested
# value. Test-overridable via APL_FEED_UAT_USB_SERIAL_GLOB.
: "${APL_FEED_UAT_USB_SERIAL_GLOB:=/sys/bus/usb/devices/*/serial}"
_uat_probe_serial() {
    local want="$1" f have
    [[ -n "$want" ]] || return 1
    # shellcheck disable=SC2086
    for f in $APL_FEED_UAT_USB_SERIAL_GLOB; do
        [[ -r "$f" ]] || continue
        have="$(cat "$f" 2>/dev/null)" || continue
        [[ "$have" == "$want" ]] && return 0
    done
    return 1
}

# Atomic rewrite of feed.env. Reads three keys from positional args
# ("UAT_INPUT", "DUMP978_SDR_SERIAL", "DUMP978_GAIN") in order. Pass an
# empty string for any key you want to ERASE; pass the literal "-" to
# leave the existing line untouched. (The bash `[[ -v ... ]]` form would
# be cleaner but `-` is simpler to read in callers.)
_uat_rewrite_feed_env() {
    local feed_env="$1" new_uat="$2" new_serial="$3" new_gain="$4"

    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"

    local tmp drop_re='^(UAT_INPUT|DUMP978_SDR_SERIAL|DUMP978_GAIN)='
    tmp="$(mktemp "${feed_env}.XXXXXX")"
    # Preserve any keys we're NOT touching. The `-` sentinel means "leave
    # the old line as-is"; absent values in feed.env stay absent. Build the
    # drop regex on the fly so untouched keys don't get rewritten.
    local pattern=()
    [[ "$new_uat"    != "-" ]] && pattern+=("UAT_INPUT")
    [[ "$new_serial" != "-" ]] && pattern+=("DUMP978_SDR_SERIAL")
    [[ "$new_gain"   != "-" ]] && pattern+=("DUMP978_GAIN")
    if (( ${#pattern[@]} == 0 )); then
        # Nothing to change — write the file back verbatim.
        cat "$feed_env" > "$tmp"
    else
        local re
        re="^($(IFS='|'; printf '%s' "${pattern[*]}"))="
        grep -vE "$re" "$feed_env" > "$tmp" || true
    fi
    # Append the new keys in canonical order. Empty value → emit `KEY=""`
    # (the wrapper reads ${VAR-} so an empty string is the "user-cleared"
    # signal and is preserved across rewrites). Skip the `-` sentinel.
    if [[ "$new_uat" != "-" ]]; then
        printf 'UAT_INPUT="%s"\n' "$new_uat" >> "$tmp"
    fi
    if [[ "$new_serial" != "-" ]]; then
        printf 'DUMP978_SDR_SERIAL="%s"\n' "$new_serial" >> "$tmp"
    fi
    if [[ "$new_gain" != "-" ]]; then
        printf 'DUMP978_GAIN="%s"\n' "$new_gain" >> "$tmp"
    fi
    chmod --reference="$feed_env" "$tmp" 2>/dev/null || true
    chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$feed_env"
}

apl_feed_uat_enable() {
    local serial="-" gain="-"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --serial)
                [[ $# -ge 2 ]] || die "--serial requires VALUE"
                serial="$2"; shift 2 ;;
            --gain)
                [[ $# -ge 2 ]] || die "--gain requires VALUE"
                gain="$2"; shift 2 ;;
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

    [[ "$serial" != "-" ]] && _uat_validate_serial "$serial"
    [[ "$gain"   != "-" ]] && _uat_validate_gain "$gain"

    local feed_env
    feed_env="$(feed_env_path)"
    _uat_rewrite_feed_env "$feed_env" "$LOCAL_UAT_ENDPOINT" "$serial" "$gain"
    echo "UAT_INPUT set to \"$LOCAL_UAT_ENDPOINT\" in $feed_env"
    [[ "$serial" != "-" ]] && echo "DUMP978_SDR_SERIAL set to \"$serial\""
    [[ "$gain"   != "-" ]] && echo "DUMP978_GAIN set to \"$gain\""
    if _uat_restart_services; then
        echo "Restarting 978 services ... done"
    else
        return 1
    fi
}

apl_feed_uat_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for 978 disable: $1" ;;
        esac
    done

    local feed_env
    feed_env="$(feed_env_path)"
    _uat_rewrite_feed_env "$feed_env" "" "-" "-"
    echo "UAT_INPUT cleared in $feed_env (978 disabled)"
    if _uat_restart_services; then
        echo "Restarting 978 services ... done"
    else
        return 1
    fi
}

# Interactive setup wizard. Prompts the operator through SDR serial + gain
# with defaults, runs the same probe the image wrapper uses if available,
# and surfaces a non-fatal warning on miss (the user might be configuring
# a dongle they haven't plugged in yet).
apl_feed_uat_setup() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
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
        if _uat_unit_exists "$unit"; then
            local active
            active="$(systemctl is-active "$unit" 2>/dev/null || true)"
            printf '  %-26s %s\n' "$unit" "${active:-unknown}"
        else
            printf '  %-26s %s\n' "$unit" "not installed (image-only)"
        fi
    done
}

dispatch_uat() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "978 requires a subcommand (enable|disable|setup|status)"
    shift || true
    case "$sub" in
        enable)  apl_feed_uat_enable  "$@" ;;
        disable) apl_feed_uat_disable "$@" ;;
        setup)   apl_feed_uat_setup   "$@" ;;
        status)  apl_feed_uat_status  "$@" ;;
        -h|--help) usage ;;
        *) die "unknown 978 subcommand: $sub" ;;
    esac
}
