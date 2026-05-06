#!/usr/bin/env bats
# Tests for chown_claim_state, the chown integration in
# write_secret_file / write_version_file, and heal_claim_state_ownership.
# The helpers shell out to /usr/bin/id, /usr/bin/getent, and /bin/chown
# which we shadow via PATH stubs so the tests don't need real root or a
# real airplanes-feed user/group.

setup() {
    BATS_TMPDIR_TEST="$(mktemp -d)"
    STUB_BIN_DIR="$BATS_TMPDIR_TEST/bin"
    mkdir -p "$STUB_BIN_DIR"
    CHOWN_LOG="$BATS_TMPDIR_TEST/chown.log"

    # Default stubs: act like a non-root user so chown_claim_state is a
    # no-op. Individual tests override id/getent/chown as needed.
    cat > "$STUB_BIN_DIR/id" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
STUB
    cat > "$STUB_BIN_DIR/getent" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$STUB_BIN_DIR/chown" <<STUB
#!/usr/bin/env bash
echo "chown \$*" >> "$CHOWN_LOG"
STUB
    chmod +x "$STUB_BIN_DIR"/{id,getent,chown}
    PATH="$STUB_BIN_DIR:$PATH"
    export PATH

    # shellcheck source=../scripts/apl-feed/common.sh
    source "$BATS_TEST_DIRNAME/../scripts/apl-feed/common.sh"
    # shellcheck source=../scripts/lib/claim-registration.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/claim-registration.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR_TEST"
}

# Helper: simulate root.
become_root_stub() {
    cat > "$STUB_BIN_DIR/id" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
STUB
    chmod +x "$STUB_BIN_DIR/id"
}

# Helper: simulate target user missing (both `getent passwd` and `getent
# group` lookups return NOTFOUND).
user_missing_stub() {
    cat > "$STUB_BIN_DIR/getent" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
    chmod +x "$STUB_BIN_DIR/getent"
}

# Helper: simulate user existing but the matching group missing (passwd
# lookup returns success, group lookup returns NOTFOUND).
group_missing_stub() {
    cat > "$STUB_BIN_DIR/getent" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    passwd) exit 0 ;;
    group)  exit 2 ;;
    *)      exit 0 ;;
esac
STUB
    chmod +x "$STUB_BIN_DIR/getent"
}

@test "chown_claim_state no-op when file is missing" {
    become_root_stub
    chown_claim_state "$BATS_TMPDIR_TEST/missing"
    [[ ! -f "$CHOWN_LOG" ]]
}

@test "chown_claim_state no-op when not running as root" {
    : > "$BATS_TMPDIR_TEST/file"
    chown_claim_state "$BATS_TMPDIR_TEST/file"
    [[ ! -f "$CHOWN_LOG" ]]
}

@test "chown_claim_state no-op when target user is missing" {
    become_root_stub
    user_missing_stub
    : > "$BATS_TMPDIR_TEST/file"
    chown_claim_state "$BATS_TMPDIR_TEST/file"
    [[ ! -f "$CHOWN_LOG" ]]
}

@test "chown_claim_state no-op when target group is missing" {
    become_root_stub
    group_missing_stub
    : > "$BATS_TMPDIR_TEST/file"
    chown_claim_state "$BATS_TMPDIR_TEST/file"
    # User exists, group doesn't — chown would fail with "invalid group",
    # so the helper short-circuits before invoking it.
    [[ ! -f "$CHOWN_LOG" ]]
}

@test "chown_claim_state sets owner:group when root + both exist" {
    become_root_stub
    : > "$BATS_TMPDIR_TEST/file"
    chown_claim_state "$BATS_TMPDIR_TEST/file"
    grep -qF "chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/file" "$CHOWN_LOG"
}

@test "chown_claim_state respects APL_FEED_SECRET_OWNER override" {
    become_root_stub
    : > "$BATS_TMPDIR_TEST/file"
    APL_FEED_SECRET_OWNER=other-feed chown_claim_state "$BATS_TMPDIR_TEST/file"
    grep -qF "chown other-feed:other-feed $BATS_TMPDIR_TEST/file" "$CHOWN_LOG"
}

@test "chown_claim_state respects APL_FEED_SECRET_GROUP override (split owner/group)" {
    become_root_stub
    : > "$BATS_TMPDIR_TEST/file"
    APL_FEED_SECRET_OWNER=feeder-user APL_FEED_SECRET_GROUP=claim-readers \
        chown_claim_state "$BATS_TMPDIR_TEST/file"
    grep -qF "chown feeder-user:claim-readers $BATS_TMPDIR_TEST/file" "$CHOWN_LOG"
}

@test "write_secret_file chowns + chmods the temp file before the rename" {
    become_root_stub
    write_secret_file "$BATS_TMPDIR_TEST/secret" "ABCD1234EFGH5678"
    # The chown target should have been the temp path (.$$ suffix), not the
    # final destination — chown-after-mv reordering would let a reader
    # observe wrong-owner state during the open window between rename and
    # chown.
    grep -qE "^chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/secret\.[0-9]+$" "$CHOWN_LOG"
    run grep -qE "^chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/secret$" "$CHOWN_LOG"
    [[ "$status" -ne 0 ]]
    [[ -f "$BATS_TMPDIR_TEST/secret" ]]
    [[ "$(cat "$BATS_TMPDIR_TEST/secret")" == "ABCD1234EFGH5678" ]]
    # Mode 0640: owner rw, group r, other none. Group-read is what lets
    # other service accounts in the airplanes-feed group consume the
    # secret without sudo.
    [[ "$(stat -c %a "$BATS_TMPDIR_TEST/secret")" == "640" ]]
}

@test "write_version_file chowns + chmods the temp file before the rename" {
    become_root_stub
    # write_version_file resolves via secret_version_path() which uses
    # ROOT — so we point ROOT at our tmpdir to redirect /etc/airplanes.
    ROOT="$BATS_TMPDIR_TEST"
    mkdir -p "$BATS_TMPDIR_TEST/etc/airplanes"
    write_version_file 7
    grep -qE "^chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/etc/airplanes/feeder-claim-secret\.version\.[0-9]+$" "$CHOWN_LOG"
    [[ -f "$BATS_TMPDIR_TEST/etc/airplanes/feeder-claim-secret.version" ]]
    [[ "$(cat "$BATS_TMPDIR_TEST/etc/airplanes/feeder-claim-secret.version")" == "7" ]]
    [[ "$(stat -c %a "$BATS_TMPDIR_TEST/etc/airplanes/feeder-claim-secret.version")" == "640" ]]
}

@test "write_secret_file no-op chown when not root, file still written 0640" {
    write_secret_file "$BATS_TMPDIR_TEST/secret" "ABCD1234EFGH5678"
    [[ ! -f "$CHOWN_LOG" ]]
    [[ -f "$BATS_TMPDIR_TEST/secret" ]]
    [[ "$(cat "$BATS_TMPDIR_TEST/secret")" == "ABCD1234EFGH5678" ]]
    [[ "$(stat -c %a "$BATS_TMPDIR_TEST/secret")" == "640" ]]
}

@test "write_secret_file with chown failure leaves no published final file" {
    become_root_stub
    # Override chown to fail. The temp file gets created but chown returns
    # non-zero; under set -e (the apl-feed CLI's posture) write_secret_file
    # aborts before the mv, so the final path stays unpublished. Better
    # than publishing a root:root file that other users can't read.
    cat > "$STUB_BIN_DIR/chown" <<STUB
#!/usr/bin/env bash
echo "chown \$*" >> "$CHOWN_LOG"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/chown"
    set +e
    ( set -e; write_secret_file "$BATS_TMPDIR_TEST/secret" "ABCD1234EFGH5678" )
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]]
    [[ ! -f "$BATS_TMPDIR_TEST/secret" ]]
}

@test "heal_claim_state_ownership chowns + chmods existing claim-state files" {
    : > "$BATS_TMPDIR_TEST/feeder-claim-secret"
    : > "$BATS_TMPDIR_TEST/feeder-claim-secret.pending"
    : > "$BATS_TMPDIR_TEST/feeder-claim-secret.version"
    chmod 600 "$BATS_TMPDIR_TEST"/feeder-claim-secret*
    heal_claim_state_ownership "$BATS_TMPDIR_TEST"
    grep -qF "chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/feeder-claim-secret" "$CHOWN_LOG"
    grep -qF "chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/feeder-claim-secret.pending" "$CHOWN_LOG"
    grep -qF "chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/feeder-claim-secret.version" "$CHOWN_LOG"
    # chmod is a real call (not stubbed); the file mode should reflect it.
    [[ "$(stat -c %a "$BATS_TMPDIR_TEST/feeder-claim-secret")" == "640" ]]
    [[ "$(stat -c %a "$BATS_TMPDIR_TEST/feeder-claim-secret.pending")" == "640" ]]
    [[ "$(stat -c %a "$BATS_TMPDIR_TEST/feeder-claim-secret.version")" == "640" ]]
}

@test "heal_claim_state_ownership skips files that don't exist" {
    : > "$BATS_TMPDIR_TEST/feeder-claim-secret"
    # No .pending or .version
    heal_claim_state_ownership "$BATS_TMPDIR_TEST"
    grep -qF "chown airplanes-feed:airplanes-feed $BATS_TMPDIR_TEST/feeder-claim-secret" "$CHOWN_LOG"
    run grep -qF "feeder-claim-secret.pending" "$CHOWN_LOG"
    [[ "$status" -ne 0 ]]
    run grep -qF "feeder-claim-secret.version" "$CHOWN_LOG"
    [[ "$status" -ne 0 ]]
}

@test "heal_claim_state_ownership warns to stderr on chown failure but does not abort" {
    : > "$BATS_TMPDIR_TEST/feeder-claim-secret"
    : > "$BATS_TMPDIR_TEST/feeder-claim-secret.version"
    cat > "$STUB_BIN_DIR/chown" <<STUB
#!/usr/bin/env bash
echo "chown \$*" >> "$CHOWN_LOG"
exit 1
STUB
    chmod +x "$STUB_BIN_DIR/chown"
    run heal_claim_state_ownership "$BATS_TMPDIR_TEST"
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "WARNING: failed to chown" ]]
    [[ "$output" =~ "feeder-claim-secret" ]]
    [[ "$output" =~ "airplanes-feed:airplanes-feed" ]]
}

@test "heal_claim_state_ownership respects APL_FEED_SECRET_OWNER + GROUP overrides" {
    : > "$BATS_TMPDIR_TEST/feeder-claim-secret"
    APL_FEED_SECRET_OWNER=feeder-user APL_FEED_SECRET_GROUP=claim-readers \
        heal_claim_state_ownership "$BATS_TMPDIR_TEST"
    grep -qF "chown feeder-user:claim-readers $BATS_TMPDIR_TEST/feeder-claim-secret" "$CHOWN_LOG"
}
