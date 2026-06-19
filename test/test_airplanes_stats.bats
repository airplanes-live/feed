#!/usr/bin/env bats

# Tests for scripts/airplanes-stats.sh — the feeder stats uploader invoked every
# ~120s by airplanes-stats.timer. It forwards the forwarder's raw readsb JSON
# (aircraft/stats/outline) gzip-encoded to /api/feeders/stats.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO_ROOT/scripts/airplanes-stats.sh"

    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    COMMAND_LOG="$ROOT_DIR/cmd.log"
    BODY_LOG="$ROOT_DIR/body.log"
    HEADER_LOG="$ROOT_DIR/header.log"
    mkdir -p "$STUB_DIR" "$ROOT_DIR/etc/airplanes" "$ROOT_DIR/run/airplanes-feed"

    # curl stub: records argv, dumps the --config file (bearer header) to
    # HEADER_LOG, and GUNZIPS the uploaded body (post_gzip_bearer sends
    # `--data-binary @<gzip_file>`) into BODY_LOG so tests can inspect the JSON.
    # Writes a synthetic response and exits with $CURL_STATUS / $CURL_RC.
    cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
prev=''
output_file=''
data_file=''
for arg in "$@"; do
    if [[ "$prev" == "--config" && -r "$arg" ]]; then
        cat "$arg" >> "$HEADER_LOG"
    fi
    [[ "$prev" == "--output" ]] && output_file="$arg"
    [[ "$prev" == "--data-binary" ]] && data_file="${arg#@}"
    prev="$arg"
done
if [[ -n "$data_file" && -r "$data_file" ]]; then
    gunzip -c "$data_file" > "$BODY_LOG" 2>/dev/null || cp "$data_file" "$BODY_LOG"
fi
if [[ -n "$output_file" ]]; then
    printf '%s' "${CURL_RESPONSE:-{\"ok\":true\}}" > "$output_file"
fi
printf '%s' "${CURL_STATUS:-200}"
exit "${CURL_RC:-0}"
SH
    chmod +x "$STUB_DIR/curl"

    # Claim state + consent (claimed + opted in by default).
    printf '11111111-2222-3333-4444-555555555555\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    chmod 0644 "$ROOT_DIR/etc/airplanes/feeder-id"
    printf 'ABCDEFGHIJKLMNOP\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    printf 'REPORT_STATUS=true\n' > "$ROOT_DIR/etc/airplanes/feed.env"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Seed fresh, valid forwarder JSON (aircraft + stats). $1 overrides aircraft.now.
_seed_forwarder() {
    local now="${1:-$(date +%s)}"
    local dir="$ROOT_DIR/run/airplanes-feed"
    cat > "$dir/aircraft.json" <<EOF
{"now": $now, "messages": 1234, "aircraft": [{"hex":"abc123","rssi":-12.3,"lat":52.5,"lon":13.4}]}
EOF
    cat > "$dir/stats.json" <<'EOF'
{"aircraft_with_pos": 7, "aircraft_without_pos": 3, "total": {"messages": 1000, "position_count_total": 400, "tracks": {"all": 50}, "max_distance": 185200}}
EOF
}

_seed_outline() {
    cat > "$ROOT_DIR/run/airplanes-feed/outline.json" <<'EOF'
{"actualRange": {"last24h": {"points": [[52.5, 13.4], [52.6, 13.5], [52.4, 13.3]]}}}
EOF
}

run_script() {
    run env -i \
        PATH="$STUB_DIR:/usr/bin:/bin" \
        HOME="$ROOT_DIR" \
        AIRPLANES_STATS_ROOT="$ROOT_DIR" \
        APL_FEED_WEBSITE_URL="${APL_FEED_WEBSITE_URL:-http://127.0.0.1:0}" \
        AIRPLANES_STATS_TEST_MAX_RAW_BYTES="${AIRPLANES_STATS_TEST_MAX_RAW_BYTES:-}" \
        AIRPLANES_STATS_TEST_MAX_GZIP_BYTES="${AIRPLANES_STATS_TEST_MAX_GZIP_BYTES:-}" \
        COMMAND_LOG="$COMMAND_LOG" \
        BODY_LOG="$BODY_LOG" \
        HEADER_LOG="$HEADER_LOG" \
        CURL_STATUS="${CURL_STATUS:-200}" \
        CURL_RC="${CURL_RC:-0}" \
        CURL_RESPONSE="${CURL_RESPONSE:-}" \
        bash "$SCRIPT"
}

_posted() { grep -q -- '/api/feeders/stats' "$COMMAND_LOG"; }

# ---- happy path ----

@test "fresh JSON + outline → gzip POST to /api/feeders/stats with all three docs" {
    _seed_forwarder
    _seed_outline
    run_script
    [ "$status" -eq 0 ]
    _posted
    grep -q -- 'Content-Encoding: gzip' "$COMMAND_LOG"
    run jq -e '.schema_version == 1' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e '.uuid == "11111111-2222-3333-4444-555555555555"' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e 'has("ts")' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e '.aircraft.now != null' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e '.stats.total.max_distance == 185200' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e '.outline.actualRange.last24h.points | length == 3' "$BODY_LOG"; [ "$status" -eq 0 ]
}

@test "bearer travels in the curl --config header, never in argv" {
    _seed_forwarder
    run_script
    [ "$status" -eq 0 ]
    grep -q 'Authorization: Bearer alv1.11111111-2222-3333-4444-555555555555.ABCDEFGHIJKLMNOP' "$HEADER_LOG"
    # The secret must never appear in the recorded curl argv.
    if grep -q 'ABCDEFGHIJKLMNOP' "$COMMAND_LOG"; then return 1; fi
}

@test "outline absent → envelope omits outline, core docs still sent" {
    _seed_forwarder   # no _seed_outline
    run_script
    [ "$status" -eq 0 ]
    _posted
    run jq -e 'has("outline") | not' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e '(.aircraft != null) and (.stats != null)' "$BODY_LOG"; [ "$status" -eq 0 ]
}

@test "outline present but truncated → outline omitted, core still sent" {
    _seed_forwarder
    printf '{ truncated outline' > "$ROOT_DIR/run/airplanes-feed/outline.json"
    run_script
    [ "$status" -eq 0 ]
    _posted
    run jq -e 'has("outline") | not' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e '.aircraft != null' "$BODY_LOG"; [ "$status" -eq 0 ]
}

@test "non-object core doc (array) → no POST, exit 0" {
    _seed_forwarder
    printf '[1,2,3]\n' > "$ROOT_DIR/run/airplanes-feed/stats.json"
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
}

@test "multi-document core file (concatenated objects) → no POST, exit 0" {
    # A half-rewritten readsb file can concatenate two objects. validate_doc must
    # reject the stream rather than upload only the first object.
    _seed_forwarder
    printf '{"a":1}{"b":2}\n' > "$ROOT_DIR/run/airplanes-feed/stats.json"
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
}

# ---- freshness ----

@test "stale aircraft.now (old) → no POST, exit 0" {
    _seed_forwarder "$(( $(date +%s) - 9999 ))"
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
    [[ "$output" == *"reason=stale"* ]]
}

@test "missing aircraft.now → no POST, exit 0" {
    cat > "$ROOT_DIR/run/airplanes-feed/aircraft.json" <<'EOF'
{"messages": 5, "aircraft": []}
EOF
    cat > "$ROOT_DIR/run/airplanes-feed/stats.json" <<'EOF'
{"total": {"max_distance": 0}}
EOF
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
    [[ "$output" == *"reason=no_now"* ]]
}

@test "non-numeric aircraft.now → no POST, exit 0" {
    cat > "$ROOT_DIR/run/airplanes-feed/aircraft.json" <<'EOF'
{"now": "soon", "aircraft": []}
EOF
    cat > "$ROOT_DIR/run/airplanes-feed/stats.json" <<'EOF'
{"total": {"max_distance": 0}}
EOF
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
}

# ---- consent + identity gating ----

@test "REPORT_STATUS=false → no POST, exit 0" {
    printf 'REPORT_STATUS=false\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    _seed_forwarder
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
    [[ "$output" == *"status=disabled"* ]]
}

@test "REPORT_STATUS garbage → exit 64, no POST" {
    printf 'REPORT_STATUS=perhaps\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    _seed_forwarder
    run_script
    [ "$status" -eq 64 ]
    [[ "$output" == *"status=bad_config"* ]]
    [ ! -f "$COMMAND_LOG" ]
}

@test "unclaimed (no secret) → no POST, exit 0" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    _seed_forwarder
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
    [[ "$output" == *"reason=no_secret"* ]]
}

@test "invalid Feeder ID → no POST, exit 0" {
    printf 'not-a-uuid\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    _seed_forwarder
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
}

@test "forwarder JSON entirely absent → no POST, exit 0" {
    # No _seed_forwarder — /run/airplanes-feed is empty.
    run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
    [[ "$output" == *"reason=aircraft_unavailable"* ]]
}

# ---- size policy ----

@test "oversize with outline → drop outline and resend core only" {
    _seed_forwarder
    # A large outline pushes the raw envelope over the test cap; the core-only
    # envelope is well under it, so the uploader drops outline and still POSTs.
    python3 - "$ROOT_DIR/run/airplanes-feed/outline.json" <<'PY'
import json, sys
pts = [[round(52 + i*1e-4, 4), round(13 + i*1e-4, 4)] for i in range(400)]
json.dump({"actualRange": {"last24h": {"points": pts}}}, open(sys.argv[1], "w"))
PY
    AIRPLANES_STATS_TEST_MAX_RAW_BYTES=2000 run_script
    [ "$status" -eq 0 ]
    _posted
    run jq -e 'has("outline") | not' "$BODY_LOG"; [ "$status" -eq 0 ]
    run jq -e '.aircraft != null' "$BODY_LOG"; [ "$status" -eq 0 ]
}

@test "oversize even without outline → skip, no POST, exit 0" {
    _seed_forwarder
    AIRPLANES_STATS_TEST_MAX_RAW_BYTES=1 run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
    [[ "$output" == *"status=oversize"* ]]
}

@test "gzip cap exceeded with no outline to drop → skip, no POST, exit 0" {
    _seed_forwarder
    AIRPLANES_STATS_TEST_MAX_GZIP_BYTES=1 run_script
    [ "$status" -eq 0 ]
    if _posted; then return 1; fi
    [[ "$output" == *"status=oversize"* ]]
}

# ---- POST outcomes (best-effort) ----

@test "server returns 500 → exit 0, logs stats_failed" {
    _seed_forwarder
    CURL_STATUS=500 run_script
    [ "$status" -eq 0 ]
    _posted
    [[ "$output" == *"status=stats_failed"* ]]
}

@test "transport error (curl rc != 0) → exit 0, logs transport_error" {
    _seed_forwarder
    CURL_RC=7 run_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=transport_error"* ]]
}

@test "AIRPLANES_STATS_ROOT honoured: reads the rooted /run path" {
    # Forwarder JSON under the rooted path is found; an absent rooted path means
    # no data (already covered) — this asserts the root override is actually used
    # by writing only under ROOT and expecting a successful POST.
    _seed_forwarder
    run_script
    [ "$status" -eq 0 ]
    _posted
}
