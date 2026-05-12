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
ALTITUDE="120m"
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
