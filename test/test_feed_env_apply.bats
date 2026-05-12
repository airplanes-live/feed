#!/usr/bin/env bats

# Direct tests for the apl_feed_apply library function in
# scripts/lib/feed-env-apply.sh. Calls the function directly (not via
# `run`, which would lose the result globals to a subshell) and
# captures the exit code into APL_APPLY_RC so per-test assertions can
# read APL_APPLY_STATUS / APL_APPLY_CHANGED / APL_APPLY_ERRORS afterwards.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/scripts/lib"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    mkdir -p "$STUB_DIR" "$ROOT_DIR/etc/airplanes" "$ROOT_DIR/run/airplanes"

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$LIB/configure-validators.sh"
    # shellcheck source=../scripts/lib/feed-env-keys.sh
    source "$LIB/feed-env-keys.sh"
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$LIB/feed-env-apply.sh"
    eval "$bats_exit_trap"

    FEED_ENV="$ROOT_DIR/etc/airplanes/feed.env"
    LOCK_FILE="$ROOT_DIR/run/airplanes/feed-env.lock"

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$ROOT_DIR"
}

seed_feed_env() {
    cat > "$FEED_ENV" <<EOF
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="120m"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
GAIN=auto
UAT_INPUT=""
DUMP978_SDR_SERIAL=""
DUMP978_GAIN=44.5
INPUT="127.0.0.1:30005"
INPUT_TYPE=dump1090
EOF
}

# Run the library function and capture its exit code into APL_APPLY_RC
# without aborting the test on non-zero. Result globals (APL_APPLY_STATUS,
# APL_APPLY_CHANGED, APL_APPLY_ERRORS, APL_APPLY_PENDING_RESTART) are
# available to the caller afterwards.
do_apply() {
    APL_APPLY_RC=0
    apl_feed_apply --feed-env "$FEED_ENV" --lock-file "$LOCK_FILE" "$@" || APL_APPLY_RC=$?
}

@test "empty payload returns no_change without touching feed.env" {
    seed_feed_env
    cp "$FEED_ENV" "$FEED_ENV.before"
    do_apply
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "no_change" ]
    diff -u "$FEED_ENV.before" "$FEED_ENV"
}

@test "single key change rewrites the value and lists it as dirty" {
    seed_feed_env
    do_apply --no-restart MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "${APL_APPLY_CHANGED[*]}" = "MLAT_PRIVATE" ]
    grep -q '^MLAT_PRIVATE="true"$' "$FEED_ENV"
    grep -q '^MLAT_USER="alice"$' "$FEED_ENV"
    grep -q '^GAIN="auto"$' "$FEED_ENV"
}

@test "rejects bad LATITUDE without touching feed.env" {
    seed_feed_env
    cp "$FEED_ENV" "$FEED_ENV.before"
    do_apply --no-restart LATITUDE=200
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[LATITUDE]}" ]
    diff -u "$FEED_ENV.before" "$FEED_ENV"
}

@test "rejects shell metacharacter via universal-reject" {
    seed_feed_env
    do_apply --no-restart 'MLAT_USER=alice;rm'
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[MLAT_USER]}" ]
}

@test "rejects MLAT_ENABLED=true without geo (consistency check)" {
    : > "$FEED_ENV"
    do_apply --no-restart MLAT_ENABLED=true
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[GEO_CONFIGURED]}" ]
}

@test "GEO_CONFIGURED auto-derives to true on non-zero coordinates" {
    : > "$FEED_ENV"
    do_apply --no-restart LATITUDE=52.5 LONGITUDE=13.4
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^GEO_CONFIGURED="true"$' "$FEED_ENV"
}

@test "GEO_CONFIGURED auto-derives to false on zero coordinates" {
    cat > "$FEED_ENV" <<EOF
LATITUDE="1"
LONGITUDE="1"
GEO_CONFIGURED=true
EOF
    do_apply --no-restart LATITUDE=0 LONGITUDE=0
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^GEO_CONFIGURED="false"$' "$FEED_ENV"
}

@test "explicit GEO_CONFIGURED in payload overrides auto-derive" {
    : > "$FEED_ENV"
    do_apply --no-restart LATITUDE=52.5 LONGITUDE=13.4 GEO_CONFIGURED=false
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^GEO_CONFIGURED="false"$' "$FEED_ENV"
}

@test "boundary: LATITUDE=90 accepted (closed range)" {
    : > "$FEED_ENV"
    do_apply --no-restart LATITUDE=90 LONGITUDE=0 GEO_CONFIGURED=true
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^LATITUDE="90"$' "$FEED_ENV"
}

@test "boundary: LONGITUDE=180 accepted (closed range)" {
    : > "$FEED_ENV"
    do_apply --no-restart LATITUDE=0 LONGITUDE=180 GEO_CONFIGURED=true
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^LONGITUDE="180"$' "$FEED_ENV"
}

@test "boundary: ALTITUDE=10000 accepted (closed range)" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=10000m
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="10000m"$' "$FEED_ENV"
}

@test "ALTITUDE accepts decimals (120.5m)" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=120.5m
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="120.5m"$' "$FEED_ENV"
}

@test "ALTITUDE canonicalizes 120 (no suffix) to 120m on disk" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=120
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="120m"$' "$FEED_ENV"
}

@test "ALTITUDE rejects 10001 (out of range)" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=10001m
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
}

@test "MLAT_USER empty is accepted (daemon Anonymous-fallback)" {
    seed_feed_env
    do_apply --no-restart MLAT_USER=
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^MLAT_USER=""$' "$FEED_ENV"
}

@test "MLAT_USER with space is rejected" {
    seed_feed_env
    do_apply --no-restart 'MLAT_USER=alice rabbit'
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
}

@test "no_change when payload matches existing value" {
    seed_feed_env
    cp "$FEED_ENV" "$FEED_ENV.before"
    do_apply --no-restart MLAT_PRIVATE=false
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "no_change" ]
    diff -u "$FEED_ENV.before" "$FEED_ENV"
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "MLAT_ENABLED change restarts airplanes-mlat" {
    seed_feed_env
    do_apply MLAT_ENABLED=false
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^systemctl restart airplanes-mlat$' "$SYSTEMCTL_LOG"
}

@test "LATITUDE change restarts the full geo fan-out" {
    seed_feed_env
    do_apply LATITUDE=48.13
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^systemctl restart readsb$' "$SYSTEMCTL_LOG"
    grep -q '^systemctl restart airplanes-feed$' "$SYSTEMCTL_LOG"
    grep -q '^systemctl restart airplanes-978$' "$SYSTEMCTL_LOG"
    grep -q '^systemctl restart airplanes-mlat$' "$SYSTEMCTL_LOG"
}

@test "GEO_CONFIGURED-only change does not restart anything" {
    cat > "$FEED_ENV" <<EOF
LATITUDE="1"
LONGITUDE="1"
GEO_CONFIGURED=false
EOF
    do_apply GEO_CONFIGURED=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "--no-restart skips systemctl regardless of dirty keys" {
    seed_feed_env
    do_apply --no-restart MLAT_ENABLED=false
    [ "$APL_APPLY_RC" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "build mode skips systemctl regardless of dirty keys" {
    seed_feed_env
    AIRPLANES_BUILD_MODE=1 do_apply MLAT_ENABLED=false
    [ "$APL_APPLY_RC" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "atomic write preserves file mode" {
    seed_feed_env
    chmod 0640 "$FEED_ENV"
    do_apply --no-restart MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$(stat -c '%a' "$FEED_ENV")" = "640" ]
}

@test "lock contention: second caller waits then succeeds" {
    seed_feed_env
    mkdir -p "$(dirname "$LOCK_FILE")"
    (
        flock 200
        sleep 1
        exec 200>&-
    ) 200>"$LOCK_FILE" &
    holder_pid=$!
    sleep 0.1
    do_apply --no-restart --lock-timeout 5 MLAT_PRIVATE=true
    wait "$holder_pid"
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^MLAT_PRIVATE="true"$' "$FEED_ENV"
}

@test "lock timeout: short timeout returns lock_timeout status" {
    seed_feed_env
    mkdir -p "$(dirname "$LOCK_FILE")"
    (
        flock 200
        sleep 2
        exec 200>&-
    ) 200>"$LOCK_FILE" &
    holder_pid=$!
    sleep 0.1
    do_apply --no-restart --lock-timeout 0 MLAT_PRIVATE=true
    wait "$holder_pid"
    [ "$APL_APPLY_RC" -eq 4 ]
    [ "$APL_APPLY_STATUS" = "lock_timeout" ]
}

@test "unknown key rejected" {
    seed_feed_env
    do_apply --no-restart BOGUS=1
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[BOGUS]}" ]
}

@test "comments and blank lines in feed.env preserved across rewrite" {
    cat > "$FEED_ENV" <<EOF
# A user comment
LATITUDE="10"

LONGITUDE="20"
EOF
    do_apply --no-restart LATITUDE=11
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^LATITUDE="11"$' "$FEED_ENV"
    grep -q '^LONGITUDE="20"$' "$FEED_ENV"
}

@test "MLAT_ENABLED=true accepted when consistency holds" {
    cat > "$FEED_ENV" <<EOF
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="120m"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
EOF
    do_apply --no-restart MLAT_ENABLED=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^MLAT_ENABLED="true"$' "$FEED_ENV"
}

@test "altitude-only edit does NOT flip explicit GEO_CONFIGURED" {
    cat > "$FEED_ENV" <<EOF
LATITUDE="0"
LONGITUDE="0"
ALTITUDE="100m"
GEO_CONFIGURED=true
EOF
    do_apply --no-restart ALTITUDE=150m
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^GEO_CONFIGURED="true"$' "$FEED_ENV"
}

@test "missing feed.env is rejected (no silent bootstrap)" {
    rm -f "$FEED_ENV"
    do_apply --no-restart MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 3 ]
    [ "$APL_APPLY_STATUS" = "filesystem_error" ]
    [ ! -f "$FEED_ENV" ]
}

@test "preserved value with forbidden character is rejected" {
    # Hand-edited feed.env with a shell metachar in a preserved key.
    # Re-emitting it during a normal save would bake it into the new
    # file; the library must reject instead.
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
GAIN="auto"
EOF
    # Append a dangerous preserved value that bypasses the per-key
    # validator path because we are not touching that key in the payload.
    printf 'DUMP978_SDR_SERIAL="bad`payload`"\n' >> "$FEED_ENV"
    do_apply --no-restart MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[DUMP978_SDR_SERIAL]}" ]
}

@test "malformed feed.env lines silently dropped" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
GARBAGE_LINE_WITHOUT_EQUALS
LONGITUDE="13.4"
GEO_CONFIGURED=true
ALTITUDE="100m"
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
9_BAD_LEADING_DIGIT_KEY="x"
EOF
    do_apply --no-restart MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^MLAT_PRIVATE="true"$' "$FEED_ENV"
    # Malformed keys/lines do not survive the rewrite.
    ! grep -q '^GARBAGE_LINE' "$FEED_ENV"
    ! grep -q '^9_BAD' "$FEED_ENV"
}

@test "comment after bare value rejected as malformed" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
GEO_CONFIGURED=true
ALTITUDE="100m"
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
GAIN=auto # this is a comment
EOF
    do_apply --no-restart MLAT_PRIVATE=true
    # The malformed GAIN line is dropped, so the merged map sees no
    # GAIN key. That's fine — the payload only touches MLAT_PRIVATE.
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    # The rewritten file must NOT contain the broken comment-tail.
    ! grep -q 'this is a comment' "$FEED_ENV"
}

@test "missing feed.env without --create-if-missing returns filesystem_error" {
    [ ! -e "$FEED_ENV" ]
    do_apply --no-restart MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 3 ]
    [ "$APL_APPLY_STATUS" = "filesystem_error" ]
    [ ! -e "$FEED_ENV" ]
}

@test "missing feed.env with --create-if-missing: file created inside lock, payload applied" {
    [ ! -e "$FEED_ENV" ]
    do_apply --no-restart --create-if-missing MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ -f "$FEED_ENV" ]
    grep -qE '^MLAT_PRIVATE="?true"?$' "$FEED_ENV"
}

@test "--create-if-missing + rejected payload leaves no file behind" {
    # The library creates the canonical file inside the lock only after
    # the payload passes per-key validation. A rejected payload should
    # not leak an empty file onto disk where a status reader would see
    # it instead of the legacy fallback.
    [ ! -e "$FEED_ENV" ]
    do_apply --no-restart --create-if-missing LATITUDE=999
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ ! -e "$FEED_ENV" ]
}

@test "--create-if-missing is idempotent when feed.env already exists" {
    seed_feed_env
    cp "$FEED_ENV" "$FEED_ENV.before"
    do_apply --no-restart --create-if-missing MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -qE '^MLAT_PRIVATE="?true"?$' "$FEED_ENV"
    # Original keys preserved.
    grep -q '^MLAT_USER="alice"$' "$FEED_ENV"
}
