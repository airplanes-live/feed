#!/usr/bin/env bats

# Pure-function tests for scripts/lib/legacy-mlat-translation.sh. Three
# downstream sites (apl-feed/import.sh, update-migrations.sh, airplanes-
# mlat.sh) historically had divergent inline parsers; this lib is now
# the single source of truth. The matrix below is the contract those
# sites import from.

setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/lib/legacy-mlat-translation.sh"
    # shellcheck source=../scripts/lib/legacy-mlat-translation.sh
    source "$LIB"
}

assert_recognised() {
    local fn="$1" input="$2" expected="$3"
    local out rc=0
    out="$("$fn" "$input")" || rc=$?
    if (( rc != 0 )); then
        echo "FAIL: $fn '$input' returned rc=$rc, expected rc=0 + '$expected'" >&2
        return 1
    fi
    if [[ "$out" != "$expected" ]]; then
        echo "FAIL: $fn '$input' = '$out', expected '$expected'" >&2
        return 1
    fi
}

assert_unrecognised() {
    local fn="$1" input="$2"
    local out rc=0
    out="$("$fn" "$input")" || rc=$?
    if (( rc == 0 )); then
        echo "FAIL: $fn '$input' returned rc=0 (recognised as '$out'), expected rc!=0 (unrecognised)" >&2
        return 1
    fi
    if [[ -n "$out" ]]; then
        echo "FAIL: $fn '$input' emitted '$out' on unrecognised; should be empty" >&2
        return 1
    fi
}

@test "derive_mlat_private_from_privacy: --privacy → true" {
    assert_recognised derive_mlat_private_from_privacy '--privacy' 'true'
}

@test "derive_mlat_private_from_privacy: whitespace around --privacy tolerated" {
    assert_recognised derive_mlat_private_from_privacy '  --privacy  ' 'true'
    assert_recognised derive_mlat_private_from_privacy $'\t--privacy\n' 'true'
}

@test "derive_mlat_private_from_privacy: empty → false" {
    assert_recognised derive_mlat_private_from_privacy '' 'false'
}

@test "derive_mlat_private_from_privacy: explicit no/false/0 → false" {
    assert_recognised derive_mlat_private_from_privacy 'no' 'false'
    assert_recognised derive_mlat_private_from_privacy 'false' 'false'
    assert_recognised derive_mlat_private_from_privacy '0' 'false'
}

@test "derive_mlat_private_from_privacy: unrecognised values return non-zero" {
    # No silent flip to false on values we don't understand. Callers
    # must decide whether to preserve current state or default; the
    # helper refuses to coerce.
    assert_unrecognised derive_mlat_private_from_privacy 'yes'
    assert_unrecognised derive_mlat_private_from_privacy 'true'
    assert_unrecognised derive_mlat_private_from_privacy '1'
    assert_unrecognised derive_mlat_private_from_privacy 'garble'
    assert_unrecognised derive_mlat_private_from_privacy '--public'
}

@test "derive_mlat_private_from_marker: no → true (inverted polarity)" {
    assert_recognised derive_mlat_private_from_marker 'no' 'true'
}

@test "derive_mlat_private_from_marker: yes/true/1 → false" {
    assert_recognised derive_mlat_private_from_marker 'yes' 'false'
    assert_recognised derive_mlat_private_from_marker 'true' 'false'
    assert_recognised derive_mlat_private_from_marker '1' 'false'
}

@test "derive_mlat_private_from_marker: whitespace tolerated" {
    assert_recognised derive_mlat_private_from_marker '  no  ' 'true'
    assert_recognised derive_mlat_private_from_marker $'\tyes\n' 'false'
}

@test "derive_mlat_private_from_marker: unrecognised returns non-zero" {
    assert_unrecognised derive_mlat_private_from_marker ''
    assert_unrecognised derive_mlat_private_from_marker 'garble'
    assert_unrecognised derive_mlat_private_from_marker 'private'
}

@test "no side effects: helpers don't leak named variables" {
    # Run a representative call set and assert the helpers' internal
    # locals (v) are not visible to the caller. (Full `declare -p` diff
    # would also catch implicit bash state like BASH_REMATCH; this test
    # focuses on the explicit invariant.)
    unset v _import_v _migration_v 2>/dev/null || true
    derive_mlat_private_from_privacy '--privacy' >/dev/null
    derive_mlat_private_from_marker 'no' >/dev/null
    [ -z "${v:-}" ]
}
