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

valid_latitude() {
    [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] \
        && awk -v LAT="$1" 'BEGIN { exit !(LAT < 90 && LAT > -90) }'
}

valid_longitude() {
    [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] \
        && awk -v LON="$1" 'BEGIN { exit !(LON < 180 && LON > -180) }'
}

valid_altitude() {
    [[ "$1" =~ ^-?[0-9]+(ft|m)?$ ]]
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
