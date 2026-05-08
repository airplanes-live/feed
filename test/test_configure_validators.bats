#!/usr/bin/env bats

# Per-function tests for scripts/lib/configure-validators.sh. The same
# rules are also exercised end-to-end via test_configure_script.bats's
# whiptail loops and non-interactive paths; these tests pin the contract
# at the function boundary so a future webconfig backend (or any other
# reuser) has a stable specification.

setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/lib/configure-validators.sh"
    # shellcheck source=/dev/null
    source "$LIB"
}

# --- valid_latitude ---

@test "valid_latitude accepts canonical decimals" {
    valid_latitude 0
    valid_latitude 52.52
    valid_latitude -89.99
    valid_latitude 0.0
}

@test "valid_latitude accepts +signed values" {
    valid_latitude '+52.52'
    valid_latitude '+0'
}

@test "valid_latitude rejects out-of-range" {
    ! valid_latitude 90
    ! valid_latitude 90.0
    ! valid_latitude -90
    ! valid_latitude 91
    ! valid_latitude -91
    ! valid_latitude 100
}

@test "valid_latitude rejects non-numeric" {
    ! valid_latitude north
    ! valid_latitude ''
    ! valid_latitude '52.52N'
    ! valid_latitude '52,52'
}

# --- valid_longitude ---

@test "valid_longitude accepts canonical decimals" {
    valid_longitude 0
    valid_longitude 13.405
    valid_longitude -179.99
    valid_longitude 179.99
}

@test "valid_longitude rejects out-of-range" {
    ! valid_longitude 180
    ! valid_longitude -180
    ! valid_longitude 181
    ! valid_longitude -181
}

@test "valid_longitude rejects non-numeric" {
    ! valid_longitude east
    ! valid_longitude ''
    ! valid_longitude '13.40E'
}

# --- valid_altitude ---

@test "valid_altitude accepts unitless integers (build-mode contract)" {
    # README's build-mode example uses AIRPLANES_ALTITUDE=0 — keep it valid
    # at the lib level even though the interactive UI requires units.
    valid_altitude 0
    valid_altitude 35
    valid_altitude -10
    valid_altitude 1000
}

@test "valid_altitude accepts ft and m suffixes" {
    valid_altitude 35m
    valid_altitude 100ft
    valid_altitude -5m
    valid_altitude -200ft
}

@test "valid_altitude rejects decimals" {
    ! valid_altitude 35.5
    ! valid_altitude 35.5m
    ! valid_altitude 35.5ft
}

@test "valid_altitude rejects unknown units" {
    ! valid_altitude 35km
    ! valid_altitude 35yd
    ! valid_altitude 35M  # case-sensitive: only lowercase 'm' is meters
    ! valid_altitude 35FT
}

@test "valid_altitude rejects non-numeric" {
    ! valid_altitude high
    ! valid_altitude ''
    ! valid_altitude m
    ! valid_altitude ft
}

# --- normalize_altitude ---

@test "normalize_altitude passes positive values through unchanged" {
    [ "$(normalize_altitude 35m)" = "35m" ]
    [ "$(normalize_altitude 100ft)" = "100ft" ]
    [ "$(normalize_altitude 0)" = "0" ]
    [ "$(normalize_altitude 200)" = "200" ]
}

@test "normalize_altitude converts negative feet to negative meters" {
    # Existing rule: -<n>ft -> awk "%.2f" of n/3.28
    local out
    out="$(normalize_altitude -100ft)"
    [[ "$out" =~ ^-30\.[0-9]+$ ]]
}

@test "normalize_altitude strips m suffix from negative meters" {
    [ "$(normalize_altitude -50m)" = "-50" ]
    [ "$(normalize_altitude -1m)" = "-1" ]
}

# --- sanitize_mlat_user ---
#
# Contract pin (see header in configure-validators.sh): the `tr` filter
# replaces every character NOT in [a-zA-Z0-9_- ] with `_`. These tests
# exhaustively pin that allowlist so a future maintainer can't widen or
# narrow it without seeing a test break.

@test "sanitize_mlat_user passes alphanumerics through unchanged" {
    [ "$(sanitize_mlat_user 'alice')" = 'alice' ]
    [ "$(sanitize_mlat_user 'ABC123')" = 'ABC123' ]
    [ "$(sanitize_mlat_user 'william34-london')" = 'william34-london' ]
}

@test "sanitize_mlat_user preserves underscore, hyphen, space" {
    [ "$(sanitize_mlat_user 'alice_bob')" = 'alice_bob' ]
    [ "$(sanitize_mlat_user 'alice-bob')" = 'alice-bob' ]
    [ "$(sanitize_mlat_user 'alice bob')" = 'alice bob' ]
}

@test "sanitize_mlat_user replaces shell metacharacters with underscore" {
    [ "$(sanitize_mlat_user 'al$ce')"  = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al`ce')"  = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al"ce')"  = 'al_ce' ]
    [ "$(sanitize_mlat_user "al'ce")"  = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al\ce')" = 'al_ce' ]
}

@test "sanitize_mlat_user: parens, braces are replaced with underscore" {
    [ "$(sanitize_mlat_user 'al(ce')"  = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al)ce')"  = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al{ce')"  = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al}ce')"  = 'al_ce' ]
}

@test "sanitize_mlat_user: square brackets pass through unchanged (tr-set quirk, contract pin)" {
    # The `tr -c '[a-zA-Z0-9]_\- '` filter treats `[` and `]` as LITERAL
    # characters in the allowlist (BSD/GNU tr both do — POSIX `tr` does
    # not use `[...]` as a character-class delimiter outside the
    # `[:class:]` form). So these end up allowed alongside `a-zA-Z0-9`.
    # Pinning this behavior so a future maintainer who tightens the
    # filter sees the test break and decides explicitly.
    [ "$(sanitize_mlat_user 'al[ce')" = 'al[ce' ]
    [ "$(sanitize_mlat_user 'al]ce')" = 'al]ce' ]
}

@test "sanitize_mlat_user replaces other non-allowlist characters" {
    [ "$(sanitize_mlat_user 'al@ce')" = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al#ce')" = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al!ce')" = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al?ce')" = 'al_ce' ]
    [ "$(sanitize_mlat_user 'al/ce')" = 'al_ce' ]
}

@test "sanitize_mlat_user collapses tabs and newlines to underscore" {
    [ "$(sanitize_mlat_user $'al\tce')" = 'al_ce' ]
    [ "$(sanitize_mlat_user $'al\nce')" = 'al_ce' ]
}

@test "sanitize_mlat_user empty input produces empty output" {
    [ "$(sanitize_mlat_user '')" = '' ]
}

@test "sanitize_mlat_user multiple bad characters each become underscore (not collapsed)" {
    [ "$(sanitize_mlat_user 'a!@#b')" = 'a___b' ]
}
