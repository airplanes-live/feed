#!/usr/bin/env bats

# Executable record of the feed.env value contract (one KEY=value or
# KEY="value" per line, plain scalars, no expansion/escapes, no same-line
# comments — see the header configure.sh writes).
#
# feed.env is consumed by several parsers: bash `source` (the daemons),
# systemd EnvironmentFile= (image units), and the CLI's single reader —
# _apl_feed_apply_read (the strict reader behind `apl-feed apply`,
# `apl-feed config show`, and feed_env_get, which delegates to it).
# Conforming values must parse identically in the ones executable here;
# the divergence tests pin exactly how the forbidden shapes fall apart,
# so a parser change that shifts the boundary is visible in CI.

setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/lib"
    APL="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    mkdir -p "$ROOT_DIR/etc/airplanes"

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$LIB/configure-validators.sh"
    # shellcheck source=../scripts/lib/feed-env-keys.sh
    source "$LIB/feed-env-keys.sh"
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$LIB/feed-env-apply.sh"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$APL/common.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    FEED_ENV="$ROOT_DIR/etc/airplanes/feed.env"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Reader 1: bash `source`, the daemons' parser. Runs in a throwaway bash
# so vector content can't leak state into the test shell. Prints the
# value, __UNSET__ when the key never materialized, or fails when the
# file itself doesn't parse.
read_via_source() {
    local key="$1"
    bash -c 'source "$1" 2>/dev/null || exit 99; printf "%s" "${'"$key"'-__UNSET__}"' _ "$FEED_ENV"
}

# Reader 2: feed_env_get, the sed-based CLI reader.
read_via_get() {
    feed_env_get "$1" || printf '__UNSET__'
}

# Reader 3: _apl_feed_apply_read, the strict reader behind apply and
# config show.
read_via_strict() {
    local key="$1"
    local -A m=()
    _apl_feed_apply_read "$FEED_ENV" m
    if [[ -n "${m[$key]+set}" ]]; then
        printf '%s' "${m[$key]}"
    else
        printf '__UNSET__'
    fi
}

@test "contract: conforming shapes parse identically across all three readers" {
    # LINE<TAB>EXPECTED vector table. Conforming = double-quoted or bare
    # plain scalar, exactly what configure.sh and apl-feed apply write.
    local vectors=$'KEY=hello\thello
KEY="hello world"\thello world
KEY="--net-connector feed.airplanes.test,30004,beast_reduce_plus_out"\t--net-connector feed.airplanes.test,30004,beast_reduce_plus_out
KEY="https://airplanes.test"\thttps://airplanes.test
KEY=true\ttrue
KEY="-12.5"\t-12.5
KEY="x" \tx'

    local line expected got_source got_get got_strict
    while IFS=$'\t' read -r line expected; do
        printf '%s\n' "$line" > "$FEED_ENV"
        got_source="$(read_via_source KEY)"
        got_get="$(read_via_get KEY)"
        got_strict="$(read_via_strict KEY)"
        [ "$got_source" = "$expected" ] || { echo "source: [$line] -> [$got_source] != [$expected]"; return 1; }
        [ "$got_get" = "$expected" ]    || { echo "feed_env_get: [$line] -> [$got_get] != [$expected]"; return 1; }
        [ "$got_strict" = "$expected" ] || { echo "strict: [$line] -> [$got_strict] != [$expected]"; return 1; }
    done <<< "$vectors"
}

@test "contract: duplicate keys resolve last-write-wins in all three readers" {
    printf 'KEY=first\nKEY="second"\n' > "$FEED_ENV"

    [ "$(read_via_source KEY)" = "second" ]
    [ "$(read_via_get KEY)" = "second" ]
    [ "$(read_via_strict KEY)" = "second" ]
}

@test "divergence: explicitly empty value is invisible to feed_env_get" {
    # source and the strict reader represent KEY="" as an empty string;
    # feed_env_get conflates it with absent (rc 1). Callers that treat
    # empty as meaningful (UAT_INPUT) must use the strict reader.
    printf 'KEY=""\n' > "$FEED_ENV"

    [ "$(read_via_source KEY)" = "" ]
    [ "$(read_via_strict KEY)" = "" ]
    run feed_env_get KEY
    [ "$status" -eq 1 ]
}

@test "divergence: quoted value with trailing comment is dropped by both CLI readers" {
    # Forbidden by the contract: source reads the clean value, but both
    # CLI readers (feed_env_get delegates to the strict reader) refuse
    # the line rather than guessing — historically feed_env_get's bare
    # rule captured the opening quote here.
    printf 'KEY="false" # note\n' > "$FEED_ENV"

    [ "$(read_via_source KEY)" = "false" ]
    [ "$(read_via_strict KEY)" = "__UNSET__" ]
    [ "$(read_via_get KEY)" = "__UNSET__" ]
}

@test "divergence: bare value with trailing comment is dropped by both CLI readers" {
    printf 'KEY=auto # note\n' > "$FEED_ENV"

    [ "$(read_via_source KEY)" = "auto" ]
    [ "$(read_via_get KEY)" = "__UNSET__" ]
    [ "$(read_via_strict KEY)" = "__UNSET__" ]
}

@test "divergence: dollar expansion is live under source, literal in the CLI readers" {
    # Purpose-built sentinel instead of an inherited variable like HOME,
    # so the expected expansion is fully under the test's control.
    export APL_CONTRACT_SENTINEL="expanded-by-source"
    printf 'KEY="$APL_CONTRACT_SENTINEL"\n' > "$FEED_ENV"

    [ "$(read_via_source KEY)" = "expanded-by-source" ]
    [ "$(read_via_get KEY)" = '$APL_CONTRACT_SENTINEL' ]
    [ "$(read_via_strict KEY)" = '$APL_CONTRACT_SENTINEL' ]
}

@test "divergence: unterminated quote breaks source entirely" {
    printf 'KEY="abc\nOTHER="fine"\n' > "$FEED_ENV"

    # The whole file stops being sourceable — the worst failure mode the
    # contract exists to prevent.
    run read_via_source KEY
    [ "$status" -eq 99 ]
    # The strict reader drops the malformed line and keeps going.
    [ "$(read_via_strict KEY)" = "__UNSET__" ]
}

@test "informational: single-quoted values agree across the bash readers" {
    # Works today in all bash-side parsers, but stays outside the
    # documented contract: supported writers only emit double-quoted or
    # bare values.
    printf "KEY='a b'\n" > "$FEED_ENV"

    [ "$(read_via_source KEY)" = "a b" ]
    [ "$(read_via_get KEY)" = "a b" ]
    [ "$(read_via_strict KEY)" = "a b" ]
}

@test "writer: universal-reject blocks every non-conforming byte" {
    # The canonical writer can only ever produce conforming values —
    # that, not reader leniency, is what keeps the parsers agreeing.
    local bad_values=('a"b' 'a\b' 'a$b' 'a`b' 'a;b' 'a&b' 'a|b' 'a<b' 'a>b' 'a#b' "a'b" $'a\nb' $'a\rb')
    local v
    for v in "${bad_values[@]}"; do
        if _apl_feed_apply_universal_reject "$v"; then
            echo "universal-reject accepted forbidden value: [$v]"
            return 1
        fi
    done
    _apl_feed_apply_universal_reject 'plain-scalar value 1.5, ok'
}
