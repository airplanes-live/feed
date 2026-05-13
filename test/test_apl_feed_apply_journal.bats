#!/usr/bin/env bats

# Journald audit coverage for apl_feed_apply. Stubs logger(1) to record
# its argv into LOGGER_LOG and asserts the audit line is emitted (or
# suppressed) by each gate.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/scripts/lib"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    LOGGER_LOG="$ROOT_DIR/logger.log"
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

    # Recording logger stub. Captures argv per invocation so each test
    # can assert exactly what (or what was NOT) audited.
    cat > "$STUB_DIR/logger" <<STUB
#!/usr/bin/env bash
printf 'logger %s\n' "\$*" >> "$LOGGER_LOG"
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

do_apply() {
    APL_APPLY_RC=0
    apl_feed_apply --feed-env "$FEED_ENV" --lock-file "$LOCK_FILE" "$@" || APL_APPLY_RC=$?
}

@test "single key change emits one audit line listing the key and new value" {
    seed_feed_env
    do_apply MLAT_USER=bob
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ -s "$LOGGER_LOG" ]
    [ "$(wc -l < "$LOGGER_LOG")" -eq 1 ]
    grep -F 'applied: MLAT_USER="bob"' "$LOGGER_LOG"
    # Tag and priority flags should also be present. `--` stops grep
    # from parsing the leading `-` as an option.
    grep -F -- '-t apl-feed-apply' "$LOGGER_LOG"
    grep -F -- '-p user.info' "$LOGGER_LOG"
}

@test "multi key change emits one audit line listing every changed key" {
    seed_feed_env
    do_apply MLAT_USER=carol MLAT_PRIVATE=true ALTITUDE=200
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "$(wc -l < "$LOGGER_LOG")" -eq 1 ]
    grep -F 'MLAT_USER="carol"' "$LOGGER_LOG"
    grep -F 'MLAT_PRIVATE="true"' "$LOGGER_LOG"
    # ALTITUDE canonicalises to suffixed form (200 -> 200m).
    grep -F 'ALTITUDE="200m"' "$LOGGER_LOG"
}

@test "no_change outcome emits no audit line" {
    seed_feed_env
    do_apply MLAT_USER=alice
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ ! -s "$LOGGER_LOG" ]
}

@test "rejected outcome emits no audit line" {
    seed_feed_env
    do_apply LATITUDE=200
    [ "$APL_APPLY_RC" -eq 2 ]
    [ "$APL_APPLY_STATUS" = "rejected" ]
    [ ! -s "$LOGGER_LOG" ]
}

@test "--no-audit suppresses the audit line even on successful change" {
    seed_feed_env
    do_apply --no-audit MLAT_USER=dave
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ ! -s "$LOGGER_LOG" ]
}

@test "--no-audit is orthogonal to --no-restart" {
    seed_feed_env
    do_apply --no-restart MLAT_USER=erin
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    # --no-restart by itself MUST NOT suppress the audit.
    [ -s "$LOGGER_LOG" ]
    grep -F 'MLAT_USER="erin"' "$LOGGER_LOG"
}

@test "AIRPLANES_BUILD_MODE=1 suppresses the audit line" {
    seed_feed_env
    AIRPLANES_BUILD_MODE=1 do_apply MLAT_USER=frank
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ ! -s "$LOGGER_LOG" ]
}

@test "missing logger(1) does not abort the apply" {
    seed_feed_env
    # Removing the stub alone isn't enough — PATH still falls through
    # to /usr/bin/logger on a real Debian/Ubuntu host. Shadow `command`
    # so the lib's `command -v logger` returns false, while leaving
    # every other `command -v` lookup unchanged.
    rm -f "$STUB_DIR/logger"
    command() {
        if [[ "$1" == "-v" && "$2" == "logger" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    do_apply MLAT_USER=grace
    unset -f command
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ ! -s "$LOGGER_LOG" ]
}

@test "logger exiting non-zero does not abort the apply" {
    seed_feed_env
    cat > "$STUB_DIR/logger" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
    chmod +x "$STUB_DIR/logger"
    do_apply MLAT_USER=heidi
    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
}
