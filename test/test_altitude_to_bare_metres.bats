#!/usr/bin/env bats

# Fixture-driven coverage for altitude_to_bare_metres(). The same fixture
# file is consumed by image-webconfig's Go and JS mirrors so divergent
# behaviour surfaces as a unit-test failure in both repos. Output strings
# are pinned byte-exact; any consumer that drifts breaks dirty-state
# comparisons and triggers metadata-churn in apl-feed apply.

setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/lib/configure-validators.sh"
    FIXTURE="$BATS_TEST_DIRNAME/fixtures/altitude-canonicalization.json"
    # shellcheck source=/dev/null
    source "$LIB"
    [ -r "$FIXTURE" ] || skip "fixture not present: $FIXTURE"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

@test "altitude_to_bare_metres matches the shared fixture (every case)" {
    local count
    count="$(jq -r '.cases | length' "$FIXTURE")"
    [ "$count" -gt 0 ]

    local i
    for ((i = 0; i < count; i++)); do
        local input expected_output expected_ok
        input="$(jq -r ".cases[$i].input" "$FIXTURE")"
        expected_output="$(jq -r ".cases[$i].expected_output" "$FIXTURE")"
        expected_ok="$(jq -r ".cases[$i].expected_ok" "$FIXTURE")"

        local actual_output actual_rc=0
        actual_output="$(altitude_to_bare_metres "$input")" || actual_rc=$?

        if [[ "$expected_ok" == "true" ]]; then
            if [[ "$actual_rc" -ne 0 ]]; then
                printf 'fixture case %d: input=%q expected rc=0, got rc=%d\n' "$i" "$input" "$actual_rc" >&2
                return 1
            fi
        else
            if [[ "$actual_rc" -eq 0 ]]; then
                printf 'fixture case %d: input=%q expected rc!=0, got rc=0 (output=%q)\n' "$i" "$input" "$actual_output" >&2
                return 1
            fi
        fi

        if [[ "$actual_output" != "$expected_output" ]]; then
            printf 'fixture case %d: input=%q expected output=%q, got %q\n' "$i" "$input" "$expected_output" "$actual_output" >&2
            return 1
        fi
    done
}

@test "altitude_to_bare_metres never emits scientific notation" {
    # Pin: regardless of value magnitude, the output regex must match the
    # validator's regex shape (otherwise a round-trip through valid_altitude
    # would reject our own canonicalized output).
    local out
    for input in "0.0001m" "0.0001ft" "9999.999m"; do
        out="$(altitude_to_bare_metres "$input")" || continue
        [[ "$out" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
    done
}

@test "altitude_to_bare_metres output round-trips through valid_altitude" {
    # The validator must accept whatever the canonicalizer produces.
    # Otherwise a write succeeds on first apply, then fails on subsequent
    # reads/writes — silent data corruption.
    local count
    count="$(jq -r '.cases | length' "$FIXTURE")"
    local i input expected_output expected_ok
    for ((i = 0; i < count; i++)); do
        input="$(jq -r ".cases[$i].input" "$FIXTURE")"
        expected_output="$(jq -r ".cases[$i].expected_output" "$FIXTURE")"
        expected_ok="$(jq -r ".cases[$i].expected_ok" "$FIXTURE")"
        [[ "$expected_ok" == "true" ]] || continue
        # Empty output (tombstone) is accepted by valid_altitude explicitly.
        if [[ -z "$expected_output" ]]; then
            valid_altitude ""
            continue
        fi
        valid_altitude "$expected_output"
    done
}
