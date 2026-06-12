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

    # `cat` answers with an ExecStart under /usr/local/share/airplanes/ so
    # the apply lib's unit-ownership gate treats every unit as ours by
    # default; the foreign-unit tests override this stub per-test.
    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
if [ "\$1" = cat ]; then
    printf 'ExecStart=/usr/local/share/airplanes/%s.sh\n' "\${@: -1}"
fi
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    # No-op logger stub so the apply-time journald audit (added in the
    # journal-audit feature) doesn't reach the host's real /dev/log.
    cat > "$STUB_DIR/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/logger"
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
ALTITUDE="120"
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

@test "boundary: ALTITUDE=10000m accepted (closed range, canonicalized to bare metres)" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=10000m
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="10000"$' "$FEED_ENV"
}

@test "ALTITUDE accepts decimals (120.5m, canonicalized to bare metres)" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=120.5m
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="120.5"$' "$FEED_ENV"
}

@test "ALTITUDE canonicalizes 120m (m-suffixed) to bare 120 on disk" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=120m
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="120"$' "$FEED_ENV"
}

@test "ALTITUDE bare 120 round-trips unchanged" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=120
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="120"$' "$FEED_ENV"
}

@test "ALTITUDE converts 400ft to 121.92 (bare metres)" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=400ft
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="121.92"$' "$FEED_ENV"
}

@test "ALTITUDE rejects 10001m (out of range, metres)" {
    seed_feed_env
    do_apply --no-restart ALTITUDE=10001m
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
}

@test "ALTITUDE rejects 33000ft (out of range; post-conversion ~10058m)" {
    # Pre-existing valid_altitude range-gated raw 33000 > 10000 by sheer
    # coincidence. Post-conversion range-gating catches this case the way
    # the website's serializer does.
    seed_feed_env
    do_apply --no-restart ALTITUDE=33000ft
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
}

@test "ALTITUDE accepts 20000ft (in range; post-conversion ~6096m)" {
    # The old raw-range rule rejected 20000ft as out-of-range integer-bound.
    # The new post-conversion rule accepts it because the result lives
    # well inside [-1000, 10000] metres.
    seed_feed_env
    do_apply --no-restart ALTITUDE=20000ft
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^ALTITUDE="6096"$' "$FEED_ENV"
}

@test "ALTITUDE empty (tombstone) lands on disk as empty string" {
    # Inbound `alt.value: null` -> _config_sync_translate_response emits
    # `ALTITUDE=` (empty value). The apply layer must accept it and write
    # ALTITUDE="" on disk. Without this path, the next sync cycle wedges
    # with validation_failed.
    cat > "$FEED_ENV" <<EOF
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="120"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=false
MLAT_PRIVATE=false
EOF
    do_apply --no-restart ALTITUDE=
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^ALTITUDE=""$' "$FEED_ENV"
}

@test "ALTITUDE empty rejected when MLAT_ENABLED=true (consistency check unchanged)" {
    # Tombstone-passthrough on the validator does NOT relax the cross-key
    # consistency rule: MLAT_ENABLED=true requires ALTITUDE non-empty.
    cat > "$FEED_ENV" <<EOF
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="120"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
EOF
    do_apply --no-restart ALTITUDE=
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[ALTITUDE]}" ]
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

@test "READSB_SDR_SERIAL change restarts readsb and nothing else" {
    seed_feed_env
    do_apply READSB_SDR_SERIAL=1090
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "${APL_APPLY_CHANGED[*]}" = "READSB_SDR_SERIAL" ]
    grep -q '^READSB_SDR_SERIAL="1090"$' "$FEED_ENV"
    grep -q '^systemctl restart readsb$' "$SYSTEMCTL_LOG"
    ! grep -q 'restart airplanes-feed' "$SYSTEMCTL_LOG"
    ! grep -q 'restart airplanes-mlat' "$SYSTEMCTL_LOG"
    ! grep -q 'restart airplanes-978' "$SYSTEMCTL_LOG"
    ! grep -q 'restart dump978-fa' "$SYSTEMCTL_LOG"
}

@test "clearing READSB_SDR_SERIAL also restarts readsb" {
    seed_feed_env
    printf 'READSB_SDR_SERIAL="1090"\n' >> "$FEED_ENV"
    do_apply READSB_SDR_SERIAL=
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "${APL_APPLY_CHANGED[*]}" = "READSB_SDR_SERIAL" ]
    grep -q '^READSB_SDR_SERIAL=""$' "$FEED_ENV"
    grep -q '^systemctl restart readsb$' "$SYSTEMCTL_LOG"
}

@test "rejects bad READSB_SDR_SERIAL without touching feed.env or restarting" {
    seed_feed_env
    cp "$FEED_ENV" "$FEED_ENV.before"
    do_apply READSB_SDR_SERIAL="$(printf 'a%.0s' {1..33})"
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[READSB_SDR_SERIAL]}" ]
    diff -u "$FEED_ENV.before" "$FEED_ENV"
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "GAIN and READSB_SDR_SERIAL in one apply restart readsb once" {
    seed_feed_env
    do_apply GAIN=43.9 READSB_SDR_SERIAL=1090
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "$(grep -c '^systemctl restart readsb$' "$SYSTEMCTL_LOG")" -eq 1 ]
}

# Replace the systemctl stub with one where the named units exist but
# belong to a third-party package (ExecStart outside our install tree),
# while every other unit stays ours. Models a PiAware box, where
# dump978-fa.service is FlightAware's, or a wiedehopf adsb-scripts box,
# where readsb.service ExecStarts /usr/bin/readsb.
stub_foreign_units() {
    local foreign="$*"
    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
if [ "\$1" = cat ]; then
    unit="\${@: -1}"
    case " $foreign " in
        *" \$unit "*) printf 'ExecStart=/usr/bin/%s\n' "\$unit" ;;
        *) printf 'ExecStart=/usr/local/share/airplanes/%s.sh\n' "\$unit" ;;
    esac
fi
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
}

@test "UAT_INPUT change skips a foreign dump978-fa unit" {
    seed_feed_env
    stub_foreign_units dump978-fa airplanes-978
    do_apply UAT_INPUT=127.0.0.1:30978
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^systemctl restart airplanes-feed$' "$SYSTEMCTL_LOG"
    run grep -q '^systemctl restart dump978-fa$' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
    run grep -q '^systemctl restart airplanes-978$' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
    # Skipped foreign units are not failures.
    [ "${#APL_APPLY_PENDING_RESTART[@]}" -eq 0 ]
}

@test "GAIN change skips a foreign readsb unit" {
    seed_feed_env
    stub_foreign_units readsb
    do_apply GAIN=38.6
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    run grep -q '^systemctl restart readsb$' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
    [ "${#APL_APPLY_PENDING_RESTART[@]}" -eq 0 ]
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

@test "APL_FEED_WEBSITE_URL is preserved through config-sync rewrite" {
    # Non-writable keys (here: the WEBSITE_URL pointer written by the
    # image's first-run from airplanes-config.txt) must survive every
    # apply pass — otherwise a homelab-pointed Pi would silently re-home
    # to prod on the first config-sync tick.
    cat > "$FEED_ENV" <<EOF
APL_FEED_WEBSITE_URL="http://homelab.airplanes.test"
LATITUDE="52.5"
LONGITUDE="13.4"
EOF
    do_apply --no-restart LATITUDE=53.0
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^APL_FEED_WEBSITE_URL="http://homelab.airplanes.test"$' "$FEED_ENV"
    grep -q '^LATITUDE="53.0"$' "$FEED_ENV"
}

@test "MLAT_ENABLED=true accepted when consistency holds" {
    cat > "$FEED_ENV" <<EOF
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="120"
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
ALTITUDE="100"
GEO_CONFIGURED=true
EOF
    do_apply --no-restart ALTITUDE=150m
    [ "$APL_APPLY_RC" -eq 0 ]
    grep -q '^GEO_CONFIGURED="true"$' "$FEED_ENV"
    grep -q '^ALTITUDE="150"$' "$FEED_ENV"
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
ALTITUDE="100"
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
ALTITUDE="100"
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

# ---------------------------------------------------------------------------
# feed.meta.json sidecar (DEV-380)
# ---------------------------------------------------------------------------

# Default meta path is dirname($FEED_ENV)/feed.meta.json. Tests reference
# $ROOT_DIR/etc/airplanes/feed.meta.json directly because ROOT_DIR is only
# valid inside a test body (after setup()); a file-scope reference would
# expand to /etc/airplanes/feed.meta.json on the host. A dedicated test
# below proves the lib's auto-derive itself.

@test "metadata object payload stamps feed.meta.json with the caller's tuple" {
    seed_feed_env
    APL_APPLY_INCOMING_META_EDITED_AT=([MLAT_USER]="2026-05-12T10:00:00Z")
    APL_APPLY_INCOMING_META_EDITED_BY=([MLAT_USER]="website")
    do_apply --no-restart MLAT_USER=bob
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
    [ "$(jq -r '.schema_version' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "1" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "2026-05-12T10:00:00Z" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "website" ]
    # Clean up input arrays so they don't leak into the next test.
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

@test "bare-string change to tracked field stamps default feeder+now metadata" {
    seed_feed_env
    do_apply --no-restart MLAT_USER=bob
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "feeder"  ]
    # Current-ish timestamp — assert RFC 3339 shape (regex). Strict equality
    # would require freezing the clock. iso_now emits microsecond precision
    # so two writes within the same second produce distinct stamps under the
    # LWW gate; the regex permits the optional fractional segment.
    EDITED_AT="$(jq -r '.fields.MLAT_USER.edited_at' "$ROOT_DIR/etc/airplanes/feed.meta.json")"
    [[ "$EDITED_AT" =~ ^2[0-9]{3}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]
}

@test "unchanged tracked key with no incoming metadata leaves prior tuple intact" {
    seed_feed_env
    cat > "$ROOT_DIR/etc/airplanes/feed.meta.json" <<EOF
{"schema_version":1,"fields":{"MLAT_USER":{"edited_at":"2020-01-01T00:00:00Z","edited_by":"legacy"}}}
EOF
    # Apply a no-op (MLAT_USER already alice) — meta file untouched.
    do_apply --no-restart MLAT_USER=alice
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "2020-01-01T00:00:00Z" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "legacy" ]
}

@test "object-form metadata reconciles sidecar even when value matches on-disk" {
    # Closes the stuck-future-timestamp hole: a feeder with a bogus future
    # edited_at must reconcile to the server's tuple even if .value is the
    # same as on-disk after canonicalization.
    seed_feed_env
    cat > "$ROOT_DIR/etc/airplanes/feed.meta.json" <<EOF
{"schema_version":1,"fields":{"MLAT_USER":{"edited_at":"3000-01-01T00:00:00Z","edited_by":"feeder"}}}
EOF
    APL_APPLY_INCOMING_META_EDITED_AT=([MLAT_USER]="2026-05-12T10:00:00Z")
    APL_APPLY_INCOMING_META_EDITED_BY=([MLAT_USER]="website")
    # Value matches on-disk; only metadata differs.
    do_apply --no-restart MLAT_USER=alice
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_at' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "2026-05-12T10:00:00Z" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "website" ]
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

@test "untracked key change does not touch sidecar" {
    seed_feed_env
    do_apply --no-restart GAIN=42.5
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ ! -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
}

@test "mixed tracked + untracked: only the tracked key gets a meta entry" {
    seed_feed_env
    do_apply --no-restart MLAT_USER=carol GAIN=42.5
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
    [ "$(jq -r '.fields | has("MLAT_USER")' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "true" ]
    [ "$(jq -r '.fields | has("GAIN")' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "false" ]
}

@test "non-tracked key with incoming metadata is rejected (no write)" {
    seed_feed_env
    cp "$FEED_ENV" "$FEED_ENV.before"
    APL_APPLY_INCOMING_META_EDITED_AT=([GAIN]="2026-05-12T10:00:00Z")
    APL_APPLY_INCOMING_META_EDITED_BY=([GAIN]="website")
    do_apply --no-restart GAIN=42.5
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[GAIN]:-}" ]
    diff -u "$FEED_ENV.before" "$FEED_ENV"
    [ ! -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

@test "incoming edited_by not in {feeder,website,legacy} is rejected" {
    seed_feed_env
    APL_APPLY_INCOMING_META_EDITED_AT=([MLAT_USER]="2026-05-12T10:00:00Z")
    APL_APPLY_INCOMING_META_EDITED_BY=([MLAT_USER]="some-other-actor")
    do_apply --no-restart MLAT_USER=carol
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[MLAT_USER]:-}" ]
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

@test "incoming edited_at not matching RFC 3339 regex is rejected" {
    seed_feed_env
    APL_APPLY_INCOMING_META_EDITED_AT=([MLAT_USER]="yesterday at noon")
    APL_APPLY_INCOMING_META_EDITED_BY=([MLAT_USER]="website")
    do_apply --no-restart MLAT_USER=carol
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[MLAT_USER]:-}" ]
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

@test "sidecar write failure preserves feed.env update and sets pending_meta_warning" {
    seed_feed_env
    # Make the meta directory not creatable: replace it with a regular file.
    # mkdir -p on existing-but-not-a-directory will fail.
    rm -rf "$ROOT_DIR/etc/airplanes"
    # Recreate a stand-in feed.env path: directory holding feed.env exists,
    # but the sidecar's intended directory does not.
    mkdir -p "$ROOT_DIR/etc/airplanes"
    seed_feed_env
    # Override meta path to one whose parent dir cannot be created.
    BAD_META="$ROOT_DIR/etc/airplanes/feed.env/feed.meta.json"
    do_apply --no-restart --meta-file "$BAD_META" MLAT_USER=daniela
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^MLAT_USER="daniela"$' "$FEED_ENV"
    [ -n "$APL_APPLY_PENDING_META_WARNING" ]
}

@test "existing sidecar with malformed entries is dropped on next write" {
    seed_feed_env
    cat > "$ROOT_DIR/etc/airplanes/feed.meta.json" <<'EOF'
{"schema_version":1,"fields":{"MLAT_USER":"bad-shape","ALTITUDE":{"edited_at":"2026-05-12T10:00:00Z","edited_by":"website"}}}
EOF
    # Trigger a write on a DIFFERENT field (MLAT_PRIVATE) — the read should
    # drop MLAT_USER (bad shape) and keep ALTITUDE (good shape).
    do_apply --no-restart MLAT_PRIVATE=true
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    # Bad MLAT_USER entry gone.
    [ "$(jq -r '.fields | has("MLAT_USER")' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "false" ]
    # Preserved ALTITUDE tuple survives.
    [ "$(jq -r '.fields.ALTITUDE.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "website" ]
    # New MLAT_PRIVATE got stamped (default feeder).
    [ "$(jq -r '.fields.MLAT_PRIVATE.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "feeder" ]
}

@test "feed.meta.json is created with mode 0664" {
    seed_feed_env
    do_apply --no-restart MLAT_USER=eric
    [ "$APL_APPLY_RC" -eq 0 ]
    [ -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
    # GNU stat is fine on the CI runner (ubuntu-24.04); test/macOS uses
    # docker for Ubuntu parity per rules/testing.md.
    MODE="$(stat -c '%a' "$ROOT_DIR/etc/airplanes/feed.meta.json" 2>/dev/null || stat -f '%A' "$ROOT_DIR/etc/airplanes/feed.meta.json")"
    [ "$MODE" = "664" ]
}

@test "default meta_path derives from feed_env dirname when --meta-file omitted" {
    seed_feed_env
    do_apply --no-restart MLAT_USER=fiona
    [ "$APL_APPLY_RC" -eq 0 ]
    # Expected default path is dirname($FEED_ENV)/feed.meta.json.
    [ -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
}

@test "--meta-file overrides the default sidecar path" {
    seed_feed_env
    OVERRIDE="$ROOT_DIR/custom-meta.json"
    do_apply --no-restart --meta-file "$OVERRIDE" MLAT_USER=greta
    [ "$APL_APPLY_RC" -eq 0 ]
    [ -f "$OVERRIDE" ]
    # Default path NOT created.
    [ ! -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
}

@test "build mode does not create sidecar (no /run lock held)" {
    seed_feed_env
    AIRPLANES_BUILD_MODE=1 do_apply --no-restart MLAT_USER=hank
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    grep -q '^MLAT_USER="hank"$' "$FEED_ENV"
    # Sidecar block is gated on lock_fd being held, which build mode skips.
    [ ! -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
}

@test "stale INCOMING_META for a key not in payload is rejected" {
    # Codex-flagged footgun: a long-lived shell could leave INCOMING_META
    # set from a previous call and silently rewrite metadata for an
    # unintended field. Subset check makes that an explicit reject.
    seed_feed_env
    cp "$FEED_ENV" "$FEED_ENV.before"
    APL_APPLY_INCOMING_META_EDITED_AT=([ALTITUDE]="2026-05-12T10:00:00Z")
    APL_APPLY_INCOMING_META_EDITED_BY=([ALTITUDE]="website")
    do_apply --no-restart MLAT_USER=bob
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ -n "${APL_APPLY_ERRORS[ALTITUDE]:-}" ]
    diff -u "$FEED_ENV.before" "$FEED_ENV"
    [ ! -f "$ROOT_DIR/etc/airplanes/feed.meta.json" ]
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

@test "stale INCOMING_META with empty payload is rejected (not silently applied)" {
    seed_feed_env
    APL_APPLY_INCOMING_META_EDITED_AT=([MLAT_USER]="2026-05-12T10:00:00Z")
    APL_APPLY_INCOMING_META_EDITED_BY=([MLAT_USER]="website")
    do_apply --no-restart
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

@test "sidecar write fails cleanly when meta_path exists as a directory" {
    seed_feed_env
    META_DIR="$ROOT_DIR/etc/airplanes/feed.meta.json"
    mkdir -p "$META_DIR"
    do_apply --no-restart MLAT_USER=kate
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    # feed.env still updated.
    grep -q '^MLAT_USER="kate"$' "$FEED_ENV"
    # The directory wasn't replaced and no tmp file was orphaned inside it.
    [ -d "$META_DIR" ]
    [ "$(find "$META_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)" = "0" ]
    [ -n "$APL_APPLY_PENDING_META_WARNING" ]
}

@test "INCOMING_META survives across two consecutive apply calls in the same shell" {
    seed_feed_env
    APL_APPLY_INCOMING_META_EDITED_AT=([MLAT_USER]="2026-05-12T11:00:00Z")
    APL_APPLY_INCOMING_META_EDITED_BY=([MLAT_USER]="website")
    do_apply --no-restart MLAT_USER=irene
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "website" ]
    # Caller did NOT clear; second call should still see the same input
    # state (snapshot is per-call, not consumed at exit).
    do_apply --no-restart MLAT_USER=julia
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$ROOT_DIR/etc/airplanes/feed.meta.json")" = "website" ]
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}
