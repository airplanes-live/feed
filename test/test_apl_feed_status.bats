#!/usr/bin/env bats

# Per-module unit tests for scripts/apl-feed/status.sh.
#
# Most cases stub `post_json` directly to write a prepared response
# file and return a chosen HTTP code — avoids per-test Python server
# startup. One claim_registration_status_line case exercises the
# real Python mock to keep the stub honest.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    STUB_DIR="$ROOT_DIR/bin"
    mkdir -p "$TMPDIR" "$STUB_DIR" \
        "$ROOT_DIR/etc/airplanes" \
        "$ROOT_DIR/usr/local/share/airplanes"
    export TMPDIR
    APL_FEED_SECRET_OWNER="$(id -un)"
    APL_FEED_SECRET_GROUP="$(id -gn)"
    export APL_FEED_SECRET_OWNER APL_FEED_SECRET_GROUP

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/http.sh
    source "$LIB_DIR/http.sh"
    # shellcheck source=../scripts/apl-feed/status.sh
    source "$LIB_DIR/status.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    # Default stubs: every external command status.sh might call.
    # Individual tests override by writing fresh stubs.
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 3 ;;     # default: not active
    is-enabled) printf 'disabled\n'; exit 1 ;;
esac
exit 0
STUB
    cat > "$STUB_DIR/nc" <<'STUB'
#!/usr/bin/env bash
exit 1                       # default: not reachable
STUB
    cat > "$STUB_DIR/timeout" <<'STUB'
#!/usr/bin/env bash
shift                        # drop seconds arg, exec rest
exec "$@"
STUB
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
exit 0                       # default: empty output
STUB
    chmod +x "$STUB_DIR"/*
    PATH="$STUB_DIR:$PATH"
    export PATH

    UUID='11111111-2222-3333-4444-555555555555'
    SECRET='ABCDEFGHIJKLMNOP'
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Stub `post_json` to write a prepared response and return a chosen
# code. Defines the function in the current shell so the next call to
# claim_registration_status_line / status_probe_version uses it.
stub_post_json() {
    # stub_post_json <http-status-code> <response-body-json>
    # On rc=99 sentinel, simulates network failure (curl rc != 0).
    local code="$1"
    local body="$2"
    eval "
post_json() {
    local response_file=\"\$3\"
    if [[ '$code' == '99' ]]; then
        return 7
    fi
    printf '%s' '$body' > \"\$response_file\"
    printf '%s' '$code'
    return 0
}
"
}

# --- status_init / status_finish / status_overall ---

@test "status_init: zeroes counters" {
    STATUS_FAIL_COUNT=5
    STATUS_WARN_COUNT=3
    status_init
    [ "$STATUS_FAIL_COUNT" -eq 0 ]
    [ "$STATUS_WARN_COUNT" -eq 0 ]
    [ -n "$STATUS_CHECKS_FILE" ]
    [ -f "$STATUS_CHECKS_FILE" ]
}

@test "status_overall: 'ok' when no warns/fails" {
    STATUS_WARN_COUNT=0
    STATUS_FAIL_COUNT=0
    run status_overall
    [ "$status" -eq 0 ]
    [ "$output" = 'ok' ]
}

@test "status_overall: 'warn' when ≥1 warn and 0 fails" {
    STATUS_WARN_COUNT=1
    STATUS_FAIL_COUNT=0
    run status_overall
    [ "$output" = 'warn' ]
}

@test "status_overall: 'fail' dominates 'warn'" {
    STATUS_WARN_COUNT=2
    STATUS_FAIL_COUNT=1
    run status_overall
    [ "$output" = 'fail' ]
}

# --- status_line ---

@test "status_line: ok increments neither counter, prints OK" {
    status_init
    STATUS_OUTPUT_JSON=0
    run status_line ok 'Test' 'detail'
    [ "$status" -eq 0 ]
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'Test'* ]]
    [[ "$output" == *'detail'* ]]
}

@test "status_line: warn increments STATUS_WARN_COUNT" {
    status_init
    STATUS_OUTPUT_JSON=0
    status_line warn 'Test' 'detail' >/dev/null
    [ "$STATUS_WARN_COUNT" -eq 1 ]
    [ "$STATUS_FAIL_COUNT" -eq 0 ]
}

@test "status_line: fail increments STATUS_FAIL_COUNT" {
    status_init
    STATUS_OUTPUT_JSON=0
    status_line fail 'Test' 'detail' >/dev/null
    [ "$STATUS_FAIL_COUNT" -eq 1 ]
    [ "$STATUS_WARN_COUNT" -eq 0 ]
}

@test "status_line: appends JSON line to STATUS_CHECKS_FILE" {
    status_init
    STATUS_OUTPUT_JSON=0
    status_line ok 'Feeder ID' 'present' >/dev/null
    line="$(cat "$STATUS_CHECKS_FILE")"
    [ "$(printf '%s' "$line" | jq -r '.state')" = 'ok' ]
    [ "$(printf '%s' "$line" | jq -r '.label')" = 'Feeder ID' ]
    [ "$(printf '%s' "$line" | jq -r '.detail')" = 'present' ]
}

@test "status_line: JSON output mode suppresses plain text but still records JSON" {
    status_init
    STATUS_OUTPUT_JSON=1
    run status_line ok 'Test' 'detail'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    line="$(cat "$STATUS_CHECKS_FILE")"
    [ "$(printf '%s' "$line" | jq -r '.state')" = 'ok' ]
}

# --- service_status_line ---

@test "service_status_line: no systemctl on PATH warns" {
    status_init
    STATUS_OUTPUT_JSON=0
    output="$(PATH="$ROOT_DIR/empty" service_status_line airplanes-feed 'Feed service')"
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'systemctl unavailable'* ]]
}

@test "service_status_line: is-active --quiet 0 → ok 'running'" {
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 0 ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    status_init
    STATUS_OUTPUT_JSON=0
    run service_status_line airplanes-feed 'Feed service'
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'running'* ]]
}

@test "service_status_line: is-enabled = masked → fail 'masked'" {
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 3 ;;
    is-enabled) printf 'masked\n'; exit 1 ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    status_init
    STATUS_OUTPUT_JSON=0
    run service_status_line airplanes-feed 'Feed service'
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'masked'* ]]
}

@test "service_status_line: default (inactive, not masked) → fail 'not running'" {
    status_init
    STATUS_OUTPUT_JSON=0
    run service_status_line airplanes-feed 'Feed service'
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'not running'* ]]
}

# --- mlat_status_line: state-file-driven (replaces old mlat_disabled_by_config) ---

# Helper: write a state file under the test root for the MLAT daemon.
write_mlat_state() {
    # write_mlat_state <decision> <reason> [<mlat_private>]
    local decision="$1"
    local reason="$2"
    local mlat_private="${3:-}"
    mkdir -p "$ROOT_DIR/run/airplanes-mlat"
    {
        printf 'schema_version=1\n'
        printf 'service=airplanes-mlat\n'
        printf 'state=%s\n' "$decision"
        printf 'reason=%s\n' "$reason"
        if [[ -n "$mlat_private" ]]; then
            printf 'mlat_private=%s\n' "$mlat_private"
        fi
    } > "$ROOT_DIR/run/airplanes-mlat/state"
}

# Helper: stub systemctl to return a chosen ActiveState / ExecMainStatus /
# is-enabled. Real call shapes:
#   systemctl show --property=ActiveState --value <unit>     (4 args)
#   systemctl show --property=ExecMainStatus --value <unit>  (4 args)
#   systemctl is-enabled <unit>                              (2 args)
#   systemctl is-active --quiet <unit>                       (3 args)
stub_systemctl_active_state() {
    local active_state="$1"
    local exec_main_status="${2:-0}"
    local is_enabled_value="${3:-enabled}"
    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
case "\$1 \$2 \$3" in
    "show --property=ActiveState --value") shift 3; printf '%s\n' '$active_state'; exit 0 ;;
    "show --property=ExecMainStatus --value") shift 3; printf '%s\n' '$exec_main_status'; exit 0 ;;
esac
case "\$1" in
    is-enabled) shift; printf '%s\n' '$is_enabled_value'; exit 0 ;;
    is-active) [[ '$active_state' == 'active' ]] && exit 0 || exit 3 ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
}

@test "mlat_status_line: ActiveState=active + decision=enabled → OK running" {
    write_mlat_state enabled ok
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'running'* ]]
}

@test "mlat_status_line: ActiveState=active + disabled mlat_enabled_false → 'disabled by config (MLAT_ENABLED=false)'" {
    write_mlat_state disabled mlat_enabled_false
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'disabled by config (MLAT_ENABLED=false)'* ]]
}

@test "mlat_status_line: ActiveState=active + disabled latitude_zero → 'disabled by config (LATITUDE=0)'" {
    write_mlat_state disabled latitude_zero
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'disabled by config (LATITUDE=0)'* ]]
}

@test "mlat_status_line: ActiveState=active + disabled longitude_zero → 'disabled by config (LONGITUDE=0)'" {
    write_mlat_state disabled longitude_zero
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'disabled by config (LONGITUDE=0)'* ]]
}

@test "mlat_status_line: ActiveState=failed + exit 64 + misconfigured mlat_private_invalid → actionable" {
    write_mlat_state misconfigured mlat_private_invalid
    stub_systemctl_active_state failed 64
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *"MLAT_PRIVATE must be 'true' or 'false'"* ]]
}

@test "mlat_status_line: ActiveState=activating + enabled → 'starting up'" {
    write_mlat_state enabled ok
    stub_systemctl_active_state activating
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'starting up (activating)'* ]]
}

# Load-bearing case: misconfig surface is visible continuously across the
# Restart=always cycle, not just during the microsecond active window.
@test "mlat_status_line: ActiveState=activating + misconfigured → still surfaces the actionable message" {
    write_mlat_state misconfigured mlat_private_invalid
    stub_systemctl_active_state activating
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *"MLAT_PRIVATE must be 'true' or 'false'"* ]]
}

@test "mlat_status_line: ActiveState=failed + exit 64 + state file present → surfaces misconfig reason" {
    write_mlat_state misconfigured mlat_private_invalid
    stub_systemctl_active_state failed 64
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *"MLAT_PRIVATE must be 'true' or 'false'"* ]]
}

@test "mlat_status_line: ActiveState=failed + exit 64 + no state file → generic 'check feed.env MLAT config'" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    stub_systemctl_active_state failed 64
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'failed (exit 64'* ]]
}

@test "mlat_status_line: ActiveState=failed + exit other → 'failed (exit X)'" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    stub_systemctl_active_state failed 1
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'failed (exit 1)'* ]]
}

@test "mlat_status_line: ActiveState=inactive + is-enabled=enabled → 'not running'" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    stub_systemctl_active_state inactive 0 enabled
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'not running'* ]]
}

@test "mlat_status_line: ActiveState=inactive + is-enabled=masked → 'masked'" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    stub_systemctl_active_state inactive 0 masked
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'masked'* ]]
}

@test "mlat_status_line: ActiveState=deactivating → 'not running'" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    stub_systemctl_active_state deactivating
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'not running'* ]]
}

@test "mlat_status_line: ActiveState=active + no state file → degraded 'running' fallback" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'running'* ]]
}

@test "mlat_status_line: ActiveState=activating + no state file → 'starting up'" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    stub_systemctl_active_state activating
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'starting up (activating)'* ]]
}

# --root integration: catches source-time vs runtime path mismatches that
# unit-testing mlat_status_line in isolation doesn't.
@test "mlat_status_line --root: reads state file under the redirected root" {
    write_mlat_state disabled mlat_enabled_false
    stub_systemctl_active_state active
    # ROOT was set in setup() to $ROOT_DIR; verify the function honors it.
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [ "$status" -eq 0 ]
    [[ "$output" == *'disabled by config (MLAT_ENABLED=false)'* ]]
}

# --- mlat_privacy_status_line: state-file-driven privacy posture ---

@test "mlat_privacy_status_line: mlat_private=true → OK 'private' line" {
    write_mlat_state enabled ok true
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_privacy_status_line
    [ "$status" -eq 0 ]
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'MLAT name privacy'* ]]
    [[ "$output" == *'private'* ]]
    [[ "$output" == *'name hidden'* ]]
}

@test "mlat_privacy_status_line: mlat_private=false → OK 'public' line" {
    write_mlat_state enabled ok false
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_privacy_status_line
    [ "$status" -eq 0 ]
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'MLAT name privacy'* ]]
    [[ "$output" == *'public'* ]]
    [[ "$output" == *'name shown'* ]]
}

@test "mlat_privacy_status_line: state file absent → no line emitted (silent skip)" {
    rm -rf "$ROOT_DIR/run/airplanes-mlat"
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_privacy_status_line
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "mlat_privacy_status_line: state file lacks mlat_private key → silent skip" {
    write_mlat_state enabled ok ''  # no mlat_private key written
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_privacy_status_line
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "mlat_privacy_status_line: unknown value → warn (forward-compat)" {
    write_mlat_state enabled ok futureschema
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_privacy_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'unknown value'* ]]
    [[ "$output" == *'futureschema'* ]]
}

# --- receiver_status_line ---

@test "receiver_status_line: default INPUT (no env), nc fails → fail" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    status_init
    STATUS_OUTPUT_JSON=0
    run receiver_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'127.0.0.1:30005'* ]]
}

@test "receiver_status_line: malformed INPUT (no colon) warns" {
    printf 'INPUT="badvalue"\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    status_init
    STATUS_OUTPUT_JSON=0
    run receiver_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'could not parse INPUT'* ]]
}

@test "receiver_status_line: no nc on PATH warns" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    rm -f "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    # Restrict PATH to stubs only so the system /usr/bin/nc isn't found.
    output="$(PATH="$STUB_DIR" receiver_status_line)"
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'nc unavailable'* ]]
}

@test "receiver_status_line: nc exit 0 → ok 'connected'" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    cat > "$STUB_DIR/nc" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    run receiver_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'connected'* ]]
}

@test "receiver_status_line: nc exit 1 → fail 'no data source reachable'" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    status_init
    STATUS_OUTPUT_JSON=0
    run receiver_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'no data source reachable'* ]]
}

# --- airplanes_link_status_line ---

@test "airplanes_link_status_line: ss output shows :30004 → ok" {
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
printf 'ESTAB 0 0 127.0.0.1:43530 78.46.234.18:30004 \n'
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run airplanes_link_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'connected'* ]]
}

@test "airplanes_link_status_line: ss output shows :31090 → ok (mlat)" {
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
printf 'ESTAB 0 0 127.0.0.1:43530 78.46.234.18:31090 \n'
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run airplanes_link_status_line
    [[ "$output" == *'OK'* ]]
}

@test "airplanes_link_status_line: ss output empty → warn" {
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run airplanes_link_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'no connection'* ]]
}

@test "airplanes_link_status_line: neither ss nor netstat available → warn" {
    rm -f "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    output="$(PATH="$ROOT_DIR/empty" airplanes_link_status_line)"
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'ss/netstat unavailable'* ]]
}

# --- website_feed_status_line ---

@test "website_feed_status_line: STATUS_LAST_SEEN_AT empty → not_seen warn" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT=''
    run website_feed_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'not seen yet'* ]]
}

@test "website_feed_status_line: age 900 (boundary inclusive) → ok 'recent'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS='900'
    STATUS_WEBSITE_FEED_STATE=''
    run website_feed_status_line
    [[ "$output" == *'OK'* ]]
}

@test "website_feed_status_line: age 901 (boundary exclusive) → warn 'stale'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS='901'
    STATUS_WEBSITE_FEED_STATE=''
    run website_feed_status_line
    [[ "$output" == *'CHECK'* ]]
}

@test "website_feed_status_line: non-numeric age → warn 'unavailable'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS=''
    STATUS_WEBSITE_FEED_STATE=''
    run website_feed_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'unavailable'* ]]
}

# --- claim_registration_status_line (post_json stubbed per case) ---

setup_claim_state() {
    # setup_claim_state <write-secret?>
    local write_secret="${1:-1}"
    printf '%s\n' "$UUID" > "$ROOT_DIR/etc/airplanes/feeder-id"
    if (( write_secret )); then
        printf '%s\n' "$SECRET" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
        chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    fi
}

@test "claim_registration_status_line: no UUID → fail 'missing or invalid'" {
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'missing or invalid'* ]]
}

@test "claim_registration_status_line: UUID + no secret → warn 'not present'" {
    setup_claim_state 0
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'not present'* ]]
}

@test "claim_registration_status_line: UUID + unreadable secret → warn 'not readable'" {
    setup_claim_state 1
    chmod 0000 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"   # restore for teardown
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'not readable'* ]]
}

@test "claim_registration_status_line: 200 + registered:true + version + owner_present:true → ok 'registered and claimed'" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true,"reset_until":null,"last_seen_at":null,"last_seen_age_seconds":null}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'registered and claimed (v5)'* ]]
}

@test "claim_registration_status_line: 200 + registered:true + version + owner_present:false → ok 'not yet claimed'" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":false,"reset_until":null,"last_seen_at":null,"last_seen_age_seconds":null}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'not yet claimed (v5)'* ]]
}

@test "claim_registration_status_line: 200 + registered:true + missing version → warn 'did not authenticate'" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"owner_present":true}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'did not authenticate'* ]]
}

@test "claim_registration_status_line: 200 + registered:false → warn 'not registered'" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":false}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'not registered'* ]]
}

@test "claim_registration_status_line: 200 with last_seen_at key absent → no website_feed line" {
    # When the response omits last_seen_at entirely, json_has_key
    # returns false and the website_feed line is skipped. (When the
    # key is present but null, the line IS emitted as warn 'not seen
    # yet' — see status.sh:271-277.)
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" != *'Website feed'* ]]
}

@test "claim_registration_status_line: 200 with last_seen_at:null emits 'not seen yet' warn" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true,"last_seen_at":null,"last_seen_age_seconds":null}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'Website feed'* ]]
    [[ "$output" == *'not seen yet'* ]]
}

@test "claim_registration_status_line: pending rotation file present adds warn line" {
    setup_claim_state 1
    : > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true,"last_seen_at":null,"last_seen_age_seconds":null}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'pending rotation file exists'* ]]
}

@test "claim_registration_status_line: 423 → fail 'blocked'" {
    setup_claim_state 1
    stub_post_json 423 '{"error":"feeder_blocked"}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'FIX'* ]]
}

@test "claim_registration_status_line: 429 → warn 'rate-limited'" {
    setup_claim_state 1
    stub_post_json 429 '{"error":"rate_limited"}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'rate-limited'* ]]
}

@test "claim_registration_status_line: 503 → warn 'unexpected HTTP 503'" {
    setup_claim_state 1
    stub_post_json 503 '{"error":"upstream_down"}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'unexpected HTTP 503'* ]]
}

@test "claim_registration_status_line: network failure → warn 'unreachable'" {
    setup_claim_state 1
    stub_post_json 99 ''
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'unreachable'* ]]
}

# Integration sanity check: real Python mock, stub_post_json out of
# the way. Keeps the per-test stub honest about post_json's contract.
start_python_mock() {
    local code="$1" body="$2"
    PORT_FILE="$(mktemp)"
    PID_FILE="$(mktemp)"
    python3 - "$PORT_FILE" "$code" "$body" <<'PY' &
import http.server, sys
port_file, status, body = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a, **kw): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
PY
    echo $! > "$PID_FILE"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$PORT_FILE" ]] && return 0
        sleep 0.1
    done
    return 1
}

stop_python_mock() {
    [[ -f "$PID_FILE" ]] || return 0
    local pid
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null || true
    rm -f "$PORT_FILE" "$PID_FILE"
}

@test "claim_registration_status_line: integration with real Python mock (200 ok)" {
    setup_claim_state 1
    start_python_mock 200 '{"registered":true,"version":5,"owner_present":true,"reset_until":null,"last_seen_at":null,"last_seen_age_seconds":null}'
    SERVER_URL="http://127.0.0.1:$(cat "$PORT_FILE")"
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    stop_python_mock
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'registered and claimed (v5)'* ]]
}
