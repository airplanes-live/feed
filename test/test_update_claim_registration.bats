#!/usr/bin/env bats

setup() {
    HELPER="$BATS_TEST_DIRNAME/../scripts/lib/claim-registration.sh"
    UPDATE="$BATS_TEST_DIRNAME/../update.sh"
    ROOT_DIR="$(mktemp -d)"
    BIN="$ROOT_DIR/apl-feed"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

write_apl_feed_stub() {
    local exit_code="$1"
    cat > "$BIN" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$ROOT_DIR/argv"
exit $exit_code
SH
    chmod +x "$BIN"
}

line_of_exact() {
    grep -nFx "$1" "$UPDATE" | head -n 1 | cut -d: -f1
}

last_line_containing() {
    grep -nF "$1" "$UPDATE" | tail -n 1 | cut -d: -f1
}

@test "claim registration helper succeeds quietly when apl-feed succeeds" {
    write_apl_feed_stub 0

    run env APL_FEED_BIN="$BIN" bash -c "source '$HELPER'; register_claim_secret"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Registering feeder claim secret" ]]
    [[ ! "$output" =~ "WARNING" ]]
    [ "$(cat "$ROOT_DIR/argv")" = "claim register --max-retry-time 15" ]
}

@test "claim registration helper warns and continues when apl-feed fails" {
    write_apl_feed_stub 2

    run env APL_FEED_BIN="$BIN" bash -c "source '$HELPER'; register_claim_secret"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "WARNING: claim registration did not complete" ]]
    [[ "$output" =~ "sudo apl-feed claim register" ]]
}

@test "update.sh sources and calls claim registration helper" {
    local source_line call_line
    source_line="$(line_of_exact 'source "$GIT/scripts/lib/claim-registration.sh"')"
    call_line="$(last_line_containing 'register_claim_secret')"

    [ -n "$source_line" ]
    [ -n "$call_line" ]
    [ "$source_line" -lt "$call_line" ]
}

@test "update.sh calls claim registration after service health checks" {
    local feed_check_line mlat_check_line call_line
    feed_check_line="$(last_line_containing 'systemctl is-active airplanes-feed')"
    mlat_check_line="$(last_line_containing 'systemctl is-active airplanes-mlat')"
    call_line="$(last_line_containing 'register_claim_secret')"

    [ -n "$feed_check_line" ]
    [ -n "$mlat_check_line" ]
    [ -n "$call_line" ]
    [ "$feed_check_line" -lt "$call_line" ]
    [ "$mlat_check_line" -lt "$call_line" ]
}
