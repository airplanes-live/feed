#!/usr/bin/env bats

# Tests for the `apl-feed apply` and `apl-feed schema` JSON adapters in
# scripts/apl-feed/{apply,schema}.sh. Exercises the JSON-on-stdin/stdout
# contract that webconfig will speak when this lands.
#
# Run via `bash` directly against the CLI binary (apl-feed.sh) so we
# also cover dispatch + adapter wiring, not just the library.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    mkdir -p "$STUB_DIR" "$ROOT_DIR/etc/airplanes" "$ROOT_DIR/run/airplanes"

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    PATH="$STUB_DIR:$PATH"
    export PATH

    FEED_ENV="$ROOT_DIR/etc/airplanes/feed.env"
    cat > "$FEED_ENV" <<EOF
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="120"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
GAIN=auto
EOF
}

teardown() {
    rm -rf "$ROOT_DIR"
}

run_apply() {
    local payload="$1"
    shift
    APPLY_OUT=""
    APPLY_RC=0
    # `|| APPLY_RC=$?` keeps `set -e` from aborting the test body on a
    # non-zero exit (rejected/parse_error/lock_timeout/etc). The expression
    # only fires on non-zero, so APPLY_RC stays 0 for status=applied.
    APPLY_OUT="$(printf '%s' "$payload" \
        | "$REPO_ROOT/scripts/apl-feed.sh" apply --root "$ROOT_DIR" "$@" 2>/dev/null)" \
        || APPLY_RC=$?
}

@test "schema emits {version, writable_keys, readable_keys}" {
    OUT="$("$REPO_ROOT/scripts/apl-feed.sh" schema --root "$ROOT_DIR" 2>/dev/null)"
    [ "$(jq -r .version <<<"$OUT")" = "1" ]
    [ "$(jq -r '.writable_keys | type' <<<"$OUT")" = "array" ]
    [ "$(jq -r '.readable_keys | type' <<<"$OUT")" = "array" ]
    [ "$(jq -r '.writable_keys | contains(["LATITUDE","LONGITUDE","MLAT_ENABLED"])' <<<"$OUT")" = "true" ]
    [ "$(jq -r '.readable_keys | contains(["INPUT","INPUT_TYPE"])' <<<"$OUT")" = "true" ]
}

@test "apply with empty payload returns no_change" {
    cp "$FEED_ENV" "$FEED_ENV.before"
    run_apply '{"updates":{}}' --no-restart
    [ "$APPLY_RC" -eq 0 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "no_change" ]
    diff -u "$FEED_ENV.before" "$FEED_ENV"
}

@test "apply with valid payload returns applied + changed list" {
    run_apply '{"updates":{"MLAT_PRIVATE":"true"}}' --no-restart
    [ "$APPLY_RC" -eq 0 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "applied" ]
    [ "$(jq -r '.changed | sort | join(",")' <<<"$APPLY_OUT")" = "MLAT_PRIVATE" ]
    grep -q '^MLAT_PRIVATE="true"$' "$FEED_ENV"
}

@test "apply with invalid LATITUDE returns rejected + per-key errors" {
    run_apply '{"updates":{"LATITUDE":"200"}}' --no-restart
    [ "$APPLY_RC" -eq 2 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "rejected" ]
    [ "$(jq -r '.errors.LATITUDE' <<<"$APPLY_OUT")" != "null" ]
}

@test "apply with malformed JSON returns parse_error" {
    run_apply 'not json' --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply with non-string update value returns parse_error" {
    run_apply '{"updates":{"LATITUDE":42}}' --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply with non-writable key returns rejected" {
    run_apply '{"updates":{"INPUT":"127.0.0.1:30005"}}' --no-restart
    [ "$APPLY_RC" -eq 2 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "rejected" ]
    [ "$(jq -r '.errors.INPUT' <<<"$APPLY_OUT")" != "null" ]
}

@test "apply --root implicitly skips restarts (no host service touch)" {
    run_apply '{"updates":{"MLAT_PRIVATE":"true"}}'
    [ "$APPLY_RC" -eq 0 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "applied" ]
    # --root != "/" forces --no-restart through the adapter so the test
    # runner's stubbed systemctl is never called.
    [ ! -s "$SYSTEMCTL_LOG" ]
}

# ---------------------------------------------------------------------------
# feed.meta.json sidecar via the JSON adapter (DEV-380)
# ---------------------------------------------------------------------------

# Default sidecar path under --root.
META_FILE_FOR_ROOT() { printf '%s\n' "$ROOT_DIR/etc/airplanes/feed.meta.json"; }

@test "apply with object-form metadata writes feed.meta.json" {
    PAYLOAD='{"updates":{"MLAT_USER":{"value":"bob","edited_at":"2026-05-12T10:00:00Z","edited_by":"website"}}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 0 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "applied" ]
    META="$(META_FILE_FOR_ROOT)"
    [ -f "$META" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$META")" = "2026-05-12T10:00:00Z" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$META")" = "website" ]
}

@test "apply with mixed bare/object updates forwards metadata for the object form only" {
    PAYLOAD='{"updates":{"MLAT_USER":{"value":"carol","edited_at":"2026-05-12T10:00:00Z","edited_by":"website"},"MLAT_PRIVATE":"true"}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 0 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "applied" ]
    META="$(META_FILE_FOR_ROOT)"
    # Object form → caller's tuple.
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$META")" = "website" ]
    # Bare-string change → default feeder stamp.
    [ "$(jq -r '.fields.MLAT_PRIVATE.edited_by' "$META")" = "feeder" ]
}

@test "apply rejects object form for non-tracked key with parse_error" {
    PAYLOAD='{"updates":{"GAIN":{"value":"42.5","edited_at":"2026-05-12T10:00:00Z","edited_by":"website"}}}'
    run_apply "$PAYLOAD" --no-restart
    # Adapter shape is valid (GAIN is a string-value-or-object key on the
    # wire); library rejects because GAIN is not in the tracked set.
    [ "$APPLY_RC" -eq 2 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "rejected" ]
    [ "$(jq -r '.errors.GAIN' <<<"$APPLY_OUT")" != "null" ]
}

@test "apply rejects object missing .value with parse_error" {
    PAYLOAD='{"updates":{"MLAT_USER":{"edited_at":"2026-05-12T10:00:00Z","edited_by":"website"}}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply rejects object missing .edited_at with parse_error" {
    PAYLOAD='{"updates":{"MLAT_USER":{"value":"bob","edited_by":"website"}}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply rejects edited_by not in {feeder,website,legacy}" {
    PAYLOAD='{"updates":{"MLAT_USER":{"value":"bob","edited_at":"2026-05-12T10:00:00Z","edited_by":"unknown"}}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply rejects edited_at not matching RFC 3339" {
    PAYLOAD='{"updates":{"MLAT_USER":{"value":"bob","edited_at":"yesterday","edited_by":"website"}}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply rejects edited_at with more than 6 fractional digits" {
    # The LWW normalize pads/truncates to microsecond precision. A
    # nanosecond-precision input would be silently truncated, which
    # can collapse strict-newer ordering under LWW. Reject at the wire
    # rather than accept-then-truncate.
    PAYLOAD='{"updates":{"MLAT_USER":{"value":"bob","edited_at":"2026-05-14T12:00:00.1234567Z","edited_by":"website"}}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply accepts edited_at with exactly 6 fractional digits" {
    PAYLOAD='{"updates":{"MLAT_USER":{"value":"bob","edited_at":"2026-05-14T12:00:00.123456Z","edited_by":"website"}}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 0 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "applied" ]
}

@test "malformed JSON returns structured parse_error (no bash abort)" {
    run_apply '{"updates":{"MLAT_USER":' --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply rejects keys with embedded newline (key-injection guard)" {
    # Without the key validator, jq -r '\(.key)=\(.value)' would split this
    # crafted key into two pairs after the newline.
    PAYLOAD='{"updates":{"GAIN=42.5\nMLAT_USER":"bob"}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
    # feed.env unchanged.
    grep -q '^GAIN=auto$' "$FEED_ENV"
    grep -q '^MLAT_USER="alice"$' "$FEED_ENV"
}

@test "apply rejects keys with embedded space (regex allows only A-Za-z0-9_)" {
    # Any non-alphanumeric/underscore byte in a key is rejected up front.
    PAYLOAD='{"updates":{"MLAT@USER":"bob"}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}

@test "apply rejects keys with `=` (would-be pair injection)" {
    PAYLOAD='{"updates":{"MLAT_USER=bob":"carol"}}'
    run_apply "$PAYLOAD" --no-restart
    [ "$APPLY_RC" -eq 5 ]
    [ "$(jq -r .status <<<"$APPLY_OUT")" = "parse_error" ]
}
