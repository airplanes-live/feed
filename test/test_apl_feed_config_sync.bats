#!/usr/bin/env bats

# Tests for `apl-feed config sync` (scripts/apl-feed/config.sh).
# Drives the CLI via apl-feed.sh with --root $ROOT_DIR. Curl is stubbed
# to return canned HTTP status codes + bodies; the real apl_feed_apply
# library is exercised end-to-end so the LWW gate and feed.meta.json
# round-trip are part of the test.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    CURL_LOG="$ROOT_DIR/curl.log"
    CURL_REQ_BODY="$ROOT_DIR/curl-req-body.json"
    CANNED_STATUS_FILE="$ROOT_DIR/canned-status"
    CANNED_RESPONSE_FILE="$ROOT_DIR/canned-response.json"
    mkdir -p "$STUB_DIR" \
        "$ROOT_DIR/etc/airplanes" \
        "$ROOT_DIR/run/airplanes" \
        "$ROOT_DIR/var/lib/airplanes"

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"

    cat > "$STUB_DIR/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/logger"

    # Curl stub. Records argv + stdin body; writes canned response body
    # to the --output path; emits canned HTTP status to stdout.
    cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$CURL_LOG"
output_path=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --output) output_path="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
# Capture request body from stdin for assertions.
cat > "$CURL_REQ_BODY"
if [[ -n "\$output_path" && -f "$CANNED_RESPONSE_FILE" ]]; then
    cp "$CANNED_RESPONSE_FILE" "\$output_path"
fi
if [[ -f "$CANNED_STATUS_FILE" ]]; then
    cat "$CANNED_STATUS_FILE"
else
    printf '200'
fi
exit 0
STUB
    chmod +x "$STUB_DIR/curl"

    PATH="$STUB_DIR:$PATH"
    export PATH

    # Identity files. UUID + claim secret valid format.
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' \
        > "$ROOT_DIR/etc/airplanes/feeder-id"
    printf 'ABCD1234EFGH5678\n' \
        > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    AIRPLANES_CONFIG_SYNC_LAST_SUCCESS="$ROOT_DIR/var/lib/airplanes-config-sync/config-sync-last-success"
    export AIRPLANES_CONFIG_SYNC_LAST_SUCCESS

    AIRPLANES_CONFIG_SYNC_STATE="$ROOT_DIR/var/lib/airplanes-config-sync/state"
    export AIRPLANES_CONFIG_SYNC_STATE
}

teardown() {
    rm -rf "$ROOT_DIR"
}

seed_feed_env() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="120"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
}

seed_feed_meta() {
    # Take a flat (key, edited_at) pair list. edited_by always feeder.
    local -a pairs=("$@")
    local filter='{schema_version: 1, fields: {}}'
    local jq_args=()
    local i=0 k at
    while (( i < ${#pairs[@]} )); do
        k="${pairs[$i]}"
        at="${pairs[$((i + 1))]}"
        jq_args+=(--arg "k${i}" "$k" --arg "a${i}" "$at")
        filter+=" | .fields[\$k${i}] = {edited_at: \$a${i}, edited_by: \"feeder\"}"
        i=$((i + 2))
    done
    jq -nc "${jq_args[@]}" "$filter" > "$ROOT_DIR/etc/airplanes/feed.meta.json"
}

set_canned() {
    local status="$1" body="$2"
    printf '%s' "$status" > "$CANNED_STATUS_FILE"
    printf '%s' "$body" > "$CANNED_RESPONSE_FILE"
}

run_sync() {
    SYNC_OUT=""
    SYNC_ERR=""
    SYNC_RC=0
    local err
    err="$(mktemp)"
    SYNC_OUT="$("$REPO_ROOT/scripts/apl-feed.sh" config sync --root "$ROOT_DIR" "$@" 2>"$err")" \
        || SYNC_RC=$?
    SYNC_ERR="$(cat "$err")"
    rm -f "$err"
}

@test "dry-run emits the expected payload shape" {
    seed_feed_env
    seed_feed_meta LATITUDE "2026-05-10T10:00:00Z" LONGITUDE "2026-05-10T10:00:00Z" \
        ALTITUDE "2026-05-09T00:00:00Z" MLAT_USER "2026-05-08T00:00:00Z" \
        MLAT_ENABLED "2026-05-08T00:00:00Z" MLAT_PRIVATE "2026-05-08T00:00:00Z"

    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ ! -f "$CURL_LOG" ]  # no network call
    local payload="$SYNC_OUT"
    [ "$(jq -r .schema_version <<<"$payload")" = "1" ]
    jq -e '.fields.position.value.lat == 47' <<<"$payload" >/dev/null
    jq -e '.fields.position.value.lon == 8' <<<"$payload" >/dev/null
    [ "$(jq -r '.fields.position.edited_by' <<<"$payload")" = "feeder" ]
    # alt.value is a JSON number (bare metres) end-to-end.
    [ "$(jq -r '.fields.alt.value' <<<"$payload")" = "120" ]
    [ "$(jq -r '.fields.alt.value | type' <<<"$payload")" = "number" ]
    [ "$(jq -r '.fields.mlat_user.value' <<<"$payload")" = "alice" ]
    [ "$(jq -r '.fields.mlat_enabled.value' <<<"$payload")" = "true" ]
    [ "$(jq -r '.fields.mlat_enabled.value | type' <<<"$payload")" = "boolean" ]
    [ "$(jq -r '.fields.mlat_private.value' <<<"$payload")" = "false" ]
    [ "$(jq -r '.fields.mlat_private.value | type' <<<"$payload")" = "boolean" ]
}

@test "dry-run bootstrap path with missing feed.meta.json uses legacy tuple" {
    seed_feed_env
    # No feed.meta.json present.

    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.position.edited_at' <<<"$SYNC_OUT")" = "2020-01-01T00:00:00Z" ]
    [ "$(jq -r '.fields.alt.edited_at' <<<"$SYNC_OUT")" = "2020-01-01T00:00:00Z" ]
    [ "$(jq -r '.fields.alt.edited_by' <<<"$SYNC_OUT")" = "legacy" ]
    [ "$(jq -r '.fields.mlat_user.edited_by' <<<"$SYNC_OUT")" = "legacy" ]
}

@test "GEO_CONFIGURED=false tombstones position even with non-empty coords" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="120"
GEO_CONFIGURED=false
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.position.value' <<<"$SYNC_OUT")" = "null" ]
}

@test "empty LATITUDE tombstones position" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE=""
LONGITUDE="8.0"
ALTITUDE="120"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.position.value' <<<"$SYNC_OUT")" = "null" ]
}

@test "position edited_at is max of LATITUDE and LONGITUDE stamps (atomic group)" {
    # apl_feed_apply stamps both axes with the same now() in the normal
    # case (MIN == MAX). In the divergent-stamps edge case, MAX reflects
    # when the position state was last changed — the symmetric LWW gate
    # in _config_sync_apply_response uses MAX too so atomicity holds.
    seed_feed_env
    seed_feed_meta LATITUDE "2026-05-14T12:00:00Z" LONGITUDE "2026-05-10T08:00:00Z"

    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.position.edited_at' <<<"$SYNC_OUT")" = "2026-05-14T12:00:00Z" ]
}

@test "empty MLAT_USER emits null tombstone" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
GEO_CONFIGURED=true
ALTITUDE="120"
MLAT_USER=""
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.mlat_user.value' <<<"$SYNC_OUT")" = "null" ]
}

@test "MLAT_ENABLED absent omits the field entirely (non-nullable bool)" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
GEO_CONFIGURED=true
ALTITUDE="120"
MLAT_USER="alice"
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields | has("mlat_enabled")' <<<"$SYNC_OUT")" = "false" ]
}

@test "outbound: ALTITUDE=120 emits alt.value as JSON number 120" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="120"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.alt.value' <<<"$SYNC_OUT")" = "120" ]
    [ "$(jq -r '.fields.alt.value | type' <<<"$SYNC_OUT")" = "number" ]
}

@test "outbound: legacy on-disk ALTITUDE=120m is canonicalized on the wire (defensive)" {
    # Migration-window safety net: a feeder whose airplanes-config-sync.timer
    # fires after picking up the new scripts but before update-migrations.sh
    # has run still emits a clean JSON number on the wire.
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="120m"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.alt.value' <<<"$SYNC_OUT")" = "120" ]
    [ "$(jq -r '.fields.alt.value | type' <<<"$SYNC_OUT")" = "number" ]
}

@test "outbound: legacy on-disk ALTITUDE=400ft is converted to 121.92 on the wire" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="400ft"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.alt.value' <<<"$SYNC_OUT")" = "121.92" ]
    [ "$(jq -r '.fields.alt.value | type' <<<"$SYNC_OUT")" = "number" ]
}

@test "outbound: empty ALTITUDE emits alt.value=null tombstone" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE=""
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.alt.value' <<<"$SYNC_OUT")" = "null" ]
}

@test "outbound: unparseable ALTITUDE omits .fields.alt entirely (NOT null)" {
    # Critical footgun guard: emitting alt.value=null with a fresh
    # feeder-side edited_at would let LWW wipe a valid website value
    # when the disk state is corrupt. Omit-on-garbage instead so the
    # server's last-known-good stays put; the operator's next edit
    # recovers.
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="not-a-number"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields | has("alt")' <<<"$SYNC_OUT")" = "false" ]
    echo "$SYNC_ERR" | grep -F 'reason=alt_unparseable'
}

@test "outbound: out-of-range ALTITUDE omits .fields.alt entirely" {
    # 33000ft -> ~10058m -> out of range. Same omit-on-corruption policy.
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="33000ft"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields | has("alt")' <<<"$SYNC_OUT")" = "false" ]
    echo "$SYNC_ERR" | grep -F 'reason=alt_unparseable'
}

@test "inbound: server alt.value=42.5 lands on disk as ALTITUDE=\"42.5\" (bare metres, no suffix)" {
    seed_feed_env
    seed_feed_meta ALTITUDE "2026-05-10T00:00:00Z"
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "alt": {"value": 42.5, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "website"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    grep -F 'ALTITUDE="42.5"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "inbound: server alt.value=null lands on disk as ALTITUDE=\"\" when MLAT disabled" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="120"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
REMOTE_CONFIG_ENABLED=true
EOF
    seed_feed_meta ALTITUDE "2026-05-10T00:00:00Z"
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "alt": {"value": null, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "website"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    grep -F 'ALTITUDE=""' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "200 unowned heartbeat touches sentinel and skips apply" {
    seed_feed_env
    set_canned 200 '{"schema_version":1,"server_time":"2026-05-14T12:00:00Z","owned":false}'

    run_sync

    [ "$SYNC_RC" -eq 0 ]
    [ -f "$AIRPLANES_CONFIG_SYNC_LAST_SUCCESS" ]
    grep -F 'level=info' "$ROOT_DIR/sync.err" 2>/dev/null || true
    # apl-feed apply would write to feed.env or systemd; assert
    # systemctl wasn't called for a restart.
    if [ -f "$SYSTEMCTL_LOG" ]; then
        ! grep -F 'restart' "$SYSTEMCTL_LOG"
    fi
}

@test "log line carries host= tag from WEBSITE_URL" {
    seed_feed_env
    set_canned 200 '{"schema_version":1,"server_time":"2026-05-14T12:00:00Z","owned":false}'
    # apl-feed.sh runs in a subshell — must export so common.sh picks it up.
    export APL_FEED_WEBSITE_URL='http://feed.airplanes.test:8080/v1'
    run_sync
    unset APL_FEED_WEBSITE_URL
    [ "$SYNC_RC" -eq 0 ]
    [[ "$SYNC_ERR" == *"host=feed.airplanes.test:8080"* ]]
}

@test "200 applied response runs apl_feed_apply with server tuples" {
    seed_feed_env
    seed_feed_meta MLAT_USER "2026-05-10T00:00:00Z"
    # Server returns a newer mlat_user="bob".
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "position": {"value": {"lat": 47.0, "lon": 8.0}, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
            "alt": {"value": 120, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
            "mlat_user": {"value": "bob", "edited_at": "2026-05-14T11:00:00Z", "edited_by": "website"},
            "mlat_enabled": {"value": true, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
            "mlat_private": {"value": false, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    # Feed.env should reflect bob now.
    grep -F 'MLAT_USER="bob"' "$ROOT_DIR/etc/airplanes/feed.env"
    # Sidecar should carry the website tuple.
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "website" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "2026-05-14T11:00:00Z" ]
    [ -f "$AIRPLANES_CONFIG_SYNC_LAST_SUCCESS" ]
}

@test "200 applied with rejected_fields adopts server tuple to heal" {
    seed_feed_env
    # Bogus future on-disk stamp — server will reject and return a heal tuple.
    seed_feed_meta MLAT_USER "3000-01-01T00:00:00Z"
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "rejected_fields": ["mlat_user"],
        "fields": {
            "position": {"value": {"lat": 47.0, "lon": 8.0}, "edited_at": "2020-01-01T00:00:00Z", "edited_by": "legacy"},
            "alt": {"value": 120, "edited_at": "2020-01-01T00:00:00Z", "edited_by": "legacy"},
            "mlat_user": {"value": "alice", "edited_at": "2026-05-14T11:00:00Z", "edited_by": "feeder"},
            "mlat_enabled": {"value": true, "edited_at": "2020-01-01T00:00:00Z", "edited_by": "legacy"},
            "mlat_private": {"value": false, "edited_at": "2020-01-01T00:00:00Z", "edited_by": "legacy"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    # Stamp must be healed to the server's tuple.
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "2026-05-14T11:00:00Z" ]
    echo "$SYNC_ERR" | grep -F 'rejected_fields'
}

@test "401 logs unauthorized and exits 0" {
    seed_feed_env
    set_canned 401 '{"error":"unauthorized"}'

    run_sync

    [ "$SYNC_RC" -eq 0 ]
    echo "$SYNC_ERR" | grep -F 'reason=unauthorized'
}

@test "423 data_blocked logs and exits 0" {
    seed_feed_env
    set_canned 423 '{"error":"blocked","reason":"data_blocked"}'

    run_sync

    [ "$SYNC_RC" -eq 0 ]
    echo "$SYNC_ERR" | grep -F 'block_reason=data_blocked'
}

@test "426 logs schema mismatch and exits 0" {
    seed_feed_env
    set_canned 426 '{"error":"schema_version_unsupported","supported":[2]}'

    run_sync

    [ "$SYNC_RC" -eq 0 ]
    echo "$SYNC_ERR" | grep -F 'reason=schema_version_unsupported'
}

@test "503 logs transport and exits 0" {
    seed_feed_env
    set_canned 503 '{"error":"server_error"}'

    run_sync

    [ "$SYNC_RC" -eq 0 ]
    echo "$SYNC_ERR" | grep -F 'reason=server_503'
}

@test "missing feeder-id exits 64" {
    seed_feed_env
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"

    run_sync

    [ "$SYNC_RC" -eq 64 ]
}

@test "missing claim secret exits 64" {
    seed_feed_env
    rm -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run_sync

    [ "$SYNC_RC" -eq 64 ]
    echo "$SYNC_ERR" | grep -F 'reason=missing_claim_secret'
}

@test "corrupt claim secret exits 64 (not 1 from die-in-substitution)" {
    seed_feed_env
    # Wrong format — validate_secret requires 16 chars [A-Z0-9].
    printf 'not-a-valid-secret\n' \
        > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"

    run_sync

    [ "$SYNC_RC" -eq 64 ]
    echo "$SYNC_ERR" | grep -F 'reason=invalid_claim_secret'
}

@test "corrupt feed.meta.json edited_at falls back to legacy tuple" {
    seed_feed_env
    cat > "$ROOT_DIR/etc/airplanes/feed.meta.json" <<EOF
{"schema_version":1,"fields":{"MLAT_USER":{"edited_at":"this is not RFC 3339","edited_by":"feeder"}}}
EOF

    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.mlat_user.edited_at' <<<"$SYNC_OUT")" = "2020-01-01T00:00:00Z" ]
    [ "$(jq -r '.fields.mlat_user.edited_by' <<<"$SYNC_OUT")" = "legacy" ]
}

@test "unknown edited_by value in sidecar falls back to legacy tuple" {
    seed_feed_env
    cat > "$ROOT_DIR/etc/airplanes/feed.meta.json" <<EOF
{"schema_version":1,"fields":{"MLAT_USER":{"edited_at":"2026-05-12T10:00:00Z","edited_by":"attacker"}}}
EOF

    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.mlat_user.edited_by' <<<"$SYNC_OUT")" = "legacy" ]
    [ "$(jq -r '.fields.mlat_user.edited_at' <<<"$SYNC_OUT")" = "2020-01-01T00:00:00Z" ]
}

@test "response edited_by={feeder,website,legacy} all apply normally" {
    # Sanity: each accepted actor label produces a normal apply.
    seed_feed_env
    seed_feed_meta MLAT_USER "2026-05-10T00:00:00Z" \
                   ALTITUDE "2026-05-10T00:00:00Z" \
                   LATITUDE "2026-05-10T00:00:00Z" \
                   LONGITUDE "2026-05-10T00:00:00Z"
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "position": {"value": {"lat": 47.0, "lon": 8.0}, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "legacy"},
            "alt": {"value": 200, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "feeder"},
            "mlat_user": {"value": "bob", "edited_at": "2026-05-14T11:00:00Z", "edited_by": "website"},
            "mlat_enabled": {"value": true, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "feeder"},
            "mlat_private": {"value": false, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "feeder"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    grep -F 'MLAT_USER="bob"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -F 'ALTITUDE="200"' "$ROOT_DIR/etc/airplanes/feed.env"
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "website" ]
    [ "$(jq -r '.fields.ALTITUDE.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "feeder" ]
    [ "$(jq -r '.fields.LATITUDE.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "legacy" ]
}

@test "response edited_by outside allowlist drops only the offending field" {
    # Server response carries a bogus actor label on mlat_user. That
    # field must be dropped (logged with reason=bad_edited_by), but the
    # other fields in the same response must still apply.
    seed_feed_env
    seed_feed_meta MLAT_USER "2026-05-10T00:00:00Z" \
                   ALTITUDE "2026-05-10T00:00:00Z"
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "alt": {"value": 200, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "feeder"},
            "mlat_user": {"value": "mallory", "edited_at": "2026-05-14T11:00:00Z", "edited_by": "attacker"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    echo "$SYNC_ERR" | grep -F 'reason=bad_edited_by'
    echo "$SYNC_ERR" | grep -F 'field=mlat_user'
    # mlat_user value on disk is untouched.
    grep -F 'MLAT_USER="alice"' "$ROOT_DIR/etc/airplanes/feed.env"
    # Sidecar entry for MLAT_USER is unchanged (still feeder + the seeded stamp).
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "feeder" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "2026-05-10T00:00:00Z" ]
    # The well-formed field still applied.
    grep -F 'ALTITUDE="200"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "response edited_by with embedded space/equals is logged as a quoted token" {
    # An attacker-controlled value must not forge extra key=value pairs in
    # the structured log line. The dropped-field log entry quotes the value.
    seed_feed_env
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "alt": {"value": 200, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "evil reason=spoofed"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    echo "$SYNC_ERR" | grep -F 'reason=bad_edited_by'
    echo "$SYNC_ERR" | grep -F 'field=alt'
    # The hostile value must appear quoted, so a downstream parser cannot
    # mistake `reason=spoofed` for a new log key.
    echo "$SYNC_ERR" | grep -F 'value="evil reason=spoofed"'
}

@test "response position edited_by outside allowlist drops both axes atomically" {
    # The translator emits LATITUDE+LONGITUDE entries from a single
    # `position` line — when that line is dropped for bad edited_by,
    # neither axis must end up applied.
    seed_feed_env
    seed_feed_meta LATITUDE "2026-05-10T00:00:00Z" LONGITUDE "2026-05-10T00:00:00Z"
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "position": {"value": {"lat": 99.9, "lon": 99.9}, "edited_at": "2026-05-14T11:00:00Z", "edited_by": "rogue"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    echo "$SYNC_ERR" | grep -F 'reason=bad_edited_by'
    echo "$SYNC_ERR" | grep -F 'field=position'
    # On-disk position must be unchanged.
    grep -F 'LATITUDE="47.0"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -F 'LONGITUDE="8.0"' "$ROOT_DIR/etc/airplanes/feed.env"
}

@test "position group skips atomically when only one axis is newer locally" {
    # Hand-divergent on-disk stamps: LATITUDE was edited locally just
    # now, LONGITUDE is still on the 2020 legacy seed. Server returns a
    # position tuple older than LATITUDE but newer than LONGITUDE — a
    # naive per-key gate would apply LON (server) while skipping LAT
    # (local). The atomic position-group decision in config.sh must
    # skip both axes together.
    seed_feed_env
    cat > "$ROOT_DIR/etc/airplanes/feed.meta.json" <<EOF
{
  "schema_version": 1,
  "fields": {
    "LATITUDE":  {"edited_at": "2026-05-14T11:59:00Z", "edited_by": "feeder"},
    "LONGITUDE": {"edited_at": "2020-01-01T00:00:00Z", "edited_by": "legacy"}
  }
}
EOF
    # Server returns a position older than LATITUDE but newer than LONGITUDE.
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "position": {"value": {"lat": 99.9, "lon": 99.9}, "edited_at": "2026-05-14T11:30:00Z", "edited_by": "website"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    # Position must NOT be partially applied. LATITUDE stays 47.0, LONGITUDE stays 8.0.
    grep -F 'LATITUDE="47.0"' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -F 'LONGITUDE="8.0"' "$ROOT_DIR/etc/airplanes/feed.env"
    echo "$SYNC_ERR" | grep -F 'reason=position_group_skipped_by_lww'
}

@test "airplanes-config-sync.service owns its StateDirectory, not the shared /var/lib/airplanes" {
    # Regression guard for the first-boot race: the unit must provision its own
    # StateDirectory (created by systemd before the mount namespace) instead of
    # depending on airplanes-diagnostics having created /var/lib/airplanes. A
    # ReadWritePaths= bind to a not-yet-existent /var/lib/airplanes fails
    # namespace setup (status=226/NAMESPACE) when config-sync.timer fires first.
    local unit="$REPO_ROOT/scripts/airplanes-config-sync.service"
    run grep -qE '^StateDirectory=airplanes-config-sync$' "$unit"
    [ "$status" -eq 0 ]
    run grep -E '^ReadWritePaths=' "$unit"
    [ "$status" -eq 0 ]
    [[ "$output" != *"/var/lib/airplanes"* ]]
}

# --- Diagnostics push on the unowned→owned claim edge ---------------------

@test "200 owned records owned=true and does not start diagnostics under --root" {
    seed_feed_env
    seed_feed_meta MLAT_USER "2026-05-10T00:00:00Z"
    set_canned 200 '{
        "schema_version": 1,
        "server_time": "2026-05-14T12:00:00Z",
        "owned": true,
        "fields": {
            "position": {"value": {"lat": 47.0, "lon": 8.0}, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
            "alt": {"value": 120, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
            "mlat_user": {"value": "alice", "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
            "mlat_enabled": {"value": true, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
            "mlat_private": {"value": false, "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"}
        }
    }'

    run_sync --no-restart

    [ "$SYNC_RC" -eq 0 ]
    grep -qx 'owned=true' "$AIRPLANES_CONFIG_SYNC_STATE"
    # The state was absent, so this is an unowned→owned edge — but the trigger
    # must still be suppressed because the sync ran with --root.
    if [ -f "$SYSTEMCTL_LOG" ]; then
        ! grep -F 'airplanes-diagnostics.service' "$SYSTEMCTL_LOG"
    fi
}

@test "200 unowned records owned=false in the config-sync state file" {
    seed_feed_env
    set_canned 200 '{"schema_version":1,"server_time":"2026-05-14T12:00:00Z","owned":false}'

    run_sync

    [ "$SYNC_RC" -eq 0 ]
    grep -qx 'owned=false' "$AIRPLANES_CONFIG_SYNC_STATE"
}

# The edge trigger itself is host-root-only, so exercise it by calling the
# helper directly with ROOT=/ and the setup() systemctl stub on PATH.
_source_config_sh() {
    # shellcheck source=../scripts/apl-feed/config.sh
    source "$REPO_ROOT/scripts/apl-feed/config.sh"
    ROOT="/"
    WEBSITE_HOST=""
    CONFIG_SYNC_STATE_FILE="$ROOT_DIR/state"
}

@test "edge false->true triggers one diagnostics push" {
    _source_config_sh
    _config_sync_record_owned false 0
    : > "$SYSTEMCTL_LOG"
    _config_sync_record_owned true 0
    grep -F 'start --no-block airplanes-diagnostics.service' "$SYSTEMCTL_LOG"
    grep -qx 'owned=true' "$CONFIG_SYNC_STATE_FILE"
}

@test "no edge true->true does not re-trigger" {
    _source_config_sh
    _config_sync_record_owned true 0
    : > "$SYSTEMCTL_LOG"
    _config_sync_record_owned true 0
    if [ -f "$SYSTEMCTL_LOG" ]; then
        ! grep -F 'airplanes-diagnostics.service' "$SYSTEMCTL_LOG"
    fi
}

@test "owned=false does not trigger" {
    _source_config_sh
    : > "$SYSTEMCTL_LOG"
    _config_sync_record_owned false 0
    if [ -f "$SYSTEMCTL_LOG" ]; then
        ! grep -F 'airplanes-diagnostics.service' "$SYSTEMCTL_LOG"
    fi
}

@test "missing prior state makes the first owned=true an edge" {
    _source_config_sh
    [ ! -f "$CONFIG_SYNC_STATE_FILE" ]
    : > "$SYSTEMCTL_LOG"
    _config_sync_record_owned true 0
    grep -F 'start --no-block airplanes-diagnostics.service' "$SYSTEMCTL_LOG"
}

@test "--no-restart suppresses the edge trigger" {
    _source_config_sh
    _config_sync_record_owned false 0
    : > "$SYSTEMCTL_LOG"
    _config_sync_record_owned true 1
    if [ -f "$SYSTEMCTL_LOG" ]; then
        ! grep -F 'airplanes-diagnostics.service' "$SYSTEMCTL_LOG"
    fi
}

@test "non-host root suppresses the edge trigger" {
    _source_config_sh
    ROOT="$ROOT_DIR"
    _config_sync_record_owned false 0
    : > "$SYSTEMCTL_LOG"
    _config_sync_record_owned true 0
    if [ -f "$SYSTEMCTL_LOG" ]; then
        ! grep -F 'airplanes-diagnostics.service' "$SYSTEMCTL_LOG"
    fi
}

@test "systemctl trigger failure is non-fatal and still records owned=true" {
    _source_config_sh
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$STUB_DIR/systemctl"
    _config_sync_record_owned false 0
    run _config_sync_record_owned true 0
    [ "$status" -eq 0 ]
    grep -qx 'owned=true' "$CONFIG_SYNC_STATE_FILE"
}
