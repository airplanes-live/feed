#!/usr/bin/env bats

# Per-module unit tests for scripts/apl-feed/http.sh.
#
# `post_json` is the only network primitive — uses a Python http.server
# fixture mirroring the pattern in test_apl_feed_cli.bats.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    mkdir -p "$TMPDIR" "$ROOT_DIR/etc/airplanes"
    export TMPDIR
    MOCK_PORT_FILE="$(mktemp)"
    MOCK_PID_FILE="$(mktemp)"
    MOCK_REQUEST_LOG="$(mktemp)"
    MOCK_REQUEST_BODY="$(mktemp)"

    # Save bats's EXIT trap before common.sh overrides it (see
    # test_apl_feed_common.bats for the explanation).
    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/http.sh
    source "$LIB_DIR/http.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"
    WEBSITE_URL='http://127.0.0.1:0'
}

teardown() {
    stop_mock_server || true
    rm -rf "$ROOT_DIR"
    rm -f "$MOCK_PORT_FILE" "$MOCK_PID_FILE" "$MOCK_REQUEST_LOG" "$MOCK_REQUEST_BODY"
}

stop_mock_server() {
    [[ -f "$MOCK_PID_FILE" ]] || return 0
    local pid
    pid="$(cat "$MOCK_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
}

start_mock_server() {
    # start_mock_server <status> <body>
    # Records the POST path and body to the request logs.
    local status="$1"
    local body="$2"
    python3 - "$MOCK_PORT_FILE" "$status" "$body" "$MOCK_REQUEST_LOG" "$MOCK_REQUEST_BODY" <<'PY' &
import http.server, sys
port_file = sys.argv[1]
status = int(sys.argv[2])
body = sys.argv[3]
req_log = sys.argv[4]
req_body_file = sys.argv[5]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(req_log, "a") as f:
            f.write(f"POST {self.path} ct={self.headers.get('Content-Type','')}\n")
        with open(req_body_file, "wb") as f:
            f.write(raw)
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
    echo $! > "$MOCK_PID_FILE"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$MOCK_PORT_FILE" ]] && return 0
        sleep 0.1
    done
    return 1
}

mock_url() {
    echo "http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
}

# --- post_json ---

@test "post_json: returns HTTP code on stdout, writes body to file" {
    start_mock_server 201 '{"version":1}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    body='{"uuid":"11111111-2222-3333-4444-555555555555","new_secret":"ABCDEFGHIJKLMNOP"}'
    run post_json '/api/feeders/secret' "$body" "$response_file"
    [ "$status" -eq 0 ]
    [ "$output" = '201' ]
    [ "$(cat "$response_file")" = '{"version":1}' ]
}

@test "post_json: sends body verbatim with Content-Type: application/json" {
    start_mock_server 200 '{}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    body='{"uuid":"11111111-2222-3333-4444-555555555555"}'
    post_json '/api/feeders/status' "$body" "$response_file" >/dev/null
    [ "$(cat "$MOCK_REQUEST_BODY")" = "$body" ]
    grep -q 'POST /api/feeders/status ct=application/json' "$MOCK_REQUEST_LOG"
}

# --- body_preview ---

@test "body_preview: caps at 200 chars" {
    long="$(printf 'A%.0s' {1..500})"
    printf '%s' "$long" > "$ROOT_DIR/big"
    run body_preview "$ROOT_DIR/big"
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 200 ]
}

@test "body_preview: missing file produces empty stdout" {
    # head writes the open-failure message to stderr; redirect to keep
    # `run` from capturing it as output.
    run bash -c "source '$LIB_DIR/common.sh' && source '$LIB_DIR/http.sh' && body_preview '$ROOT_DIR/missing' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- status_probe_version ---

@test "status_probe_version: 200 with .version echoes integer version" {
    start_mock_server 200 '{"version":7}'
    WEBSITE_URL="$(mock_url)"
    run status_probe_version '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 0 ]
    [ "$output" = '7' ]
}

@test "status_probe_version: 200 without .version returns 1" {
    start_mock_server 200 '{"registered":true}'
    WEBSITE_URL="$(mock_url)"
    run status_probe_version '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 1 ]
}

@test "status_probe_version: 200 with .version=null returns 1" {
    start_mock_server 200 '{"version":null}'
    WEBSITE_URL="$(mock_url)"
    run status_probe_version '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 1 ]
}

@test "status_probe_version: non-200 returns 1" {
    start_mock_server 423 '{"error":"feeder_blocked"}'
    WEBSITE_URL="$(mock_url)"
    run status_probe_version '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 1 ]
}

@test "status_probe_version: network failure (unbound port) returns 1" {
    WEBSITE_URL='http://127.0.0.1:1'   # port 1 — should refuse connection
    run status_probe_version '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 1 ]
}

@test "status_probe_version: cleans up its tempfile" {
    # status_probe_version's response_file is rm'd inside the function.
    # post_json_bearer's curl-config tempfile is also rm'd inside the
    # helper on return (the TMP_FILES safety-net would have been
    # invisible from this scope anyway — see post_json_bearer for why).
    start_mock_server 200 '{"version":7}'
    WEBSITE_URL="$(mock_url)"
    before="$(find "$TMPDIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    status_probe_version '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP' >/dev/null || true
    after="$(find "$TMPDIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    [ "$before" = "$after" ]
}

@test "status_probe_version: sends Authorization: Bearer alv1.<uuid>.<secret>" {
    # DEV-427: /status moved to Bearer auth. The body now carries only
    # the uuid; the secret rides in the Authorization header so it can't
    # leak via request-body access logs.
    start_mock_server_with_headers 200 '{"version":7}'
    WEBSITE_URL="$(mock_url)"
    run status_probe_version '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 0 ]
    grep -qi '^Authorization: Bearer alv1\.11111111-2222-3333-4444-555555555555\.ABCDEFGHIJKLMNOP$' "$ROOT_DIR/headers.log"
    [ "$(cat "$MOCK_REQUEST_BODY")" = '{"uuid":"11111111-2222-3333-4444-555555555555"}' ]
}

# --- post_json_bearer ---
#
# Extra fixture: the Python mock server logs every request header to a
# dedicated file so the Authorization header can be asserted independently.

start_mock_server_with_headers() {
    local status="$1"
    local body="$2"
    python3 - "$MOCK_PORT_FILE" "$status" "$body" "$MOCK_REQUEST_LOG" "$MOCK_REQUEST_BODY" "$ROOT_DIR/headers.log" <<'PY' &
import http.server, sys
port_file = sys.argv[1]
status = int(sys.argv[2])
body = sys.argv[3]
req_log = sys.argv[4]
req_body_file = sys.argv[5]
header_log = sys.argv[6]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(req_log, "a") as f:
            f.write(f"POST {self.path}\n")
        with open(req_body_file, "wb") as f:
            f.write(raw)
        with open(header_log, "w") as f:
            for k, v in self.headers.items():
                f.write(f"{k}: {v}\n")
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
    echo $! > "$MOCK_PID_FILE"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$MOCK_PORT_FILE" ]] && return 0
        sleep 0.1
    done
    return 1
}

@test "post_json_bearer: sends Authorization: Bearer <token> header" {
    start_mock_server_with_headers 200 '{"ok":true}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    body='{"schema_version":1,"uuid":"11111111-2222-3333-4444-555555555555"}'
    run post_json_bearer 'alv1.11111111-2222-3333-4444-555555555555.ABCDEFGHIJKLMNOP' \
        '/api/feeders/diagnostics' "$body" "$response_file"
    [ "$status" -eq 0 ]
    [ "$output" = '200' ]
    grep -qi '^Authorization: Bearer alv1\.11111111-2222-3333-4444-555555555555\.ABCDEFGHIJKLMNOP$' "$ROOT_DIR/headers.log"
}

@test "post_json_bearer: token is NOT passed via curl argv" {
    # Wrap curl with a stub that records argv and then exec's real curl.
    real_curl="$(command -v curl)"
    [ -n "$real_curl" ]
    stub_dir="$ROOT_DIR/curl-stub"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$ROOT_DIR/curl-argv.log'
exec '$real_curl' "\$@"
SH
    chmod +x "$stub_dir/curl"

    start_mock_server_with_headers 200 '{"ok":true}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    PATH="$stub_dir:$PATH" post_json_bearer 'alv1.deadbeef.SECRETTOKEN0000' \
        '/api/feeders/diagnostics' '{"x":1}' "$response_file" >/dev/null
    ! grep -q 'SECRETTOKEN0000' "$ROOT_DIR/curl-argv.log"
    ! grep -q 'alv1\.deadbeef' "$ROOT_DIR/curl-argv.log"
    # Sanity: the canned URL is in argv even though the token is not
    grep -q "$WEBSITE_URL" "$ROOT_DIR/curl-argv.log"
}

@test "post_json_bearer: sends body verbatim with Content-Type: application/json" {
    start_mock_server_with_headers 200 '{}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    body='{"schema_version":1,"uuid":"x"}'
    post_json_bearer 'alv1.x.y' '/api/feeders/diagnostics' "$body" "$response_file" >/dev/null
    [ "$(cat "$MOCK_REQUEST_BODY")" = "$body" ]
    grep -qi '^Content-Type: application/json' "$ROOT_DIR/headers.log"
}

@test "post_json_bearer: tempfile is registered in TMP_FILES safety-net and 0600" {
    # Stub rm so the curl-config tempfile survives the in-function
    # cleanup; that lets us assert both the TMP_FILES registration (for
    # the EXIT trap safety-net) and the 0600 mode on the created file.
    # The next test asserts the primary in-function cleanup actually
    # runs.
    rm_real="$(command -v rm)"
    rm() { :; }  # no-op
    start_mock_server_with_headers 200 '{}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    before_count="${#TMP_FILES[@]}"
    post_json_bearer 'alv1.x.y' '/api/feeders/diagnostics' '{}' "$response_file" >/dev/null
    unset -f rm
    [ "${#TMP_FILES[@]}" -gt "$before_count" ]
    last_entry="${TMP_FILES[-1]}"
    [ -f "$last_entry" ]
    # 0600 mode — owner-read/write only
    mode="$(stat -c '%a' "$last_entry" 2>/dev/null || stat -f '%A' "$last_entry")"
    [ "$mode" = '600' ]
}

@test "post_json_bearer: tempfile is rm'd on return (primary cleanup)" {
    # Primary cleanup: the helper rm's the curl-config inside the
    # function so callers using $() command substitution (where
    # TMP_FILES mutations are lost) still don't leak. TMP_FILES is the
    # safety-net for signal-kill / set-e-bail paths.
    start_mock_server_with_headers 200 '{}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    before="$(find "$TMPDIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    post_json_bearer 'alv1.x.y' '/api/feeders/diagnostics' '{}' "$response_file" >/dev/null
    rm -f "$response_file"
    after="$(find "$TMPDIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    [ "$before" = "$after" ]
}

@test "post_json: still works after http.sh has loaded post_json_bearer (regression)" {
    # Codex flagged the risk of post_json_bearer drifting post_json semantics.
    # This regression pin asserts the original helper's contract is unchanged:
    # a 4xx response is returned as a string, not as a curl transport failure.
    start_mock_server 400 '{"error":"bad_request"}'
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    run post_json '/api/feeders/secret' '{"x":1}' "$response_file"
    [ "$status" -eq 0 ]
    [ "$output" = '400' ]
    [ "$(cat "$response_file")" = '{"error":"bad_request"}' ]
}

# --- response-size cap ---
#
# Both POST helpers pass --max-filesize 131072 so a misbehaving server
# cannot fill /tmp on a disk-constrained feeder. curl announces the
# expected size via Content-Length; if that exceeds the cap, curl exits
# 63 before reading the body.

start_mock_server_big_body() {
    # Emits an HTTP response with the given Content-Length and then
    # streams that many bytes. Used to exercise the --max-filesize cap.
    local status="$1"
    local size="$2"
    python3 - "$MOCK_PORT_FILE" "$status" "$size" <<'PY' &
import http.server, sys
port_file = sys.argv[1]
status = int(sys.argv[2])
size = int(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        _ = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        # Stream bytes in chunks so the wire reflects the announced size.
        chunk = b"A" * 4096
        remaining = size
        try:
            while remaining > 0:
                n = min(remaining, len(chunk))
                self.wfile.write(chunk[:n])
                remaining -= n
        except BrokenPipeError:
            pass
    def log_message(self, *a, **kw): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
PY
    echo $! > "$MOCK_PID_FILE"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$MOCK_PORT_FILE" ]] && return 0
        sleep 0.1
    done
    return 1
}

@test "post_json: response larger than 128 KiB cap exits with curl --max-filesize error" {
    # 200 KiB body — Content-Length > 131072 so curl bails with exit 63
    # (CURLE_FILESIZE_EXCEEDED) before writing anything to the response file.
    start_mock_server_big_body 200 204800
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    run post_json '/api/feeders/secret' '{"x":1}' "$response_file"
    [ "$status" -eq 63 ]
}

@test "post_json_bearer: response larger than 128 KiB cap exits with curl --max-filesize error" {
    start_mock_server_big_body 200 204800
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    run post_json_bearer 'alv1.x.y' '/api/feeders/diagnostics' '{"x":1}' "$response_file"
    [ "$status" -eq 63 ]
}

@test "post_json: response just under 128 KiB cap succeeds" {
    # Sanity: 120 KiB body (well under the 128 KiB cap) round-trips fine.
    start_mock_server_big_body 200 122880
    WEBSITE_URL="$(mock_url)"
    response_file="$TMPDIR/resp"
    run post_json '/api/feeders/secret' '{"x":1}' "$response_file"
    [ "$status" -eq 0 ]
    [ "$output" = '200' ]
}
