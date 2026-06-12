#!/usr/bin/env bats

# Unit tests for `apl-feed claim status` (claim.sh:claim_status) and the
# shared probe it leans on (http.sh:claim_status_probe).
#
# Most cases stub `post_json_bearer` to write a prepared response and
# return a chosen HTTP code — no Python server needed. Local-state cases
# (no_identity / unregistered / secret_invalid) assert the probe is never
# reached.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    mkdir -p "$TMPDIR" "$ROOT_DIR/etc/airplanes"
    export TMPDIR
    APL_FEED_SECRET_OWNER="$(id -un)"
    APL_FEED_SECRET_GROUP="$(id -gn)"
    export APL_FEED_SECRET_OWNER APL_FEED_SECRET_GROUP

    # common.sh installs an EXIT trap; save/restore bats's own so teardown
    # still fires (mirrors test_apl_feed_status.bats).
    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/http.sh
    source "$LIB_DIR/http.sh"
    # shellcheck source=../scripts/apl-feed/claim.sh
    source "$LIB_DIR/claim.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    # post_json_bearer is stubbed in every server-path test; this URL is
    # never actually dialed.
    WEBSITE_URL="http://127.0.0.1:0"
    UUID='11111111-2222-3333-4444-555555555555'
    SECRET='ABCDEFGHIJKLMNOP'
    PROBE_CALLS="$ROOT_DIR/probe.calls"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Seed feeder-id (+ optionally a valid claim secret).
setup_claim_state() {
    local write_secret="${1:-1}"
    printf '%s\n' "$UUID" > "$ROOT_DIR/etc/airplanes/feeder-id"
    if (( write_secret )); then
        printf '%s\n' "$SECRET" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
        chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    fi
}

# Stub post_json_bearer to write a prepared response and return a code.
# Records each call so local-state tests can assert "no probe". On the
# rc=99 sentinel, simulates a transport failure (curl rc != 0).
stub_post_json() {
    local code="$1" body="$2"
    eval "
post_json_bearer() {
    printf 'called\n' >> '$PROBE_CALLS'
    local response_file=\"\$4\"
    if [[ '$code' == '99' ]]; then
        return 7
    fi
    printf '%s' '$body' > \"\$response_file\"
    printf '%s' '$code'
    return 0
}
"
}

jqr() { printf '%s' "$1" | jq -r "$2"; }

# --- local state (no network) -------------------------------------------

@test "claim status: no Feeder ID → no_identity, no probe" {
    stub_post_json 200 '{}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'no_identity' ]
    [ ! -f "$PROBE_CALLS" ]
}

@test "claim status: Feeder ID but no secret → unregistered, no probe" {
    setup_claim_state 0
    stub_post_json 200 '{}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'unregistered' ]
    [ ! -f "$PROBE_CALLS" ]
}

@test "claim status: zero-byte secret → secret_invalid, no probe" {
    setup_claim_state 0
    : > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    stub_post_json 200 '{}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'secret_invalid' ]
    [ ! -f "$PROBE_CALLS" ]
}

@test "claim status: non-canonical secret → secret_invalid, no probe" {
    setup_claim_state 0
    printf 'not-a-valid-secret\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    stub_post_json 200 '{}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'secret_invalid' ]
    [ ! -f "$PROBE_CALLS" ]
}

# --- server outcomes ----------------------------------------------------

@test "claim status: 200 registered+owner → claimed (exit 0)" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":true,"reset_until":null,"last_seen_at":"2026-06-03T10:00:00Z","last_seen_age_seconds":12}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.schema_version')" = '1' ]
    [ "$(jqr "$output" '.result')" = 'claimed' ]
    [ "$(jqr "$output" '.registered')" = 'true' ]
    [ "$(jqr "$output" '.owner_present')" = 'true' ]
    [ "$(jqr "$output" '.version')" = '7' ]
    [ "$(jqr "$output" '.last_seen_at')" = '2026-06-03T10:00:00Z' ]
    [ "$(jqr "$output" '.last_seen_age_seconds')" = '12' ]
}

@test "claim status: 200 registered, owner_present:false → unclaimed" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":false}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'unclaimed' ]
    [ "$(jqr "$output" '.owner_present')" = 'false' ]
}

@test "claim status: claimable absent (older server) → .claimable null, default copy" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":false}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.claimable')" = 'null' ]
    [ "$(jqr "$output" '.claim_unavailable_reason')" = 'null' ]
    run claim_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claim it at:"* ]]
}

@test "claim status: claimable:true passes through" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":false,"claimable":true,"claim_unavailable_reason":null}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'unclaimed' ]
    [ "$(jqr "$output" '.claimable')" = 'true' ]
}

@test "claim status: not_seen_feeding, never seen → waiting-for-first-data copy" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":false,"claimable":false,"claim_unavailable_reason":"not_seen_feeding","last_seen_at":null,"last_seen_age_seconds":null}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'unclaimed' ]
    [ "$(jqr "$output" '.claimable')" = 'false' ]
    [ "$(jqr "$output" '.claim_unavailable_reason')" = 'not_seen_feeding' ]
    run claim_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting for first data"* ]]
    [[ "$output" != *"Claim it at:"* ]]
}

@test "claim status: not_seen_feeding, stale last_seen → reconnect copy" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":false,"claimable":false,"claim_unavailable_reason":"not_seen_feeding","last_seen_at":"2026-04-01T10:00:00Z","last_seen_age_seconds":3000000}'
    run claim_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"not seen feeding recently"* ]]
    [[ "$output" != *"waiting for first data"* ]]
}

@test "claim status: claimable:false with non-liveness reason → generic copy, no data hint" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":false,"claimable":false,"claim_unavailable_reason":"claim_blocked"}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.claim_unavailable_reason')" = 'claim_blocked' ]
    run claim_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"not currently claimable"* ]]
    [[ "$output" != *"waiting for first data"* ]]
    [[ "$output" != *"Claim it at:"* ]]
}

@test "claim status: 200 registered:true, no version (minimal) → secret_mismatch" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'secret_mismatch' ]
}

@test "claim status: 200 registered:false → server_unregistered" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":false}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'server_unregistered' ]
    [ "$(jqr "$output" '.registered')" = 'false' ]
}

@test "claim status: 200 registered:true+version but missing owner_present → error" {
    # An authenticated reply must carry a boolean owner_present; its
    # absence is a contract fault, not an "unclaimed" feeder.
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7}'
    run claim_status --json
    [ "$status" -eq 2 ]
    [ "$(jqr "$output" '.result')" = 'error' ]
}

@test "claim status: 423 → blocked (exit 0)" {
    setup_claim_state 1
    stub_post_json 423 '{"error":"data_blocked"}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'blocked' ]
}

@test "claim status: 429 → rate_limited with retry_after_seconds" {
    setup_claim_state 1
    stub_post_json 429 '{"error":"rate_limited","retry_after":42}'
    run claim_status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'rate_limited' ]
    [ "$(jqr "$output" '.retry_after_seconds')" = '42' ]
}

@test "claim status: transport failure → unreachable (exit 2)" {
    setup_claim_state 1
    stub_post_json 99 ''
    run claim_status --json
    [ "$status" -eq 2 ]
    [ "$(jqr "$output" '.result')" = 'unreachable' ]
}

@test "claim status: unexpected HTTP → error (exit 2)" {
    setup_claim_state 1
    stub_post_json 503 '{"error":"upstream_down"}'
    run claim_status --json
    [ "$status" -eq 2 ]
    [ "$(jqr "$output" '.result')" = 'error' ]
}

@test "claim status: 200 with non-JSON body → error (not server_unregistered)" {
    setup_claim_state 1
    stub_post_json 200 '<html>gateway error</html>'
    run claim_status --json
    [ "$status" -eq 2 ]
    [ "$(jqr "$output" '.result')" = 'error' ]
}

@test "claim status: 200 valid JSON missing 'registered' → error" {
    setup_claim_state 1
    stub_post_json 200 '{"foo":1}'
    run claim_status --json
    [ "$status" -eq 2 ]
    [ "$(jqr "$output" '.result')" = 'error' ]
}

@test "claim status: present but unreadable secret → error, no probe" {
    if [[ "$(id -u)" -eq 0 ]]; then skip "root bypasses file permissions"; fi
    setup_claim_state 1
    chmod 000 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":true}'
    run claim_status --json
    [ "$status" -eq 2 ]
    [ "$(jqr "$output" '.result')" = 'error' ]
    [ ! -f "$PROBE_CALLS" ]
}

# --- human output -------------------------------------------------------

@test "claim status (human): claimed prints 'Claimed: yes'" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":true}'
    run claim_status
    [ "$status" -eq 0 ]
    [[ "$output" == *'Claimed: yes'* ]]
}

@test "claim status (human): unclaimed points at the claim page" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":false}'
    run claim_status
    [ "$status" -eq 0 ]
    [[ "$output" == *'Claimed: no'* ]]
    [[ "$output" == *'/feeder/claim'* ]]
}

# --- dispatch + usage ---------------------------------------------------

@test "claim status: --help exits 0 and prints usage" {
    run claim_status --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed claim status'* ]]
}

@test "dispatch_claim routes 'status' to claim_status" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":7,"owner_present":true}'
    run dispatch_claim status --json
    [ "$status" -eq 0 ]
    [ "$(jqr "$output" '.result')" = 'claimed' ]
}
