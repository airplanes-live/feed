#!/usr/bin/env bats
# Tests for apl-feed claim register. Each test starts an inline Python
# HTTP server bound on 127.0.0.1:0 (kernel-assigned port) so parallel or
# stale runs don't collide.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/apl-feed.sh"
    CONTRACT="$BATS_TEST_DIRNAME/contracts/feeder-api-v1.json"
    ROOT_DIR="$(mktemp -d)"
    mkdir -p "$ROOT_DIR/etc/airplanes"
    echo "11111111-2222-3333-4444-555555555555" > "$ROOT_DIR/etc/airplanes/feeder-id"
    MOCK_RESP_FILE="$(mktemp)"
    MOCK_PORT_FILE="$(mktemp)"
    MOCK_PID_FILE="$(mktemp)"
}

teardown() {
    stop_mock_server || true
    rm -rf "$ROOT_DIR"
    rm -f "$MOCK_RESP_FILE" "$MOCK_PORT_FILE" "$MOCK_PID_FILE"
}

# Inline mock HTTP server. Reads its (status, body) response from
# $MOCK_RESP_FILE on each request, so a test can sequence responses by
# rewriting the file between polls. For one-shot tests we just write once
# before starting the server.
start_mock_server() {
    local port_file="$MOCK_PORT_FILE"
    local resp_file="$MOCK_RESP_FILE"
    local pid_file="$MOCK_PID_FILE"
    python3 - "$port_file" "$resp_file" <<'PY' &
import http.server, json, sys
port_file, resp_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        with open(resp_file) as f:
            spec = json.load(f)
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(spec["status"])
        ct = spec.get("content_type", "application/json")
        self.send_header("Content-Type", ct)
        self.end_headers()
        body = spec.get("body", {})
        out = body if isinstance(body, str) else json.dumps(body)
        self.wfile.write(out.encode())
    def log_message(self, *a, **kw): pass

s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
PY
    echo $! > "$pid_file"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$port_file" ]] && return 0
        sleep 0.1
    done
    return 1
}

stop_mock_server() {
    [[ -f "$MOCK_PID_FILE" ]] || return 0
    local pid
    pid="$(cat "$MOCK_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
}

write_response() {
    # write_response STATUS BODY_JSON [CONTENT_TYPE]
    local status="$1"
    local body="$2"
    local ct="${3:-application/json}"
    python3 -c "import json,sys; print(json.dumps({'status': int(sys.argv[1]), 'body': sys.argv[2], 'content_type': sys.argv[3]}))" \
        "$status" "$body" "$ct" > "$MOCK_RESP_FILE"
}

write_contract_response() {
    local section="$1"
    local name="$2"
    local status body
    status="$(jq -r --arg section "$section" --arg name "$name" '.[$section][$name].response.status' "$CONTRACT")"
    body="$(jq -c --arg section "$section" --arg name "$name" '.[$section][$name].response.body' "$CONTRACT")"
    write_response "$status" "$body"
}

mock_url() {
    echo "http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
}

@test "shows usage on --help" {
    run "$SCRIPT" claim register --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "defaults server URL when --server-url missing" {
    run "$SCRIPT" claim register --root "$ROOT_DIR" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ "https://airplanes.live/api/feeders/secret" ]]
}

@test "reads existing UUID from --root in --dry-run" {
    run timeout 2 "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://127.0.0.1:1" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ "11111111-2222-3333-4444-555555555555" ]]
}

@test "fails when no Feeder ID file exists at --root" {
    rm "$ROOT_DIR/etc/airplanes/feeder-id"
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "http://127.0.0.1:1" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Feeder ID" ]]
}

@test "rejects malformed Feeder ID" {
    echo "not-a-uuid" > "$ROOT_DIR/etc/airplanes/feeder-id"
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "http://127.0.0.1:1" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Feeder ID" || "$output" =~ "format" ]]
}

@test "reads UUID from legacy local path as fallback" {
    rm "$ROOT_DIR/etc/airplanes/feeder-id"
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes"
    echo "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"
    run timeout 2 "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://127.0.0.1:1" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]]
}

@test "reads UUID from /boot/airplanes-uuid as fallback" {
    rm "$ROOT_DIR/etc/airplanes/feeder-id"
    mkdir -p "$ROOT_DIR/boot"
    echo "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "$ROOT_DIR/boot/airplanes-uuid"
    run timeout 2 "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://127.0.0.1:1" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]]
}


# --- Secret generation ----------------------------------------------------

@test "secret is 16 chars, A-Z + 0-9 only" {
    run timeout 2 "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://127.0.0.1:1" --dry-run
    [ "$status" -eq 0 ]
    secret=$(echo "$output" | grep -E '^SECRET: ' | awk '{print $2}')
    [ -n "$secret" ]
    [ "${#secret}" -eq 16 ]
    [[ "$secret" =~ ^[A-Z0-9]{16}$ ]]
}

@test "two consecutive generations produce different secrets" {
    s1=$(timeout 2 "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://127.0.0.1:1" --dry-run \
        | grep -E '^SECRET: ' | awk '{print $2}')
    s2=$(timeout 2 "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://127.0.0.1:1" --dry-run \
        | grep -E '^SECRET: ' | awk '{print $2}')
    [ -n "$s1" ]
    [ -n "$s2" ]
    [ "$s1" != "$s2" ]
}


# --- POST + JSON-body response dispatch -----------------------------------

@test "201 success exits 0 and prints SUCCESS" {
    write_contract_response secret create_success
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SUCCESS" ]]
}

@test "200 NOOP_REPLAY exits 0 (treated as success)" {
    write_contract_response secret noop_replay
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SUCCESS" ]]
}

@test "409 legacy_unclaimed exits 4 (reinstall flow)" {
    write_contract_response secret legacy_unclaimed
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 4 ]
}

@test "409 rotation_rejected exits 1" {
    write_contract_response secret rotation_rejected
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 1 ]
}

@test "423 feeder_blocked exits 1 (terminal — no retry, fast)" {
    write_contract_response secret feeder_blocked
    start_mock_server
    local start_ts; start_ts=$(date +%s)
    run timeout 5 "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    local elapsed=$(( $(date +%s) - start_ts ))
    [ "$status" -eq 1 ]
    [ "$elapsed" -lt 3 ]
}

@test "400 bad request exits 1" {
    write_contract_response secret invalid_claim_secret
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 1 ]
}

@test "non-JSON 404 exits 1 (endpoint disabled / wrong URL)" {
    write_response 404 '<html>Not Found</html>' 'text/html'
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 1 ]
}

@test "network unreachable (RFC 2606 .invalid) exits 2" {
    run "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://nonexistent-host-deliberately-broken.invalid" \
        --max-retry-time 5
    [ "$status" -eq 2 ]
}


# --- Atomic persistence + idempotent reuse --------------------------------

@test "201 success persists secret atomically (mode 0600, .pending cleaned)" {
    write_contract_response secret create_success
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 0 ]
    local final="$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    [ -f "$final" ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
    local persisted; persisted="$(cat "$final")"
    [ "${#persisted}" -eq 16 ]
    [[ "$persisted" =~ ^[A-Z0-9]{16}$ ]]
    local mode; mode="$(stat -c '%a' "$final")"
    [ "$mode" = "600" ]
}

@test "writes pending file before first POST so crash mid-POST recovers" {
    # Use a non-routable address so the POST hangs/fails, but pending was
    # written first and survives.
    run timeout 4 "$SCRIPT" claim register --root "$ROOT_DIR" \
        --server-url "http://127.0.0.1:1" \
        --max-retry-time 1
    # Either curl-rc network-error (exit 2) or rate-limit-cap (exit 3).
    [ "$status" -eq 2 ] || [ "$status" -eq 3 ]
    # The pending file must exist because we wrote it pre-POST.
    [ -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
    # Final must NOT exist (POST didn't succeed).
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
}

@test "existing feeder-claim-secret is reused (NOOP_REPLAY scenario)" {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    echo "PRESERVEDSECRET1" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    write_contract_response secret noop_replay
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SUCCESS" ]]
    [[ ! "$output" =~ "PRESERVEDSECRET1" ]]
    # Final still has the original secret unchanged.
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "PRESERVEDSECRET1" ]
}

@test "existing pending file is reused (mid-POST resume scenario)" {
    mkdir -p "$ROOT_DIR/etc/airplanes"
    echo "RESUMEPENDING123" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    write_contract_response secret create_success
    start_mock_server
    run "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "$(mock_url)"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "RESU-MEPE-NDIN-G123" ]]
    # Pending was promoted to final on success.
    [ -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "RESUMEPENDING123" ]
}
