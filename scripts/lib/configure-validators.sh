#!/usr/bin/env bash
# Pure-function validators / normalizers used by configure.sh to accept
# operator input from whiptail prompts and AIRPLANES_* env vars. Extracted
# to a lib so per-function tests can exercise the regex + range rules
# directly without driving them through configure.sh's whiptail loops.
#
# Each function takes its inputs as positional args and produces a boolean
# exit status (validators) or stdout (normalizer). No global-state reads
# or writes — safe to source anywhere.
#
# Altitude unit policy (intentional split):
#   `valid_altitude` accepts unitless integers (e.g. `0`, `123`) so build-mode
#   feeders configured non-interactively with AIRPLANES_ALTITUDE=0 don't get
#   rejected. The interactive whiptail loop in configure.sh enforces a
#   stricter `^-?[0-9]+(ft|m)$` shape because the operator is being asked
#   for an antenna altitude and units must be explicit. Both rules coexist
#   on purpose.
#
# `sanitize_mlat_user` character set:
#   The `tr -c '[a-zA-Z0-9]_\- ' '_'` filter replaces every character NOT
#   in the allowlist with `_`. Allowed: A-Z, a-z, 0-9, underscore,
#   hyphen, space, AND square brackets `[` `]` (a `tr` quirk — `[` and
#   `]` are literal characters here, not character-class delimiters).
#   Everything else (`$`, backtick, single/double quotes, backslash,
#   parens, braces, shell metacharacters, etc.) gets rewritten to `_`.
#   The contract is pinned by test_configure_validators.bats; do not
#   change the filter without updating both.

sanitize_mlat_user() {
    printf '%s' "$1" | tr -c '[a-zA-Z0-9]_\- ' '_'
}

# Numeric range bounds are CLOSED, matching Go configspec.validateLatitude
# (`f < -90 || f > 90` rejects, i.e. ±90 accepted). The previous open-range
# check rejected a legitimate ±90 antenna at the geographic poles.
valid_latitude() {
    [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] \
        && awk -v LAT="$1" 'BEGIN { exit !(LAT <= 90 && LAT >= -90) }'
}

valid_longitude() {
    [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] \
        && awk -v LON="$1" 'BEGIN { exit !(LON <= 180 && LON >= -180) }'
}

# Altitude accepts integers and decimals, optional `m`/`ft` suffix, and is
# numerically range-checked against [-1000, 10000] to match Go configspec.
# The previous integer-only rule rejected legitimate decimal antenna
# heights (e.g. `120.5m`) and skipped the range check entirely.
valid_altitude() {
    [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?(ft|m)?$ ]] || return 1
    local num="${BASH_REMATCH[0]}"
    num="${num%ft}"
    num="${num%m}"
    awk -v ALT="$num" 'BEGIN { exit !(ALT >= -1000 && ALT <= 10000) }'
}

# Strict shape match for canonical MLAT_USER input. Mirrors Go
# configspec.mlatUserRE. Differs from sanitize_mlat_user (which rewrites
# disallowed bytes to `_` — used by configure.sh's whiptail loop) by
# refusing instead of mangling. Empty string is rejected here; callers
# that allow empty (daemon-Anonymous fallback) check that separately.
valid_mlat_user_strict() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

valid_bool() {
    case "$1" in
        true|false) return 0 ;;
        *) return 1 ;;
    esac
}

# GAIN accepts auto/min/max or a finite number in [0, 60]. Mirrors Go
# configspec.validateGain.
valid_gain() {
    case "$1" in
        auto|min|max) return 0 ;;
    esac
    [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v G="$1" 'BEGIN { exit !(G >= 0 && G <= 60) }'
}

# UAT_INPUT v1: only "" (978 disabled) or the local dump978-fa endpoint.
# Mirrors Go configspec.validateUATInput.
valid_uat_input() {
    case "$1" in
        ''|127.0.0.1:30978) return 0 ;;
        *) return 1 ;;
    esac
}

# DUMP978_SDR_SERIAL: empty or 1-32 chars in [0-9A-Za-z_-]. Mirrors
# Go configspec.validateDump978SdrSerial.
valid_dump978_serial() {
    [[ -z "$1" ]] && return 0
    [[ "$1" =~ ^[0-9A-Za-z_-]{1,32}$ ]]
}

# DUMP978_GAIN: finite number in [0, 60]. dump978-fa rejects readsb's
# `auto`/`min`/`max` so we reject them here too. Mirrors Go
# configspec.validateDump978Gain.
valid_dump978_gain() {
    [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v G="$1" 'BEGIN { exit !(G >= 0 && G <= 60) }'
}

normalize_altitude() {
    local alt="$1"
    if [[ $alt =~ ^-([0-9]+)ft$ ]]; then
        awk -v NUM="${BASH_REMATCH[1]}" 'BEGIN { printf "-%0.2f", NUM / 3.28 }'
    elif [[ $alt =~ ^-([0-9]+)m$ ]]; then
        printf -- '-%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$alt"
    fi
}
