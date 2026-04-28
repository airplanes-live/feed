#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/apl-feed.sh"
    ROOT_DIR="$(mktemp -d)"
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes" "$ROOT_DIR/etc/airplanes"
    echo "11111111-2222-3333-4444-555555555555" > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"
    MOCK_PORT_FILE="$(mktemp)"
    MOCK_PID_FILE="$(mktemp)"
}

teardown() {
    stop_mock_server || true
    rm -rf "$ROOT_DIR"
    rm -f "$MOCK_PORT_FILE" "$MOCK_PID_FILE"
}

stop_mock_server() {
    [[ -f "$MOCK_PID_FILE" ]] || return 0
    local pid
    pid="$(cat "$MOCK_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
}

mock_url() {
    echo "http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
}

start_fixed_server() {
    local status="$1"
    local body="$2"
    local port_file="$MOCK_PORT_FILE"
    local pid_file="$MOCK_PID_FILE"
    python3 - "$port_file" "$status" "$body" <<'PY' &
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
    echo $! > "$pid_file"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$port_file" ]] && return 0
        sleep 0.1
    done
    return 1
}

start_claim_server() {
    # start_claim_server SECRET_STATUS SECRET_BODY ACTIVE_SECRET ACTIVE_VERSION PENDING_SECRET PENDING_VERSION
    local secret_status="$1"
    local secret_body="$2"
    local active_secret="$3"
    local active_version="$4"
    local pending_secret="$5"
    local pending_version="$6"
    local port_file="$MOCK_PORT_FILE"
    local pid_file="$MOCK_PID_FILE"
    python3 - "$port_file" "$secret_status" "$secret_body" \
        "$active_secret" "$active_version" "$pending_secret" "$pending_version" <<'PY' &
import http.server, json, sys
port_file = sys.argv[1]
secret_status = int(sys.argv[2])
secret_body = sys.argv[3]
active_secret = sys.argv[4]
active_version = sys.argv[5]
pending_secret = sys.argv[6]
pending_version = sys.argv[7]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = json.loads(raw.decode() or "{}")
        except Exception:
            body = {}
        if self.path == "/api/feeders/secret":
            self.send_response(secret_status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(secret_body.encode())
            return
        if self.path == "/api/feeders/status":
            current = body.get("current_secret")
            if current == active_secret:
                out = {
                    "registered": True,
                    "version": int(active_version),
                    "set_at": "2026-04-28T00:00:00+00:00",
                    "owner_present": False,
                    "reset_until": None,
                }
            elif current == pending_secret:
                out = {
                    "registered": True,
                    "version": int(pending_version),
                    "set_at": "2026-04-28T00:00:00+00:00",
                    "owner_present": False,
                    "reset_until": None,
                }
            else:
                out = {"registered": True}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(out).encode())
            return
        self.send_response(404)
        self.end_headers()
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

@test "claim show prints grouped local secret" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/claim-secret"

    run "$SCRIPT" claim show --root "$ROOT_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "ABCD-EFGH-IJKL-MNOP" ]]
}

@test "top-level status authenticates local secret and stores version" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/claim-secret"
    start_fixed_server 200 '{"registered": true, "version": 7, "set_at": "2026-04-28T00:00:00+00:00", "owner_present": false, "reset_until": null}'

    run "$SCRIPT" status --root "$ROOT_DIR" --server-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Website claim" ]]
    [[ "$output" =~ "registered, not yet claimed (v7)" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/claim-secret.version")" = "7" ]
}

@test "claim rotate promotes pending on 200" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/claim-secret"
    start_fixed_server 200 '{"version": 2}'

    run "$SCRIPT" claim rotate --root "$ROOT_DIR" --server-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rotation complete (v2)" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/claim-secret.pending" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/claim-secret.version")" = "2" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/claim-secret")" != "ABCDEFGHIJKLMNOP" ]
}

@test "claim rotate finalizes pending after lost response" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/claim-secret"
    echo "QRSTUVWXYZ012345" > "$ROOT_DIR/etc/airplanes/claim-secret.pending"
    chmod 600 "$ROOT_DIR/etc/airplanes/claim-secret" "$ROOT_DIR/etc/airplanes/claim-secret.pending"
    start_claim_server 409 '{"error": "rotation_rejected"}' \
        "ABCDEFGHIJKLMNOP" 1 "QRSTUVWXYZ012345" 3

    run "$SCRIPT" claim rotate --root "$ROOT_DIR" --server-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rotation finalized (v3)" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/claim-secret")" = "QRSTUVWXYZ012345" ]
    [ ! -f "$ROOT_DIR/etc/airplanes/claim-secret.pending" ]
}

@test "claim rotate --abort deletes pending only when active authenticates" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/claim-secret"
    echo "QRSTUVWXYZ012345" > "$ROOT_DIR/etc/airplanes/claim-secret.pending"
    chmod 600 "$ROOT_DIR/etc/airplanes/claim-secret" "$ROOT_DIR/etc/airplanes/claim-secret.pending"
    start_claim_server 200 '{"version": 1}' \
        "ABCDEFGHIJKLMNOP" 1 "NO_MATCH_PENDING1" 2

    run "$SCRIPT" claim rotate --abort --root "$ROOT_DIR" --server-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Pending rotation aborted" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/claim-secret.pending" ]
}

@test "backup writes mode 0600 JSON and restore reads it" {
    local backup_file="$ROOT_DIR/backup.json"
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/claim-secret"
    echo "4" > "$ROOT_DIR/etc/airplanes/claim-secret.version"
    chmod 600 "$ROOT_DIR/etc/airplanes/claim-secret" "$ROOT_DIR/etc/airplanes/claim-secret.version"

    run "$SCRIPT" backup "$backup_file" --root "$ROOT_DIR"

    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$backup_file")" = "600" ]
    [ "$(jq -r '.feeder_uuid' "$backup_file")" = "11111111-2222-3333-4444-555555555555" ]
    [ "$(jq -r '.claim.secret' "$backup_file")" = "ABCDEFGHIJKLMNOP" ]
    [ "$(jq -r '.claim.version' "$backup_file")" = "4" ]
    rm "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"
    rm "$ROOT_DIR/etc/airplanes/claim-secret" "$ROOT_DIR/etc/airplanes/claim-secret.version"

    run "$SCRIPT" restore "$backup_file" --root "$ROOT_DIR"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid")" = "11111111-2222-3333-4444-555555555555" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/claim-secret")" = "ABCDEFGHIJKLMNOP" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/claim-secret.version")" = "4" ]
}

@test "register sends raw secret through stdin, not curl argv" {
    local bin_dir="$ROOT_DIR/bin"
    local args_file="$ROOT_DIR/curl.args"
    local stdin_file="$ROOT_DIR/curl.stdin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [[ $# -gt 0 ]]; do
    printf '%s\n' "$1" >> "$CURL_ARGS_FILE"
    if [[ "$1" == "--output" ]]; then
        shift
        out="$1"
        printf '%s\n' "$1" >> "$CURL_ARGS_FILE"
    fi
    shift || true
done
cat > "$CURL_STDIN_FILE"
printf '{"version":1}' > "$out"
printf '201'
SH
    chmod +x "$bin_dir/curl"

    run env PATH="$bin_dir:$PATH" CURL_ARGS_FILE="$args_file" CURL_STDIN_FILE="$stdin_file" \
        "$SCRIPT" claim register --root "$ROOT_DIR" --server-url "http://example.invalid"

    [ "$status" -eq 0 ]
    local secret
    secret="$(cat "$ROOT_DIR/etc/airplanes/claim-secret")"
    ! grep -q "$secret" "$args_file"
    grep -q "$secret" "$stdin_file"
}
