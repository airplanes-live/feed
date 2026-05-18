#!/usr/bin/env bats
#
# Unit tests for stop_claim_timer_if_present, defined in
# scripts/apl-feed/common.sh. Source-based so the helper runs in the
# test's own shell — that lets us override the `command` builtin to
# fake out `command -v systemctl` lookups (a PATH stub can hide our
# stubbed systemctl but can't make the real /usr/bin/systemctl
# disappear from the rest of PATH).
#
# Integration coverage (helper is invoked at the right time inside
# claim_register / claim_set, and is silent on failure paths) lives in
# test_claim_register.bats and test_apl_feed_cli.bats.

setup() {
    COMMON_LIB="$BATS_TEST_DIRNAME/../scripts/apl-feed/common.sh"
    STUB_DIR="$(mktemp -d)"
    COMMAND_LOG="$(mktemp)"

    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"

    OLD_PATH="$PATH"
    PATH="$STUB_DIR:$PATH"
    export PATH COMMAND_LOG

    # shellcheck source=/dev/null
    source "$COMMON_LIB"
}

teardown() {
    PATH="$OLD_PATH"
    rm -rf "$STUB_DIR"
    rm -f "$COMMAND_LOG"
}

# Helper: hide systemctl from `command -v` so the no-systemctl branch is
# reachable even on CI runners and dev boxes where /usr/bin/systemctl is
# preinstalled. Mirrors the _hide_ss_from_command_v pattern in
# test_apl_feed_status.bats.
_hide_systemctl_from_command_v() {
    command() {
        if [[ "$1" = "-v" && "$2" = "systemctl" ]]; then
            return 1
        fi
        builtin command "$@"
    }
}

@test "stop_claim_timer_if_present invokes systemctl --no-block stop on ROOT=/" {
    ROOT="/"
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    grep -F -- '--no-block stop airplanes-claim.timer' "$COMMAND_LOG"
}

@test "stop_claim_timer_if_present skips silently when ROOT != /" {
    ROOT="/tmp/somerootfs"
    unset APL_FEED_TEST_TIMER_STOP_FORCE
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    [ ! -s "$COMMAND_LOG" ]
}

@test "stop_claim_timer_if_present runs anyway when APL_FEED_TEST_TIMER_STOP_FORCE=1" {
    # Test seam used by the integration bats files so they can keep using
    # --root for filesystem fixtures while still exercising the helper.
    ROOT="/tmp/somerootfs"
    APL_FEED_TEST_TIMER_STOP_FORCE=1
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    grep -F -- '--no-block stop airplanes-claim.timer' "$COMMAND_LOG"
}

@test "stop_claim_timer_if_present is silent with no systemctl in PATH" {
    # Manual installs on non-systemd hosts (or chroots) shouldn't error.
    _hide_systemctl_from_command_v
    ROOT="/"
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    [ ! -s "$COMMAND_LOG" ]
}

@test "stop_claim_timer_if_present exits 0 even when systemctl exits non-zero" {
    # Legacy hosts without airplanes-claim.timer return non-zero from
    # `systemctl stop`. The helper's trailing `|| true` must absorb it so
    # the calling claim_register / claim_set still ends at `return 0`.
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 1
STUB
    chmod +x "$STUB_DIR/systemctl"
    ROOT="/"
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    grep -F -- '--no-block stop airplanes-claim.timer' "$COMMAND_LOG"
}

@test "stop_claim_timer_if_present is idempotent across repeat calls" {
    # claim_set on an already-claimed feeder hits the timer-stop branch
    # again; both calls must exit 0 even though the second one is a no-op
    # at the systemd level.
    ROOT="/"
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    # Both invocations should have hit the stub.
    [ "$(grep -c -F -- '--no-block stop airplanes-claim.timer' "$COMMAND_LOG")" = "2" ]
}

@test "stop_claim_timer_if_present passes the documented argv (pinned)" {
    # Pin the exact argv shape: --no-block (returns immediately so the
    # service can exit), stop (not disable — we keep the timer's enable
    # symlink so a future reclaim can re-arm it on reboot),
    # airplanes-claim.timer (the unit name the image side ships).
    ROOT="/"
    run stop_claim_timer_if_present
    [ "$status" -eq 0 ]
    local logged; logged="$(cat "$COMMAND_LOG")"
    [ "$logged" = "systemctl --no-block stop airplanes-claim.timer" ]
}
