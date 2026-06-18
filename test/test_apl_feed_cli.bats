#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/apl-feed.sh"
    CONTRACT="$BATS_TEST_DIRNAME/contracts/feeder-api-v1.json"
    ROOT_DIR="$(mktemp -d)"
    mkdir -p "$ROOT_DIR/usr/local/share/airplanes" "$ROOT_DIR/etc/airplanes" \
             "$ROOT_DIR/var/lib/airplanes-diagnostics"
    echo "11111111-2222-3333-4444-555555555555" > "$ROOT_DIR/etc/airplanes/feeder-id"
    # Stage a fresh diagnostics-push timestamp so diagnostics_status_line
    # reads "ok" rather than the default "no successful push observed yet"
    # warn (the default-healthy fixture state assumes the timer has fired
    # at least once).
    touch "$ROOT_DIR/var/lib/airplanes-diagnostics/diagnostics-last-success"
    MOCK_PORT_FILE="$(mktemp)"
    MOCK_PID_FILE="$(mktemp)"
    # Mock servers append one "PATH<TAB>AUTH<TAB>BODY" line per POST here,
    # so tests can pin the v2 wire shape (Authorization: Bearer alv1.X.Y +
    # slim {"new_secret": ...} body for /api/feeders/secret).
    MOCK_REQ_FILE="$(mktemp)"

    # Stub external commands `apl-feed status` calls so the result-text
    # assertions don't depend on whether the host runner has systemctl,
    # active services, or established sockets. Defaults: services active,
    # receiver port reachable, ingest link established.
    STUB_BIN_DIR="$(mktemp -d)"
    cat > "$STUB_BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "show --property=ActiveState --value "*) printf 'active\n'; exit 0 ;;
    "show --property=ExecMainStatus --value "*) printf '0\n'; exit 0 ;;
    "is-active --quiet "*) exit 0 ;;
    "is-enabled "*) echo "enabled"; exit 0 ;;
esac
exit 0
STUB
    # nc serves two callers in status.sh: `nc -z <ip> <port>` for the
    # receiver connectivity probe (exit 0 = reachable), and bare
    # `nc <ip> <port>` for the receiver-activity byte sniff (must emit
    # some bytes so the data-flowing branch is exercised).
    cat > "$STUB_BIN_DIR/nc" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-z" ]]; then
    exit 0
fi
printf 'beast-bytes-fixture'
exit 0
STUB
    # ADS-B uplink check parses ss's last column (peer address:port) and
    # accepts :30004 (primary) or :64004 (failover); default-healthy
    # fixture emits an established socket to :30004 with the header row
    # the awk parser expects to skip.
    cat > "$STUB_BIN_DIR/ss" <<'STUB'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local-Address:Port Peer-Address:Port\n'
printf 'ESTAB 0 0 127.0.0.1:43530 78.46.234.18:30004\n'
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl" "$STUB_BIN_DIR/nc" "$STUB_BIN_DIR/ss"
    PATH="$STUB_BIN_DIR:$PATH"
    export PATH STUB_BIN_DIR
}

teardown() {
    stop_mock_server || true
    rm -rf "$ROOT_DIR" "$STUB_BIN_DIR"
    rm -f "$MOCK_PORT_FILE" "$MOCK_PID_FILE" "$MOCK_REQ_FILE"
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

contract_body() {
    local section="$1"
    local name="$2"
    jq -c --arg section "$section" --arg name "$name" '.[$section][$name].response.body' "$CONTRACT"
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
    local req_file="$MOCK_REQ_FILE"
    python3 - "$port_file" "$secret_status" "$secret_body" \
        "$active_secret" "$active_version" "$pending_secret" "$pending_version" \
        "$req_file" <<'PY' &
import http.server, json, re, sys
port_file = sys.argv[1]
secret_status = int(sys.argv[2])
secret_body = sys.argv[3]
active_secret = sys.argv[4]
active_version = sys.argv[5]
pending_secret = sys.argv[6]
pending_version = sys.argv[7]
req_file = sys.argv[8]

# v2 wire-shape gate (DEV-427): the shared claim stub used by every
# rotation/recovery test enforces Bearer + slim body for /secret. Without
# this, a regression that flips claim_rotate back to body-auth would
# silently pass every rotation test except the one that explicitly
# inspects MOCK_REQ_FILE.
BEARER_RE = re.compile(r"^Bearer alv1\.[0-9a-fA-F-]{32,36}\.[A-Za-z0-9]{1,64}$")

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = json.loads(raw.decode() or "{}")
        except Exception:
            body = {}
        # Record (path, auth, body) for test-side wire-shape assertions.
        auth = self.headers.get("Authorization", "")
        with open(req_file, "a") as f:
            f.write(f"{self.path}\t{auth}\t{raw.decode('utf-8', errors='replace')}\n")
        if self.path == "/api/feeders/secret":
            # Enforce v2 wire shape at the stub. Anything else means the
            # client has regressed back to v1 body-auth.
            if not BEARER_RE.match(auth):
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "missing_authorization"}).encode())
                return
            if not isinstance(body, dict) or set(body.keys()) != {"new_secret"}:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "invalid_request"}).encode())
                return
            self.send_response(secret_status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(secret_body.encode())
            return
        if self.path == "/api/feeders/status":
            # /status moved to Authorization: Bearer alv1.<uuid>.<secret>;
            # the body now only carries the UUID. Parse the bearer
            # against the body uuid the way the production server does:
            # malformed token → no auth (soft-fail to minimal),
            # token_uuid != body uuid → no auth (real server returns
            # 400 uuid_mismatch, but the feed-side test cases never
            # exercise that branch so soft-failing here is fine).
            current = ""
            body_uuid = body.get("uuid")
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Bearer alv1.") and body_uuid:
                rest = auth[len("Bearer alv1."):]
                parts = rest.split(".", 1)
                if len(parts) == 2 and parts[0] == body_uuid:
                    current = parts[1]
            if current == active_secret:
                out = {
                    "registered": True,
                    "version": int(active_version),
                    "set_at": "2026-04-28T00:00:00+00:00",
                    "owner_present": False,
                    "reset_until": None,
                    "last_seen_at": None,
                    "last_seen_age_seconds": None,
                }
            elif current == pending_secret:
                out = {
                    "registered": True,
                    "version": int(pending_version),
                    "set_at": "2026-04-28T00:00:00+00:00",
                    "owner_present": False,
                    "reset_until": None,
                    "last_seen_at": None,
                    "last_seen_age_seconds": None,
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
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run "$SCRIPT" claim show --root "$ROOT_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "ABCD-EFGH-IJKL-MNOP" ]]
    [[ "$output" =~ "Claim page: https://airplanes.live/feeder/claim" ]]
}

@test "claim show uses overridden server URL for claim page" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run "$SCRIPT" claim show --root "$ROOT_DIR" --website-url "https://staging.airplanes.test/"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Claim page: https://staging.airplanes.test/feeder/claim" ]]
}

@test "top-level status authenticates local secret and stores version" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    start_fixed_server 200 "$(contract_body status authenticated_recent)"

    run "$SCRIPT" status --root "$ROOT_DIR" --website-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Website claim" ]]
    [[ "$output" =~ "registered and claimed" ]]
    # Version is internal bookkeeping — surfaced via --json
    # (.claim.version, exercised in the json test below) and the local
    # mirror file. Not in the human line.
    [[ ! "$output" =~ "(v3)" ]]
    [[ "$output" =~ "Server reception" ]]
    [[ "$output" =~ "currently receiving" ]]
    [[ "$output" =~ "last data seen 1m ago" ]]
    [[ "$output" =~ "Result: feeding looks healthy" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version")" = "3" ]
}

@test "top-level status reads image boot config and env" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"
    mkdir -p "$ROOT_DIR/boot" "$ROOT_DIR/usr/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"
    echo "11111111-2222-3333-4444-555555555555" > "$ROOT_DIR/boot/airplanes-uuid"
    cat > "$ROOT_DIR/boot/airplanes-config.txt" <<'EOF'
USER="image-feeder"
LATITUDE="52.52000"
LONGITUDE="13.40500"
EOF
    cat > "$ROOT_DIR/boot/airplanes-env" <<'EOF'
INPUT="127.0.0.1:30006"
EOF
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    start_fixed_server 200 "$(contract_body status authenticated_recent)"

    run "$SCRIPT" status --root "$ROOT_DIR" --website-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Receiver input" ]]
    [[ "$output" =~ "connected at 127.0.0.1:30006" ]]
    [[ "$output" =~ "Result: feeding looks healthy" ]]
}

@test "top-level status json omits raw claim secret" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    start_fixed_server 200 "$(contract_body status authenticated_recent)"

    run "$SCRIPT" status --json --root "$ROOT_DIR" --website-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema_version' <<< "$output")" = "3" ]
    [ "$(jq -r '.config_sync.remote_config' <<< "$output")" = "disabled" ]
    [ "$(jq -r '.claim.version' <<< "$output")" = "3" ]
    [ "$(jq -r '.website.reception_state' <<< "$output")" = "recent" ]
    [ "$(jq -r '.website.last_seen_age_seconds' <<< "$output")" = "90" ]
    [ "$(jq -r '.receiver | type' <<< "$output")" = "object" ]
    [[ ! "$output" =~ "ABCDEFGHIJKLMNOP" ]]
    [[ ! "$output" =~ "ABCD-EFGH-IJKL-MNOP" ]]
}

@test "claim rotate promotes pending on 200" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    start_fixed_server 200 '{"version": 2}'

    run "$SCRIPT" claim rotate --root "$ROOT_DIR" --website-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rotation complete (v2)" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version")" = "2" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" != "ABCDEFGHIJKLMNOP" ]
}

@test "claim rotate POST sends v2 bearer with current secret + slim body" {
    # Pin the v2 wire shape for rotation (DEV-427): bearer carries the
    # *current* (pre-rotation) secret, body has only new_secret with the
    # next value. No legacy current_secret / uuid keys in the body.
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    start_claim_server 200 '{"version": 2}' \
        "ABCDEFGHIJKLMNOP" 1 "" 0

    run "$SCRIPT" claim rotate --root "$ROOT_DIR" --website-url "$(mock_url)"
    [ "$status" -eq 0 ]
    # Filter to the /secret POST line; /status probes are not relevant here
    # but may also appear in the capture if the rotate flow probes.
    secret_line="$(grep -F $'/api/feeders/secret\t' "$MOCK_REQ_FILE" | head -1)"
    [ -n "$secret_line" ]
    # Bearer = alv1.<uuid>.<current_secret>.
    auth="$(printf '%s' "$secret_line" | awk -F'\t' '{print $2}')"
    [[ "$auth" = "Bearer alv1.11111111-2222-3333-4444-555555555555.ABCDEFGHIJKLMNOP" ]]
    # Body = {"new_secret":"<16-char>"} with no other keys.
    body="$(printf '%s' "$secret_line" | awk -F'\t' '{print $3}')"
    [[ "$body" =~ ^\{\"new_secret\":\"[A-Z0-9]{16}\"\}$ ]]
    [[ ! "$body" =~ current_secret ]]
    [[ ! "$body" =~ \"uuid\" ]]
}

@test "claim rotate finalizes pending after lost response" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    echo "QRSTUVWXYZ012345" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret" "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    start_claim_server 409 '{"error": "rotation_rejected"}' \
        "ABCDEFGHIJKLMNOP" 1 "QRSTUVWXYZ012345" 3

    run "$SCRIPT" claim rotate --root "$ROOT_DIR" --website-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rotation finalized (v3)" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "QRSTUVWXYZ012345" ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
}

@test "claim rotate --abort deletes pending only when active authenticates" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    echo "QRSTUVWXYZ012345" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret" "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    start_claim_server 200 '{"version": 1}' \
        "ABCDEFGHIJKLMNOP" 1 "NO_MATCH_PENDING1" 2

    run "$SCRIPT" claim rotate --abort --root "$ROOT_DIR" --website-url "$(mock_url)"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Pending rotation aborted" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
}

@test "backup writes mode 0600 JSON and restore reads it" {
    local backup_file="$ROOT_DIR/backup.json"
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    echo "4" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret" "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"

    run "$SCRIPT" backup "$backup_file" --root "$ROOT_DIR"

    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$backup_file")" = "600" ]
    [ "$(jq -r '.feeder_uuid' "$backup_file")" = "11111111-2222-3333-4444-555555555555" ]
    [ "$(jq -r '.created_at | type' "$backup_file")" = "string" ]
    [ "$(jq -r '.claim.secret' "$backup_file")" = "ABCDEFGHIJKLMNOP" ]
    [ "$(jq -r '.claim.version' "$backup_file")" = "4" ]
    rm "$ROOT_DIR/etc/airplanes/feeder-id"
    rm "$ROOT_DIR/etc/airplanes/feeder-claim-secret" "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"

    run "$SCRIPT" restore "$backup_file" --root "$ROOT_DIR"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "11111111-2222-3333-4444-555555555555" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version")" = "4" ]
}

@test "restore reads a backup piped on /dev/stdin (webconfig identity-import path)" {
    # The webconfig identity-import wrapper runs `apl-feed restore
    # /dev/stdin --force` with the backup JSON on a pipe. read_backup_file
    # reopens its argument once per field, so the stream must be
    # materialised first — otherwise the first jq drains the pipe and the
    # rest see EOF.
    local backup_file="$ROOT_DIR/backup.json"
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    echo "4" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret" "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"
    run "$SCRIPT" backup "$backup_file" --root "$ROOT_DIR"
    [ "$status" -eq 0 ]
    rm "$ROOT_DIR/etc/airplanes/feeder-id"
    rm "$ROOT_DIR/etc/airplanes/feeder-claim-secret" "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"

    run bash -c "cat '$backup_file' | '$SCRIPT' restore /dev/stdin --force --root '$ROOT_DIR'"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "11111111-2222-3333-4444-555555555555" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version")" = "4" ]
}

@test "restore /dev/stdin with an empty pipe fails on schema, not existence" {
    # A relaxed source check must still surface a real validation error
    # (empty input → missing schema_version), not the misleading
    # "does not exist" that the old `[[ -f /dev/stdin ]]` test produced.
    run bash -c ": | '$SCRIPT' restore /dev/stdin --force --root '$ROOT_DIR'"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "schema_version" ]]
    [[ "$output" != *"does not exist"* ]]
}

@test "restore of a missing file path still reports does not exist" {
    # The regular-file path keeps its existence error; relaxing the check
    # for /dev/stdin must not turn a genuine typo into a jq error.
    run "$SCRIPT" restore "$ROOT_DIR/no-such-backup.json" --force --root "$ROOT_DIR"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "does not exist" ]]
}

@test "backup rejects --force instead of overwriting" {
    local backup_file="$ROOT_DIR/backup.json"
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run "$SCRIPT" backup --force "$backup_file" --root "$ROOT_DIR"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "unknown flag for backup: --force" ]]
    [ ! -e "$backup_file" ]
}

@test "restore rejects --dry-run without writing" {
    local backup_file="$ROOT_DIR/backup.json"
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run "$SCRIPT" backup "$backup_file" --root "$ROOT_DIR"
    [ "$status" -eq 0 ]
    rm "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run "$SCRIPT" restore --dry-run "$backup_file" --root "$ROOT_DIR"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "unknown flag for restore: --dry-run" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
}

@test "claim rotate rejects --dry-run without writing pending secret" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run "$SCRIPT" claim rotate --dry-run --root "$ROOT_DIR" --website-url "http://127.0.0.1:1"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "unknown flag for claim rotate: --dry-run" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
}

@test "status rejects --dry-run" {
    run "$SCRIPT" status --dry-run --root "$ROOT_DIR"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "unknown flag for status: --dry-run" ]]
}

@test "status rejects restore-only --force flag" {
    run "$SCRIPT" status --force --root "$ROOT_DIR"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "unknown flag for status: --force" ]]
}

@test "restore --check validates backup without writing" {
    local backup_file="$ROOT_DIR/backup.json"
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run "$SCRIPT" backup "$backup_file" --root "$ROOT_DIR"
    rm "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run "$SCRIPT" restore --check "$backup_file" --root "$ROOT_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Backup is valid" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
}

@test "claim set writes secret atomically when none exists" {
    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"abcd-efgh-ijkl-mnop"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
    [ "$(stat -c '%a' "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "640" ]
    [[ "$output" =~ "Claim secret saved." ]]
}

@test "claim set accepts a no-newline piped secret" {
    # `printf %s ABCDEFGHIJKLMNOP | apl-feed claim set` must work — the
    # documented website-side reveal lets users paste the secret into a
    # shell pipeline without a trailing newline.
    run bash -c "printf %s 'abcd-efgh-ijkl-mnop' | '$SCRIPT' claim set --root '$ROOT_DIR'"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
}

@test "claim set normalizes existing matching secret bytes and mode (idempotent)" {
    # User had previously written the secret in lowercase / hyphenated
    # form, or the file mode drifted. claim set should still leave a
    # canonical, mode-0640 file (group-readable so service accounts in
    # the airplanes-feed group can consume it).
    echo "abcd-efgh-ijkl-mnop" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 644 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCD-EFGH-IJKL-MNOP"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "already matches" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
    [ "$(stat -c '%a' "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "640" ]
}

@test "claim set drops stale .pending even on idempotent path" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    echo "PENDINGSECRETXY1" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
}

@test "claim set --force replaces a malformed existing secret file" {
    # Existing file is corrupt (wrong length); --force must succeed.
    echo "garbage" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" --force <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
}

@test "claim set without --force refuses to touch a malformed existing secret file" {
    echo "garbage" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "malformed or unreadable" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "garbage" ]
}

@test "claim set drops the version file when overwriting" {
    echo "OLDSECRETXYZ1234" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    echo "7" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" --force <<<"NEWSECRETXYZ5678"

    [ "$status" -eq 0 ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version" ]
}

@test "claim set leaves the version file alone on the idempotent path" {
    # When the supplied secret already matches, the version remains valid.
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    echo "7" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version")" = "7" ]
}

@test "claim set never restarts feeder daemons (no daemon consumes the secret)" {
    # The claim secret is consumed only by apl-feed itself, not by
    # airplanes-feed or airplanes-mlat. Saving it must not bounce a working
    # feeder. The only permitted systemctl calls are the post-write
    # claim-landed side effects — stop airplanes-claim.timer and nudge
    # airplanes-config-sync.service (see test_claim_timer_stop.bats and
    # test_config_sync_nudge.bats); this assertion pins that NOTHING ELSE
    # (no daemon restart or reload) is touched.
    COMMAND_LOG="$(mktemp)"
    cat > "$STUB_BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"
    export COMMAND_LOG APL_FEED_TEST_TIMER_STOP_FORCE=1 APL_FEED_TEST_CONFIG_SYNC_NUDGE_FORCE=1

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "Restarted" ]]
    # Every recorded systemctl invocation must be one of the two claim-landed
    # side effects. No restart, no reload, no apl-feed daemon touched.
    while IFS= read -r line; do
        [[ "$line" == "systemctl --no-block stop airplanes-claim.timer" \
            || "$line" == "systemctl --no-block start airplanes-config-sync.service" ]] \
            || { echo "unexpected systemctl call: $line" >&2; false; }
    done < "$COMMAND_LOG"
    rm -f "$COMMAND_LOG"
}

@test "claim set is idempotent when supplied secret already matches local" {
    echo "ABCDEFGHIJKLMNOP" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "already matches" ]]
}

@test "claim set refuses to overwrite a different existing secret without --force" {
    echo "OLDSECRETXYZ1234" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"NEWSECRETXYZ5678"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "different claim secret" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "OLDSECRETXYZ1234" ]
}

@test "claim set with --force replaces a different existing secret" {
    echo "OLDSECRETXYZ1234" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" --force <<<"NEWSECRETXYZ5678"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "NEWSECRETXYZ5678" ]
}

@test "claim set rejects malformed input" {
    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"not-a-secret"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "invalid claim secret format" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
}

@test "claim set drops any stale .pending file" {
    echo "PENDINGSECRETXY1" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"abcd-efgh-ijkl-mnop"

    [ "$status" -eq 0 ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret.pending" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
}

@test "claim set --dry-run does not write or restart services" {
    local restart_log="$ROOT_DIR/restart.log"
    cat > "$STUB_BIN_DIR/systemctl" <<STUB
#!/usr/bin/env bash
case "\$1" in
    restart) printf 'restarted %s\n' "\$2" >> "$restart_log"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"

    run env "$SCRIPT" claim set --root "$ROOT_DIR" --dry-run <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "dry-run" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
    [ ! -f "$restart_log" ]
}


# --- claim set: post-write timer stop -------------------------------------
#
# Coordinated with the image-side airplanes-claim.timer. Once claim set
# lands the secret on disk, the timer has nothing left to do, and every
# subsequent fire pollutes the service journal with condition-skip lines
# that the webconfig Claim activity panel surfaces.

@test "claim set new-secret write stops airplanes-claim.timer" {
    COMMAND_LOG="$(mktemp)"
    cat > "$STUB_BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"
    export COMMAND_LOG APL_FEED_TEST_TIMER_STOP_FORCE=1

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    grep -F -- '--no-block stop airplanes-claim.timer' "$COMMAND_LOG"
    rm -f "$COMMAND_LOG"
}

@test "claim set same-canonical-value (idempotent) still stops the timer" {
    # The re-normalize path also writes the file (to fix mode / casing), so
    # we want the timer-stop here too — keeps the helper invariant simple:
    # any successful secret write triggers the stop.
    echo "abcd-efgh-ijkl-mnop" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 644 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    COMMAND_LOG="$(mktemp)"
    cat > "$STUB_BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"
    export COMMAND_LOG APL_FEED_TEST_TIMER_STOP_FORCE=1

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"ABCD-EFGH-IJKL-MNOP"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "already matches" ]]
    grep -F -- '--no-block stop airplanes-claim.timer' "$COMMAND_LOG"
    rm -f "$COMMAND_LOG"
}

@test "claim set --dry-run does NOT stop the timer (no secret was written)" {
    COMMAND_LOG="$(mktemp)"
    cat > "$STUB_BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"
    export COMMAND_LOG APL_FEED_TEST_TIMER_STOP_FORCE=1

    run env "$SCRIPT" claim set --root "$ROOT_DIR" --dry-run <<<"ABCDEFGHIJKLMNOP"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "dry-run" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
    ! grep -F -- 'stop airplanes-claim.timer' "$COMMAND_LOG"
    rm -f "$COMMAND_LOG"
}

@test "claim set refuse-without-force does NOT stop the timer (nothing written)" {
    echo "OLDSECRETXYZ1234" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 600 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    COMMAND_LOG="$(mktemp)"
    cat > "$STUB_BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"
    export COMMAND_LOG APL_FEED_TEST_TIMER_STOP_FORCE=1

    run env "$SCRIPT" claim set --root "$ROOT_DIR" <<<"NEWSECRETXYZ5678"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "different claim secret" ]]
    ! grep -F -- 'stop airplanes-claim.timer' "$COMMAND_LOG"
    rm -f "$COMMAND_LOG"
}

@test "id set writes a new UUID and restarts both daemons feed-first" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"
    local restart_log="$ROOT_DIR/restart.log"
    cat > "$STUB_BIN_DIR/systemctl" <<STUB
#!/usr/bin/env bash
case "\$1" in
    is-active|is-enabled) exit 0 ;;
    restart) printf '%s\n' "\$2" >> "$restart_log"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"

    # Bypass the --root != / restart skip by sourcing the modules and
    # calling id_set directly with ROOT="/", with the host paths
    # redirected via shadowed helpers. Easier: stub feeder_id_path so it
    # writes inside ROOT_DIR. We do that by overriding ROOT for the
    # filesystem helpers but unsetting it for the restart helper. The
    # cleanest way is to test the restart helper directly here, then
    # cover write semantics with --root != / in a separate test.
    run env PATH="$STUB_BIN_DIR:$PATH" bash -c "
        source '$BATS_TEST_DIRNAME/../scripts/apl-feed/common.sh'
        ROOT=/
        restart_feeder_services
    "

    [ "$status" -eq 0 ]
    # Feed must be restarted before mlat (line 1 vs line 2).
    [ "$(sed -n '1p' "$restart_log")" = "airplanes-feed" ]
    [ "$(sed -n '2p' "$restart_log")" = "airplanes-mlat" ]
}

@test "id set writes a new UUID with --root != / (no systemctl)" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"
    cat > "$STUB_BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl invoked with: $*" >&2
exit 99
STUB
    chmod +x "$STUB_BIN_DIR/systemctl"

    run env "$SCRIPT" id set --root "$ROOT_DIR" <<<"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]
    [[ "$output" =~ "Feeder ID saved." ]]
    [[ "$output" =~ "Skipping service restart" ]]
    [[ ! "$output" =~ "systemctl invoked" ]]
}

@test "id set is idempotent when supplied UUID already matches" {
    # The default fixture writes 11111111-2222-3333-4444-555555555555.
    run env "$SCRIPT" id set --root "$ROOT_DIR" <<<"11111111-2222-3333-4444-555555555555"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "already matches" ]]
}

@test "id set refuses to overwrite a different existing UUID without --force" {
    # Default fixture has 1111-2222-3333-4444-...; supply a different UUID.
    run env "$SCRIPT" id set --root "$ROOT_DIR" <<<"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "different Feeder ID" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "11111111-2222-3333-4444-555555555555" ]
}

@test "id set --force prints OLD -> NEW and replaces UUID" {
    run env "$SCRIPT" id set --root "$ROOT_DIR" --force <<<"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Old: 11111111-2222-3333-4444-555555555555" ]]
    [[ "$output" =~ "New: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]
    # Soft warning about the old website-side record.
    [[ "$output" =~ "previous Feeder ID's record on airplanes.live is not removed" ]]
}

@test "id set --force replaces a malformed existing Feeder ID" {
    echo "garbage-not-a-uuid" > "$ROOT_DIR/etc/airplanes/feeder-id"

    run env "$SCRIPT" id set --root "$ROOT_DIR" --force <<<"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]
}

@test "id set without --force refuses to touch a malformed existing UUID file" {
    echo "garbage-not-a-uuid" > "$ROOT_DIR/etc/airplanes/feeder-id"

    run env "$SCRIPT" id set --root "$ROOT_DIR" <<<"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "malformed or unreadable" ]]
}

@test "id set rejects malformed input" {
    run env "$SCRIPT" id set --root "$ROOT_DIR" <<<"not-a-uuid"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "invalid Feeder ID" ]]
}

@test "id set --dry-run does not write or restart" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"
    run env "$SCRIPT" id set --root "$ROOT_DIR" --dry-run <<<"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "dry-run" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-id" ]
}

@test "restore --uuid form writes UUID + secret atomically and restarts" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"

    run bash -c "printf %s 'abcd-efgh-ijkl-mnop' | '$SCRIPT' restore --uuid AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE --root '$ROOT_DIR'"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")" = "ABCDEFGHIJKLMNOP" ]
    [[ "$output" =~ "Restored feeder config" ]]
}

@test "restore --uuid rejects malformed UUID" {
    run bash -c "printf %s 'ABCDEFGHIJKLMNOP' | '$SCRIPT' restore --uuid not-a-uuid --root '$ROOT_DIR'"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "invalid --uuid value" ]]
}

@test "restore --uuid rejects malformed secret on stdin" {
    run bash -c "printf %s 'too-short' | '$SCRIPT' restore --uuid AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE --root '$ROOT_DIR'"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "invalid claim secret" ]]
}

@test "restore --uuid + backup file rejected" {
    run env "$SCRIPT" restore --uuid AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE /tmp/some-backup --root "$ROOT_DIR"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "mutually exclusive" ]]
}

@test "restore --uuid --check validates without writing" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"
    rm -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run bash -c "printf %s 'abcd-efgh-ijkl-mnop' | '$SCRIPT' restore --uuid AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE --check --root '$ROOT_DIR'"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Inputs are valid" ]]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-id" ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret" ]
}

@test "restore --uuid refuses different existing UUID without --force" {
    # Default fixture UUID is 11111111-...
    run bash -c "printf %s 'abcd-efgh-ijkl-mnop' | '$SCRIPT' restore --uuid AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE --root '$ROOT_DIR'"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "local Feeder ID differs" ]]
    [ "$(cat "$ROOT_DIR/etc/airplanes/feeder-id")" = "11111111-2222-3333-4444-555555555555" ]
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
        "$SCRIPT" claim register --root "$ROOT_DIR" --website-url "http://example.invalid"

    [ "$status" -eq 0 ]
    local secret
    secret="$(cat "$ROOT_DIR/etc/airplanes/feeder-claim-secret")"
    ! grep -q "$secret" "$args_file"
    grep -q "$secret" "$stdin_file"
}
