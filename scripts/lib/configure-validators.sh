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
# Altitude unit policy:
#   `valid_altitude` accepts the union of operator-input shapes (`120`,
#   `120m`, `400ft`, `42.5`, `42.5m`) plus the empty string (tombstone
#   passthrough for the inbound `alt.value: null` round-trip). Conversion
#   to canonical bare metres happens through `altitude_to_bare_metres`,
#   which owns the regex AND the post-conversion `[-1000, 10000]` metres
#   range gate. The interactive whiptail loop in configure.sh still
#   enforces a stricter `^-?[0-9]+(ft|m)$` shape for explicit-units UX,
#   but the validator and canonicalizer are unit-tolerant.
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

# Convert an altitude input to bare metres on stdout. Single source of
# truth across configure.sh, apl-feed apply, apl-feed config sync (outbound),
# and the on-disk migrator. The Go and JS mirrors in image-webconfig consume
# the same fixture file (test/fixtures/altitude-canonicalization.json) so
# byte-exact equality holds across every writer.
#
# Inputs (regex shape):
#   ""           — empty stdout, rc 0 (tombstone passthrough)
#   <n>          — bare metres, stdout <n> (already bare)
#   <n>m         — strip m, stdout <n>
#   <n>ft        — multiply by 0.3048, stdout <result>
# Range gate (POST-CONVERSION metres): [-1000, 10000] closed; out-of-range
# returns rc 1 with empty stdout. Regex-shape failures also return rc 1.
#
# Output format: fixed-point (%.10f) with trailing-zero-after-decimal trim
# and bare-trailing-dot trim. Never exponential. Examples:
#   "120m"     -> "120"
#   "400ft"    -> "121.92"
#   "32808ft"  -> "9999.8784"
#   "-50ft"    -> "-15.24"
#   "33000ft"  -> "" + rc 1 (out of range; ~10058m)
altitude_to_bare_metres() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        return 0
    fi
    [[ "$raw" =~ ^(-?[0-9]+([.][0-9]+)?)(ft|m)?$ ]] || return 1
    local num="${BASH_REMATCH[1]}"
    local suffix="${BASH_REMATCH[3]}"
    local mult=1
    if [[ "$suffix" == "ft" ]]; then
        mult="0.3048"
    fi
    local metres
    metres="$(awk -v V="$num" -v MULT="$mult" 'BEGIN { printf "%.10f\n", V * MULT }')"
    awk -v ALT="$metres" 'BEGIN { exit !(ALT >= -1000 && ALT <= 10000) }' || return 1
    # Trim trailing zeros after the decimal point, and a bare trailing dot.
    metres="$(printf '%s' "$metres" | sed -E 's/\.?0+$//')"
    printf '%s' "$metres"
}

# Altitude validator: empty is accepted (tombstone passthrough from a server
# `alt.value: null` round-trip), non-empty delegates to altitude_to_bare_metres
# which owns both the regex shape and the post-conversion metres range gate.
# Range matches airplanes-live/website's accounts/serializers/feeder.py alt
# validator (`[-1000, 10000]` metres) — so `20000ft` (~6096m) is now accepted
# and `33000ft` (~10058m) is now rejected.
valid_altitude() {
    [[ -z "$1" ]] && return 0
    altitude_to_bare_metres "$1" >/dev/null
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

# READSB_SDR_SERIAL: empty (single-SDR default, no --device) or 1-32 chars
# in [0-9A-Za-z_-]. Same rules as valid_dump978_serial, kept separate so the
# webconfig JS twin (isValidReadsbSdrSerial) maps 1:1 and the two keys can
# diverge later.
valid_readsb_sdr_serial() {
    [[ -z "$1" ]] && return 0
    [[ "$1" =~ ^[0-9A-Za-z_-]{1,32}$ ]]
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

