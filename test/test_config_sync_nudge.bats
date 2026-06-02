#!/usr/bin/env bats
#
# Unit tests for nudge_config_sync_if_present and the
# claim_secret_landed_side_effects grouping helper, both defined in
# scripts/apl-feed/common.sh. Source-based so the helpers run in the
# test's own shell — that lets us override the `command` builtin to fake
# out `command -v systemctl` lookups (a PATH stub can hide our stubbed
# systemctl but can't make the real /usr/bin/systemctl disappear from the
# rest of PATH).
#
# Integration coverage (the nudge fires at the right time inside
# claim_register / claim_set / restore and stays silent on failure paths)
# lives in test_claim_register.bats and test_apl_feed_cli.bats.

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

# Hide systemctl from `command -v` so the no-systemctl branch is reachable
# even on CI runners and dev boxes where /usr/bin/systemctl is preinstalled.
_hide_systemctl_from_command_v() {
    command() {
        if [[ "$1" = "-v" && "$2" = "systemctl" ]]; then
            return 1
        fi
        builtin command "$@"
    }
}

@test "nudge_config_sync_if_present invokes systemctl --no-block start on ROOT=/" {
    ROOT="/"
    run nudge_config_sync_if_present
    [ "$status" -eq 0 ]
    grep -F -- '--no-block start airplanes-config-sync.service' "$COMMAND_LOG"
}

@test "nudge_config_sync_if_present skips silently when ROOT != / without the force env" {
    ROOT="/tmp/somerootfs"
    unset APL_FEED_TEST_CONFIG_SYNC_NUDGE_FORCE
    run nudge_config_sync_if_present
    [ "$status" -eq 0 ]
    [ ! -s "$COMMAND_LOG" ]
}

@test "nudge_config_sync_if_present runs anyway when APL_FEED_TEST_CONFIG_SYNC_NUDGE_FORCE=1" {
    # Test seam used by the integration bats files so they can keep using
    # --root for filesystem fixtures while still exercising the helper.
    ROOT="/tmp/somerootfs"
    APL_FEED_TEST_CONFIG_SYNC_NUDGE_FORCE=1
    run nudge_config_sync_if_present
    [ "$status" -eq 0 ]
    grep -F -- '--no-block start airplanes-config-sync.service' "$COMMAND_LOG"
}

@test "nudge_config_sync_if_present is silent with no systemctl in PATH" {
    # Manual installs on non-systemd hosts (or chroots) shouldn't error.
    _hide_systemctl_from_command_v
    ROOT="/"
    run nudge_config_sync_if_present
    [ "$status" -eq 0 ]
    [ ! -s "$COMMAND_LOG" ]
}

@test "nudge_config_sync_if_present exits 0 even when systemctl exits non-zero" {
    # A host without the unit yet (or a transient systemd hiccup) returns
    # non-zero from `systemctl start`. The trailing `|| true` must absorb it
    # so the calling claim path still ends at `return 0`.
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$COMMAND_LOG"
exit 1
STUB
    chmod +x "$STUB_DIR/systemctl"
    ROOT="/"
    run nudge_config_sync_if_present
    [ "$status" -eq 0 ]
    grep -F -- '--no-block start airplanes-config-sync.service' "$COMMAND_LOG"
}

@test "nudge_config_sync_if_present passes the documented argv (pinned)" {
    # Pin the exact argv: --no-block (returns immediately; the oneshot does a
    # network round-trip), start (run it now rather than wait for the timer),
    # airplanes-config-sync.service (the unit the image side ships).
    ROOT="/"
    run nudge_config_sync_if_present
    [ "$status" -eq 0 ]
    local logged; logged="$(cat "$COMMAND_LOG")"
    [ "$logged" = "systemctl --no-block start airplanes-config-sync.service" ]
}

@test "claim_secret_landed_side_effects stops the timer then nudges config-sync, in order" {
    ROOT="/"
    run claim_secret_landed_side_effects
    [ "$status" -eq 0 ]
    grep -F -- '--no-block stop airplanes-claim.timer' "$COMMAND_LOG"
    grep -F -- '--no-block start airplanes-config-sync.service' "$COMMAND_LOG"
    # Timer stop is logged before the config-sync nudge.
    local stop_line start_line
    stop_line="$(grep -n -F -- 'stop airplanes-claim.timer' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
    start_line="$(grep -n -F -- 'start airplanes-config-sync.service' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
    [ "$stop_line" -lt "$start_line" ]
}

@test "claim_secret_landed_side_effects honours both ROOT != / guards (silent)" {
    # On a chroot / build-mode run (ROOT != /) with neither force env set,
    # both side effects must stay silent so we never poke the host's systemd.
    ROOT="/tmp/somerootfs"
    unset APL_FEED_TEST_TIMER_STOP_FORCE
    unset APL_FEED_TEST_CONFIG_SYNC_NUDGE_FORCE
    run claim_secret_landed_side_effects
    [ "$status" -eq 0 ]
    [ ! -s "$COMMAND_LOG" ]
}
