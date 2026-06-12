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

# Stub `post_json_bearer` to write a prepared response and return a
# chosen code. Defines the function in the current shell so the next
# call to claim_registration_status_line / status_probe_version uses it.
# DEV-427: /status migrated from post_json to post_json_bearer; the stub
# matches the new helper's 4-arg signature (response_file is $4).
stub_post_json() {
    # stub_post_json <http-status-code> <response-body-json>
    # On rc=99 sentinel, simulates network failure (curl rc != 0).
    local code="$1"
    local body="$2"
    eval "
post_json_bearer() {
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

@test "mlat_status_line: ActiveState=active + disabled geo_not_configured → 'disabled by config (location not set)'" {
    write_mlat_state disabled geo_not_configured
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'disabled by config (location not set)'* ]]
}

@test "mlat_status_line: ActiveState=active + disabled latitude_zero → 'disabled by config (LATITUDE=0)' (legacy state file)" {
    # Forward/backward compat: state files written by an older daemon
    # (which used the LATITUDE==0 sentinel) still render with a
    # recognizable detail when the operator looks at status after upgrade.
    write_mlat_state disabled latitude_zero
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'disabled by config (LATITUDE=0)'* ]]
}

@test "mlat_status_line: ActiveState=active + disabled longitude_zero → 'disabled by config (LONGITUDE=0)' (legacy state file)" {
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

@test "mlat_status_line: ActiveState=failed + exit 64 + misconfigured altitude_empty → actionable" {
    write_mlat_state misconfigured altitude_empty
    stub_systemctl_active_state failed 64
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'ALTITUDE is empty'* ]]
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

# --- mlat_status_line: privacy suffix folded into the running line ---
#
# Privacy was previously emitted on its own "MLAT name privacy" line by
# mlat_privacy_status_line. That standalone line was folded into
# mlat_status_line when decision=enabled and active_state=active, so the
# data-flow output stays compact (one line per concern).

@test "mlat_status_line: enabled + active + mlat_private=true → 'running (name: private)'" {
    write_mlat_state enabled ok true
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'running (name: private)'* ]]
}

@test "mlat_status_line: enabled + active + mlat_private=false → 'running (name: public)'" {
    write_mlat_state enabled ok false
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'running (name: public)'* ]]
}

@test "mlat_status_line: enabled + active + mlat_private missing → bare 'running' (no suffix)" {
    write_mlat_state enabled ok ''  # no mlat_private key
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'running'* ]]
    [[ "$output" != *'(name:'* ]]
}

@test "mlat_status_line: disabled + mlat_private=true → 'disabled by config' (no privacy suffix when disabled)" {
    # Privacy is irrelevant when MLAT is disabled — the daemon publishes
    # nothing — so the suffix must not appear.
    write_mlat_state disabled mlat_enabled_false true
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'disabled by config (MLAT_ENABLED=false)'* ]]
    [[ "$output" != *'(name:'* ]]
}

@test "mlat_status_line: enabled + activating + mlat_private=true → 'starting up' (no suffix mid-transition)" {
    # Suffix is only relevant when the daemon is fully running. During
    # activating/reloading we surface the transitional state instead.
    write_mlat_state enabled ok true
    stub_systemctl_active_state activating
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'starting up (activating)'* ]]
    [[ "$output" != *'(name:'* ]]
}

@test "mlat_status_line: enabled + active + unknown mlat_private value → 'running' + warn 'unknown value' (forward-compat)" {
    # An unrecognised mlat_private token (future schema) must not be
    # silently swallowed when the privacy suffix is folded into the
    # MLAT service line. _mlat_privacy_unknown_value surfaces it as a
    # separate CHECK so a forward-compat regression stays visible.
    write_mlat_state enabled ok futureschema
    stub_systemctl_active_state active
    status_init
    STATUS_OUTPUT_JSON=0
    run mlat_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'running'* ]]
    [[ "$output" != *'running (name:'* ]]
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'MLAT name privacy'* ]]
    [[ "$output" == *'unknown value: futureschema'* ]]
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

@test "receiver_status_line: sets STATUS_RECEIVER_INPUT_STATE for the activity check to consume" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    cat > "$STUB_DIR/nc" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    receiver_status_line >/dev/null
    [ "$STATUS_RECEIVER_INPUT_STATE" = "ok" ]
    [ "$STATUS_RECEIVER_INPUT_IP" = "127.0.0.1" ]
    [ "$STATUS_RECEIVER_INPUT_PORT" = "30005" ]
}

# --- receiver_activity_status_line ---
#
# Protocol-agnostic byte sniff. Any bytes within the sample window → ok.
# `head -c` early-exit (SIGPIPE on nc) and `timeout` rc=124 both produce
# non-zero pipelines by design; the function wraps in `set +o pipefail`
# and ignores the rc — $bytes is the only signal.

@test "receiver_activity_status_line: nc emits bytes → ok 'data flowing'" {
    cat > "$STUB_DIR/nc" <<'STUB'
#!/usr/bin/env bash
# Emit some Beast-shaped bytes (binary; non-printable is fine).
printf '\x1a\x32\xa1\xb2\xc3\xd4\xe5\xf6'
exit 0
STUB
    chmod +x "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='ok'
    STATUS_RECEIVER_INPUT_IP='127.0.0.1'
    STATUS_RECEIVER_INPUT_PORT='30005'
    run receiver_activity_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'Receiver activity'* ]]
    [[ "$output" == *'data flowing'* ]]
    [[ "$output" == *'8b in'* ]]
}

@test "receiver_activity_status_line: nc exits with no output → warn 'no data'" {
    cat > "$STUB_DIR/nc" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='ok'
    STATUS_RECEIVER_INPUT_IP='127.0.0.1'
    STATUS_RECEIVER_INPUT_PORT='30005'
    run receiver_activity_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'no data'* ]]
}

@test "receiver_activity_status_line: STATUS_RECEIVER_INPUT_STATE=fail → skipped (no line emitted)" {
    # Connection-level failure is already on the line above; the activity
    # check has nothing to add and must not emit a redundant line.
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='fail'
    STATUS_RECEIVER_INPUT_IP='127.0.0.1'
    STATUS_RECEIVER_INPUT_PORT='30005'
    run receiver_activity_status_line
    [ -z "$output" ]
}

@test "receiver_activity_status_line: STATUS_RECEIVER_INPUT_STATE=warn → skipped (malformed INPUT etc.)" {
    # `warn` covers malformed INPUT or nc-missing on the input line; the
    # parsed IP/PORT may be garbage. Running the activity probe against
    # garbage produces a misleading second "no data" line — skip instead.
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='warn'
    STATUS_RECEIVER_INPUT_IP='badvalue'
    STATUS_RECEIVER_INPUT_PORT='badvalue'
    run receiver_activity_status_line
    [ -z "$output" ]
}

@test "receiver_activity_status_line: INPUT IP/PORT unresolved → warn (defensive)" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='ok'
    STATUS_RECEIVER_INPUT_IP=''
    STATUS_RECEIVER_INPUT_PORT=''
    run receiver_activity_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'INPUT not resolved'* ]]
}

@test "receiver_activity_status_line: nc unavailable → warn 'nc unavailable'" {
    rm -f "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='ok'
    STATUS_RECEIVER_INPUT_IP='127.0.0.1'
    STATUS_RECEIVER_INPUT_PORT='30005'
    output="$(PATH="$STUB_DIR" receiver_activity_status_line)"
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'nc unavailable'* ]]
}

@test "receiver_activity_status_line: caller's pipefail state is preserved across the sample" {
    # The sample uses `timeout | nc | head | wc` which routinely fails
    # under pipefail (timeout exits 124, head SIGPIPEs nc); the function
    # toggles pipefail off internally and must restore the caller's
    # original setting. Verifying this protects the production path where
    # apl-feed.sh sets `set -euo pipefail`.
    cat > "$STUB_DIR/nc" <<'STUB'
#!/usr/bin/env bash
printf 'x'
exit 0
STUB
    chmod +x "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='ok'
    STATUS_RECEIVER_INPUT_IP='127.0.0.1'
    STATUS_RECEIVER_INPUT_PORT='30005'
    set -o pipefail
    receiver_activity_status_line >/dev/null
    [[ -o pipefail ]]
    set +o pipefail
}

@test "receiver_activity_status_line: pipefail-off caller stays pipefail-off" {
    cat > "$STUB_DIR/nc" <<'STUB'
#!/usr/bin/env bash
printf 'x'
exit 0
STUB
    chmod +x "$STUB_DIR/nc"
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_RECEIVER_INPUT_STATE='ok'
    STATUS_RECEIVER_INPUT_IP='127.0.0.1'
    STATUS_RECEIVER_INPUT_PORT='30005'
    set +o pipefail
    receiver_activity_status_line >/dev/null
    ! [[ -o pipefail ]]
}

# --- adsb_uplink_status_line ---

@test "adsb_uplink_status_line: ss output shows :30004 in peer column → ok" {
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port\n'
printf 'ESTAB 0 0 127.0.0.1:43530 78.46.234.18:30004\n'
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run adsb_uplink_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'ADS-B uplink'* ]]
    [[ "$output" == *'connected'* ]]
}

@test "adsb_uplink_status_line: ss output shows :64004 (failover) in peer column → ok" {
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port\n'
printf 'ESTAB 0 0 127.0.0.1:43530 78.46.234.19:64004\n'
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run adsb_uplink_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'connected'* ]]
}

@test "adsb_uplink_status_line: ss output shows ONLY :31090 (mlat) → warn (no ADS-B)" {
    # :31090 is the MLAT uplink; this check is ADS-B only. A MLAT-only
    # connection used to wrongly flip this check to ok and masked an
    # ADS-B-down state — the narrowed grep prevents that regression.
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port\n'
printf 'ESTAB 0 0 127.0.0.1:43530 78.46.234.18:31090\n'
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run adsb_uplink_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'no connection'* ]]
}

@test "adsb_uplink_status_line: ss output empty → warn" {
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run adsb_uplink_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'no connection'* ]]
}

@test "adsb_uplink_status_line: neither ss nor netstat available → warn" {
    rm -f "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    output="$(PATH="$ROOT_DIR/empty" adsb_uplink_status_line)"
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'ss/netstat unavailable'* ]]
}

@test "adsb_uplink_status_line: local listener on :30004 (peer port is different) → warn" {
    # A local process listening on :30004 puts that port in the LOCAL
    # column, peer port is unrelated. Old grep matched anywhere on the
    # line and false-positived; the peer-column parser must not.
    cat > "$STUB_DIR/ss" <<'STUB'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port\n'
printf 'ESTAB 0 0 127.0.0.1:30004 1.2.3.4:55555\n'
exit 0
STUB
    chmod +x "$STUB_DIR/ss"
    status_init
    STATUS_OUTPUT_JSON=0
    run adsb_uplink_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'no connection'* ]]
}

# Helper: hide ss from `command -v` so the netstat fallback branch is
# reachable in tests. Necessary because CI runners (and most dev boxes)
# have /usr/bin/ss preinstalled — rm'ing the STUB_DIR/ss stub isn't
# enough; the system ss is still on PATH. Defines a `command` function
# in the current shell that BATS `run` inherits into its subshell.
_hide_ss_from_command_v() {
    command() {
        if [[ "$1" = "-v" && "$2" = "ss" ]]; then
            return 1
        fi
        builtin command "$@"
    }
}

@test "adsb_uplink_status_line: netstat TIME_WAIT to :30004 → warn (only ESTABLISHED counts)" {
    _hide_ss_from_command_v
    cat > "$STUB_DIR/netstat" <<'STUB'
#!/usr/bin/env bash
printf 'Active Internet connections (w/o servers)\n'
printf 'Proto Recv-Q Send-Q Local-Address Foreign-Address State\n'
printf 'tcp 0 0 127.0.0.1:43530 78.46.234.18:30004 TIME_WAIT\n'
exit 0
STUB
    chmod +x "$STUB_DIR/netstat"
    status_init
    STATUS_OUTPUT_JSON=0
    run adsb_uplink_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'no connection'* ]]
}

@test "adsb_uplink_status_line: netstat ESTABLISHED to :30004 → ok" {
    _hide_ss_from_command_v
    cat > "$STUB_DIR/netstat" <<'STUB'
#!/usr/bin/env bash
printf 'Active Internet connections (w/o servers)\n'
printf 'Proto Recv-Q Send-Q Local-Address Foreign-Address State\n'
printf 'tcp 0 0 127.0.0.1:43530 78.46.234.18:30004 ESTABLISHED\n'
exit 0
STUB
    chmod +x "$STUB_DIR/netstat"
    status_init
    STATUS_OUTPUT_JSON=0
    run adsb_uplink_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'connected'* ]]
}

# --- server_reception_status_line ---
#
# Tier thresholds reflect the 5-min feeder_sync cron on the website
# side: ok ≤ 480 s, warn ≤ 1200 s, fail > 1200 s.

@test "server_reception_status_line: STATUS_LAST_SEEN_AT empty → not_seen warn with first-connect hint" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT=''
    run server_reception_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'not seen yet'* ]]
    [[ "$output" == *'first connect'* ]]
}

@test "server_reception_status_line: age 480 (ok boundary inclusive) → ok 'currently receiving'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS='480'
    STATUS_SERVER_RECEPTION_STATE=''
    run server_reception_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'currently receiving'* ]]
}

@test "server_reception_status_line: age 481 → warn 'lagging'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS='481'
    STATUS_SERVER_RECEPTION_STATE=''
    run server_reception_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'lagging'* ]]
}

@test "server_reception_status_line: age 1200 (warn boundary inclusive) → warn 'lagging'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS='1200'
    STATUS_SERVER_RECEPTION_STATE=''
    run server_reception_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'lagging'* ]]
}

@test "server_reception_status_line: age 1201 → fail 'not receiving'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS='1201'
    STATUS_SERVER_RECEPTION_STATE=''
    run server_reception_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'not receiving'* ]]
}

@test "server_reception_status_line: non-numeric age → warn 'unavailable'" {
    status_init
    STATUS_OUTPUT_JSON=0
    STATUS_LAST_SEEN_AT='2026-04-28T00:00:00Z'
    STATUS_LAST_SEEN_AGE_SECONDS=''
    STATUS_SERVER_RECEPTION_STATE=''
    run server_reception_status_line
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
    [[ "$output" == *'registered and claimed'* ]]
    # Version intentionally omitted from human output — it's internal
    # bookkeeping; the JSON path (.claim.version) keeps it for tooling.
    [[ "$output" != *'(v'* ]]
}

@test "claim_registration_status_line: 200 + registered:true + version + owner_present:false → ok 'not yet claimed'" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":false,"reset_until":null,"last_seen_at":null,"last_seen_age_seconds":null}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'not yet claimed'* ]]
    [[ "$output" != *'(v'* ]]
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

@test "claim_registration_status_line: 200 with last_seen_at key absent → no Server reception line" {
    # When the response omits last_seen_at entirely, json_has_key
    # returns false and the server-reception line is skipped. (When the
    # key is present but null, the line IS emitted as warn 'not seen
    # yet'.)
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" != *'Server reception'* ]]
}

@test "claim_registration_status_line: 200 with last_seen_at:null emits 'not seen yet' warn" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true,"last_seen_at":null,"last_seen_age_seconds":null}'
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    [[ "$output" == *'Server reception'* ]]
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
    WEBSITE_URL="http://127.0.0.1:$(cat "$PORT_FILE")"
    status_init
    STATUS_OUTPUT_JSON=0
    run claim_registration_status_line
    stop_python_mock
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'registered and claimed'* ]]
}

# --- config_sync_status_line (Remote config row) -------------------------

_seed_config_sync_sentinel() {
    # $1 (optional): a `touch -d` time spec for the mtime (default: now).
    local f="$ROOT_DIR/var/lib/airplanes-config-sync/config-sync-last-success"
    mkdir -p "$(dirname "$f")"
    if [[ -n "${1:-}" ]]; then
        touch -d "$1" "$f"
    else
        touch "$f"
    fi
}

@test "config_sync_status_line: REMOTE_CONFIG_ENABLED absent → OK 'off' (sentinel not consulted)" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    _seed_config_sync_sentinel '40 minutes ago'   # stale on purpose
    status_init
    STATUS_OUTPUT_JSON=0
    run config_sync_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'off (remote config not enabled)'* ]]
    # Off must short-circuit before the (stale) sentinel is read.
    [[ "$output" != *'last sync'* ]]
}

@test "config_sync_status_line: REMOTE_CONFIG_ENABLED=false → OK 'off'" {
    printf 'REMOTE_CONFIG_ENABLED=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    status_init
    STATUS_OUTPUT_JSON=0
    run config_sync_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'off (remote config not enabled)'* ]]
}

@test "config_sync_status_line: invalid REMOTE_CONFIG_ENABLED → FIX" {
    printf 'REMOTE_CONFIG_ENABLED=maybe\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    status_init
    STATUS_OUTPUT_JSON=0
    run config_sync_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'REMOTE_CONFIG_ENABLED=maybe invalid'* ]]
}

@test "config_sync_status_line: enabled + recent sync → OK 'last sync'" {
    printf 'REMOTE_CONFIG_ENABLED=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    _seed_config_sync_sentinel
    status_init
    STATUS_OUTPUT_JSON=0
    run config_sync_status_line
    [[ "$output" == *'OK'* ]]
    [[ "$output" == *'enabled, last sync'* ]]
}

@test "config_sync_status_line: enabled + stale sync (>30m) → CHECK '(stale)'" {
    printf 'REMOTE_CONFIG_ENABLED=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    _seed_config_sync_sentinel '40 minutes ago'
    status_init
    STATUS_OUTPUT_JSON=0
    run config_sync_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'(stale)'* ]]
}

@test "config_sync_status_line: enabled + no sentinel → CHECK 'no successful sync'" {
    printf 'REMOTE_CONFIG_ENABLED=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    status_init
    STATUS_OUTPUT_JSON=0
    run config_sync_status_line
    [[ "$output" == *'CHECK'* ]]
    [[ "$output" == *'no successful sync observed yet'* ]]
}

@test "config_sync_status_line: enabled + unit failed → FIX" {
    printf 'REMOTE_CONFIG_ENABLED=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    stub_systemctl_active_state failed 64
    status_init
    STATUS_OUTPUT_JSON=0
    run config_sync_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'unit failed'* ]]
}

@test "config_sync_status_line: JSON output carries config_sync block + schema_version 3" {
    printf 'REMOTE_CONFIG_ENABLED=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    _seed_config_sync_sentinel
    status_init
    STATUS_OUTPUT_JSON=1
    config_sync_status_line
    run status_finish
    [ "$(jq -r '.schema_version' <<< "$output")" = "3" ]
    [ "$(jq -r '.config_sync.remote_config' <<< "$output")" = "enabled" ]
    [ "$(jq -r '.config_sync.last_sync_age_seconds | type' <<< "$output")" = "number" ]
}

# --- backend endpoint brackets (non-default backends) ---

# Helper: write a feed daemon state file carrying the published
# effective-endpoint keys. write_feed_daemon_state <host> <port> <is_default>
write_feed_daemon_state() {
    mkdir -p "$ROOT_DIR/run/airplanes-feed"
    {
        printf 'schema_version=1\n'
        printf 'service=airplanes-feed\n'
        printf 'state=enabled\n'
        printf 'reason=ok\n'
        printf 'target_host=%s\n' "$1"
        printf 'target_port=%s\n' "$2"
        printf 'target_is_default=%s\n' "$3"
    } > "$ROOT_DIR/run/airplanes-feed/state"
}

# Helper: like write_mlat_state but with the endpoint keys.
# write_mlat_state_with_server <decision> <reason> <server> <is_default>
write_mlat_state_with_server() {
    mkdir -p "$ROOT_DIR/run/airplanes-mlat"
    {
        printf 'schema_version=1\n'
        printf 'service=airplanes-mlat\n'
        printf 'state=%s\n' "$1"
        printf 'reason=%s\n' "$2"
        printf 'mlat_server=%s\n' "$3"
        printf 'mlat_server_is_default=%s\n' "$4"
    } > "$ROOT_DIR/run/airplanes-mlat/state"
}

@test "feed target suffix: non-default host renders bracket" {
    write_feed_daemon_state feed.airplanes.test 30004 false
    status_init
    _derive_backend_endpoints
    [ "$(_feed_target_suffix)" = " [feed.airplanes.test]" ]
}

@test "feed target suffix: default endpoint renders nothing" {
    write_feed_daemon_state feed.airplanes.live 30004 true
    status_init
    _derive_backend_endpoints
    [ -z "$(_feed_target_suffix)" ]
}

@test "feed target suffix: non-default port renders host:port" {
    write_feed_daemon_state feed.airplanes.live 9999 false
    status_init
    _derive_backend_endpoints
    [ "$(_feed_target_suffix)" = " [feed.airplanes.live:9999]" ]
}

@test "feed target suffix: present-but-empty keys render invalid TARGET" {
    write_feed_daemon_state '' '' ''
    status_init
    _derive_backend_endpoints
    [ "$(_feed_target_suffix)" = " [invalid TARGET]" ]
}

@test "feed target suffix: no state file renders nothing" {
    status_init
    _derive_backend_endpoints
    [ -z "$(_feed_target_suffix)" ]
}

@test "service_status_line: running Feed service carries the backend bracket" {
    write_feed_daemon_state feed.airplanes.test 30004 false
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 0 ;;
    is-enabled) printf 'enabled\n'; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    status_init
    _derive_backend_endpoints
    run service_status_line airplanes-feed 'Feed service' "$(_feed_target_suffix)"
    [[ "$output" == *'running [feed.airplanes.test]'* ]]
}

@test "service_status_line: not-running Feed service still carries the bracket" {
    write_feed_daemon_state feed.airplanes.test 30004 false
    status_init
    _derive_backend_endpoints
    run service_status_line airplanes-feed 'Feed service' "$(_feed_target_suffix)"
    [[ "$output" == *'not running [feed.airplanes.test]'* ]]
}

@test "mlat_status_line: running line carries a non-default MLATSERVER bracket" {
    write_mlat_state_with_server enabled ok feed.airplanes.test:31090 false
    stub_systemctl_active_state active
    status_init
    _derive_backend_endpoints
    run mlat_status_line
    [[ "$output" == *'running'* ]]
    [[ "$output" == *'[feed.airplanes.test:31090]'* ]]
}

@test "mlat_status_line: default MLATSERVER renders no bracket" {
    write_mlat_state_with_server enabled ok feed.airplanes.live:31090 true
    stub_systemctl_active_state active
    status_init
    _derive_backend_endpoints
    run mlat_status_line
    [[ "$output" == *'running'* ]]
    [[ "$output" != *'['* ]]
}

@test "mlat_status_line: failed unit still carries the MLATSERVER bracket" {
    # RuntimeDirectoryPreserve keeps the state file across the failure,
    # so the endpoint stays visible while the service is down.
    write_mlat_state_with_server enabled ok feed.airplanes.test:31090 false
    stub_systemctl_active_state failed 1
    status_init
    _derive_backend_endpoints
    run mlat_status_line
    [[ "$output" == *'FIX'* ]]
    [[ "$output" == *'[feed.airplanes.test:31090]'* ]]
}

@test "website suffix: non-default WEBSITE_HOST renders on the Website claim line" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true,"reset_until":null,"last_seen_at":null,"last_seen_age_seconds":null}'
    WEBSITE_HOST="web.dev.airplanes.live"
    status_init
    _derive_backend_endpoints
    run claim_registration_status_line
    [[ "$output" == *'registered and claimed [web.dev.airplanes.live]'* ]]
}

@test "website suffix: default WEBSITE_HOST renders no bracket" {
    setup_claim_state 1
    stub_post_json 200 '{"registered":true,"version":5,"owner_present":true,"reset_until":null,"last_seen_at":null,"last_seen_age_seconds":null}'
    WEBSITE_HOST="airplanes.live"
    status_init
    _derive_backend_endpoints
    run claim_registration_status_line
    [[ "$output" == *'registered and claimed'* ]]
    [[ "$output" != *'['* ]]
}

@test "website suffix: unreachable probe names the overridden backend" {
    setup_claim_state 1
    stub_post_json 99 ''
    WEBSITE_HOST="web.dev.airplanes.live"
    status_init
    _derive_backend_endpoints
    run claim_registration_status_line
    [[ "$output" == *'unreachable'* ]]
    [[ "$output" == *'[web.dev.airplanes.live]'* ]]
}

@test "status --json: backend object carries non-default endpoint fields" {
    write_feed_daemon_state feed.airplanes.test 9999 false
    write_mlat_state_with_server enabled ok feed.airplanes.test:31090 false
    WEBSITE_HOST="web.dev.airplanes.live"
    status_init
    _derive_backend_endpoints
    STATUS_OUTPUT_JSON=1
    run status_finish
    [ "$(jq -r '.backend.feed_target_host' <<< "$output")" = "feed.airplanes.test" ]
    [ "$(jq -r '.backend.feed_target_port' <<< "$output")" = "9999" ]
    [ "$(jq -r '.backend.feed_target_port | type' <<< "$output")" = "number" ]
    [ "$(jq -r '.backend.feed_target_is_default' <<< "$output")" = "false" ]
    [ "$(jq -r '.backend.mlat_server' <<< "$output")" = "feed.airplanes.test:31090" ]
    [ "$(jq -r '.backend.mlat_server_is_default' <<< "$output")" = "false" ]
    [ "$(jq -r '.backend.website_host' <<< "$output")" = "web.dev.airplanes.live" ]
    [ "$(jq -r '.backend.website_is_default' <<< "$output")" = "false" ]
}

@test "status --json: backend object is null/default without daemon state" {
    WEBSITE_HOST="airplanes.live"
    status_init
    _derive_backend_endpoints
    STATUS_OUTPUT_JSON=1
    run status_finish
    [ "$(jq -r '.backend.feed_target_host' <<< "$output")" = "null" ]
    [ "$(jq -r '.backend.feed_target_is_default' <<< "$output")" = "null" ]
    [ "$(jq -r '.backend.mlat_server' <<< "$output")" = "null" ]
    [ "$(jq -r '.backend.website_host' <<< "$output")" = "airplanes.live" ]
    [ "$(jq -r '.backend.website_is_default' <<< "$output")" = "true" ]
}
