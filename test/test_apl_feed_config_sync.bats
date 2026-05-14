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

    AIRPLANES_CONFIG_SYNC_LAST_SUCCESS="$ROOT_DIR/var/lib/airplanes/config-sync-last-success"
    export AIRPLANES_CONFIG_SYNC_LAST_SUCCESS
}

teardown() {
    rm -rf "$ROOT_DIR"
}

seed_feed_env() {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
ALTITUDE="120m"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
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
    [ "$(jq -r '.fields.alt.value' <<<"$payload")" = "120m" ]
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
ALTITUDE="120m"
GEO_CONFIGURED=false
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
EOF
    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.position.value' <<<"$SYNC_OUT")" = "null" ]
}

@test "empty LATITUDE tombstones position" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE=""
LONGITUDE="8.0"
ALTITUDE="120m"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.position.value' <<<"$SYNC_OUT")" = "null" ]
}

@test "position edited_at is min of LATITUDE and LONGITUDE stamps" {
    seed_feed_env
    seed_feed_meta LATITUDE "2026-05-14T12:00:00Z" LONGITUDE "2026-05-10T08:00:00Z"

    run_sync --dry-run

    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields.position.edited_at' <<<"$SYNC_OUT")" = "2026-05-10T08:00:00Z" ]
}

@test "empty MLAT_USER emits null tombstone" {
    cat > "$ROOT_DIR/etc/airplanes/feed.env" <<EOF
LATITUDE="47.0"
LONGITUDE="8.0"
GEO_CONFIGURED=true
ALTITUDE="120m"
MLAT_USER=""
MLAT_ENABLED=false
MLAT_PRIVATE=false
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
ALTITUDE="120m"
MLAT_USER="alice"
MLAT_PRIVATE=false
EOF
    run_sync --dry-run
    [ "$SYNC_RC" -eq 0 ]
    [ "$(jq -r '.fields | has("mlat_enabled")' <<<"$SYNC_OUT")" = "false" ]
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
            "alt": {"value": "120m", "edited_at": "2026-05-10T10:00:00Z", "edited_by": "feeder"},
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
            "alt": {"value": "120m", "edited_at": "2020-01-01T00:00:00Z", "edited_by": "legacy"},
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
