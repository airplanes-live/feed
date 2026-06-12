#!/usr/bin/env bats

# Per-module unit tests for scripts/apl-feed/common.sh.
#
# End-to-end coverage of the apl-feed dispatcher lives in
# test_apl_feed_cli.bats. Claim-state ownership/permissions are tested
# in test_claim_state_chown.bats — chown_claim_state and
# write_secret_file are not retested here.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    mkdir -p "$TMPDIR" \
        "$ROOT_DIR/etc/airplanes" \
        "$ROOT_DIR/usr/local/share/airplanes" \
        "$ROOT_DIR/usr/bin" \
        "$ROOT_DIR/boot"
    export TMPDIR
    STUB_DIR="$ROOT_DIR/bin"
    mkdir -p "$STUB_DIR"
    APL_FEED_SECRET_OWNER="$(id -un)"
    APL_FEED_SECRET_GROUP="$(id -gn)"
    export APL_FEED_SECRET_OWNER APL_FEED_SECRET_GROUP

    # common.sh registers `trap cleanup_tmp_files EXIT` at source time,
    # which clobbers bats's own EXIT trap (the one that records skip /
    # fail status). Capture bats's trap first and reinstate it after
    # sourcing — without this, `skip` from inside a test silently
    # marks the test "not run".
    bats_exit_trap="$(trap -p EXIT)"
    # feed_env_get delegates to the strict reader; both production
    # consumers (apl-feed.sh, airplanes-diagnostics.sh) source the apply
    # lib before common.sh, so the harness mirrors that.
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-apply.sh"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Run a snippet under strict mode in a fresh subshell. Mirrors the
# dispatcher's `set -euo pipefail` posture and prevents `set +e`/`set -e`
# toggles inside sibling modules from leaking into the bats process.
run_strict() {
    run env \
        APL_FEED_SECRET_OWNER="$APL_FEED_SECRET_OWNER" \
        APL_FEED_SECRET_GROUP="$APL_FEED_SECRET_GROUP" \
        TMPDIR="$TMPDIR" \
        bash -c "
            set -euo pipefail
            source '$LIB_DIR/common.sh'
            ROOT='$ROOT_DIR'
            $1
        "
}

# --- root_path ---

@test "root_path: identity when ROOT='/'" {
    ROOT='/'
    run root_path '/etc/airplanes/feed.env'
    [ "$status" -eq 0 ]
    [ "$output" = '/etc/airplanes/feed.env' ]
}

@test "root_path: joins under ROOT='/foo'" {
    ROOT='/foo'
    run root_path '/etc/airplanes/feed.env'
    [ "$status" -eq 0 ]
    [ "$output" = '/foo/etc/airplanes/feed.env' ]
}

@test "root_path: trailing slash on ROOT is normalized" {
    ROOT='/foo/'
    run root_path '/etc/airplanes/feed.env'
    [ "$status" -eq 0 ]
    [ "$output" = '/foo/etc/airplanes/feed.env' ]
}

# --- feed_env_path / feed_env_paths ---

@test "feed_env_path: returns rootfs feed.env when present" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_path
    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "feed_env_path: returns boot config when image marker + boot config present" {
    : > "$ROOT_DIR/boot/airplanes-config.txt"
    install -m 755 /dev/null "$ROOT_DIR/usr/bin/airplanes-feeder"
    run feed_env_path
    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/boot/airplanes-config.txt" ]
}

@test "feed_env_path: falls back to rootfs feed.env when neither feed.env nor image present" {
    run feed_env_path
    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "feed_env_paths: single path when rootfs feed.env present" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_paths
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = '1' ]
    [ "$output" = "$ROOT_DIR/etc/airplanes/feed.env" ]
}

@test "feed_env_paths: two paths when image marker + boot config present" {
    : > "$ROOT_DIR/boot/airplanes-config.txt"
    install -m 755 /dev/null "$ROOT_DIR/usr/bin/airplanes-feeder"
    run feed_env_paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"$ROOT_DIR/boot/airplanes-config.txt"* ]]
    [[ "$output" == *"$ROOT_DIR/boot/airplanes-env"* ]]
}

# Documents drift with airplanes-feed.sh. airplanes-feed.sh treats
# /etc/airplanes/image-install as an image marker (commit 269994c);
# common.sh's feed_env_paths does not. With marker-only state (no
# legacy /usr/bin/airplanes-feeder, no rootfs feed.env), feed_env_paths
# falls through to the rootfs feed.env fallback.
@test "feed_env_paths: image-install marker alone does NOT trigger image branch (drift)" {
    : > "$ROOT_DIR/etc/airplanes/image-install"
    : > "$ROOT_DIR/boot/airplanes-config.txt"
    run feed_env_paths
    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT_DIR/etc/airplanes/feed.env" ]
}

# --- feed_env_get ---

@test "feed_env_get: parses double-quoted value" {
    printf 'INPUT="127.0.0.1:30005"\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_get INPUT
    [ "$status" -eq 0 ]
    [ "$output" = '127.0.0.1:30005' ]
}

@test "feed_env_get: parses single-quoted value" {
    printf "INPUT='127.0.0.1:30005'\n" > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_get INPUT
    [ "$status" -eq 0 ]
    [ "$output" = '127.0.0.1:30005' ]
}

@test "feed_env_get: parses unquoted value" {
    printf 'INPUT=127.0.0.1:30005\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_get INPUT
    [ "$status" -eq 0 ]
    [ "$output" = '127.0.0.1:30005' ]
}

@test "feed_env_get: drops a bare value with a same-line comment (contract violation)" {
    # The strict reader refuses `KEY=value # note` rather than guessing
    # where the value ends — same-line comments are outside the feed.env
    # value contract and parse differently across consumers.
    printf 'GAIN=42 # autogain\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_get GAIN
    [ "$status" -eq 1 ]
}

@test "feed_env_get: explicitly empty value reports rc 1 like absent" {
    printf 'UAT_INPUT=""\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_get UAT_INPUT
    [ "$status" -eq 1 ]
}

@test "feed_env_get: reads an indented key (source-visible lines stay visible)" {
    printf '  GAIN="42"\n' > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_get GAIN
    [ "$status" -eq 0 ]
    [ "$output" = '42' ]
}

@test "feed_env_get: missing key returns 1" {
    : > "$ROOT_DIR/etc/airplanes/feed.env"
    run feed_env_get NOPE
    [ "$status" -eq 1 ]
}

@test "feed_env_get: last value wins across multi-path output" {
    : > "$ROOT_DIR/boot/airplanes-config.txt"
    install -m 755 /dev/null "$ROOT_DIR/usr/bin/airplanes-feeder"
    printf 'GAIN=42\n' > "$ROOT_DIR/boot/airplanes-config.txt"
    printf 'GAIN=99\n' > "$ROOT_DIR/boot/airplanes-env"
    run feed_env_get GAIN
    [ "$status" -eq 0 ]
    [ "$output" = '99' ]
}

# --- canonicalize_secret / validate_secret / display_secret ---

@test "canonicalize_secret: strips whitespace and hyphens, uppercases" {
    run canonicalize_secret '  abcd-EFGH ijkl-mnop  '
    [ "$status" -eq 0 ]
    [ "$output" = 'ABCDEFGHIJKLMNOP' ]
}

@test "validate_secret: accepts canonical 16-char A-Z 0-9" {
    run validate_secret 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 0 ]
}

@test "validate_secret: rejects 15 chars" {
    run validate_secret 'ABCDEFGHIJKLMNO'
    [ "$status" -ne 0 ]
}

@test "validate_secret: rejects 17 chars" {
    run validate_secret 'ABCDEFGHIJKLMNOPQ'
    [ "$status" -ne 0 ]
}

@test "validate_secret: rejects lowercase" {
    run validate_secret 'abcdefghijklmnop'
    [ "$status" -ne 0 ]
}

@test "validate_secret: rejects punctuation inside" {
    run validate_secret 'ABCDEFGH-IJKLMNOP'
    [ "$status" -ne 0 ]
}

@test "display_secret: groups 4-4-4-4" {
    run display_secret 'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 0 ]
    [ "$output" = 'ABCD-EFGH-IJKL-MNOP' ]
}

# --- read_secret_file ---

@test "read_secret_file: missing file returns 1" {
    run read_secret_file "$ROOT_DIR/missing"
    [ "$status" -eq 1 ]
}

@test "read_secret_file: malformed bytes die" {
    printf 'not-a-valid-secret\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run_strict 'read_secret_file "$(secret_final_path)"'
    [ "$status" -ne 0 ]
    [[ "$output" == *'invalid secret'* ]]
}

@test "read_secret_file: valid file echoes canonical secret" {
    printf 'ABCD-EFGH-IJKL-MNOP\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run read_secret_file "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    [ "$status" -eq 0 ]
    [ "$output" = 'ABCDEFGHIJKLMNOP' ]
}

# --- read_version_file / write_version_file ---

@test "read_version_file: missing file returns 1" {
    run read_version_file
    [ "$status" -eq 1 ]
}

@test "read_version_file: non-numeric returns 1" {
    printf 'banana\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"
    run read_version_file
    [ "$status" -eq 1 ]
}

@test "write_version_file/read_version_file: integer round-trips" {
    write_version_file 7
    run read_version_file
    [ "$status" -eq 0 ]
    [ "$output" = '7' ]
}

@test "write_version_file: writes 0640" {
    write_version_file 7
    perms="$(stat -c '%a' "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version" 2>/dev/null || stat -f '%Lp' "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version")"
    [ "$perms" = '640' ]
}

@test "write_version_file: 'null' is a no-op" {
    run write_version_file 'null'
    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version" ]
}

@test "write_version_file: empty is a no-op" {
    run write_version_file ''
    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version" ]
}

@test "write_version_file: non-numeric is a no-op" {
    run write_version_file 'banana'
    [ "$status" -eq 0 ]
    [ ! -e "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version" ]
}

# --- canonicalize_uuid ---

@test "canonicalize_uuid: lowercases hex" {
    run canonicalize_uuid '11111111-2222-3333-4444-AAAAAAAAAAAA'
    [ "$status" -eq 0 ]
    [ "$output" = '11111111-2222-3333-4444-aaaaaaaaaaaa' ]
}

@test "canonicalize_uuid: strips braces" {
    run canonicalize_uuid '{11111111-2222-3333-4444-555555555555}'
    [ "$status" -eq 0 ]
    [ "$output" = '11111111-2222-3333-4444-555555555555' ]
}

@test "canonicalize_uuid: strips surrounding whitespace" {
    run canonicalize_uuid '  11111111-2222-3333-4444-555555555555  '
    [ "$status" -eq 0 ]
    [ "$output" = '11111111-2222-3333-4444-555555555555' ]
}

@test "canonicalize_uuid: strips embedded space and tab" {
    run canonicalize_uuid $'11111111-2222 -3333\t-4444-555555555555'
    [ "$status" -eq 0 ]
    [ "$output" = '11111111-2222-3333-4444-555555555555' ]
}

@test "canonicalize_uuid: rejects too short" {
    run canonicalize_uuid '11111111-2222-3333-4444'
    [ "$status" -eq 1 ]
}

@test "canonicalize_uuid: rejects non-hex" {
    run canonicalize_uuid 'GGGGGGGG-2222-3333-4444-555555555555'
    [ "$status" -eq 1 ]
}

# --- read_uuid ---

@test "read_uuid: prefers /etc/airplanes/feeder-id" {
    printf '11111111-2222-3333-4444-555555555555\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    printf '99999999-2222-3333-4444-555555555555\n' > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"
    run read_uuid
    [ "$status" -eq 0 ]
    [ "$output" = '11111111-2222-3333-4444-555555555555' ]
}

@test "read_uuid: falls back to legacy /usr/local path" {
    printf '22222222-2222-3333-4444-555555555555\n' > "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"
    run read_uuid
    [ "$status" -eq 0 ]
    [ "$output" = '22222222-2222-3333-4444-555555555555' ]
}

@test "read_uuid: falls back to /boot path" {
    printf '33333333-2222-3333-4444-555555555555\n' > "$ROOT_DIR/boot/airplanes-uuid"
    run read_uuid
    [ "$status" -eq 0 ]
    [ "$output" = '33333333-2222-3333-4444-555555555555' ]
}

@test "read_uuid: malformed file at first hit dies" {
    printf 'not-a-uuid\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    run_strict 'read_uuid'
    [ "$status" -ne 0 ]
    [[ "$output" == *'invalid Feeder ID format'* ]]
}

@test "read_uuid: no files dies" {
    run_strict 'read_uuid'
    [ "$status" -ne 0 ]
    [[ "$output" == *'no Feeder ID file'* ]]
}

# Documents drift between read_uuid and canonicalize_uuid:
# canonicalize_uuid strips spaces/tabs; read_uuid strips only \n\r{}.
# A leading-space file makes read_uuid die even though the embedded
# UUID is otherwise valid.
@test "read_uuid vs canonicalize_uuid: leading-space input handled differently (drift)" {
    printf ' 11111111-2222-3333-4444-555555555555\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    run_strict 'read_uuid'
    [ "$status" -ne 0 ]
    [[ "$output" == *'invalid Feeder ID format'* ]]
    run canonicalize_uuid ' 11111111-2222-3333-4444-555555555555'
    [ "$status" -eq 0 ]
    [ "$output" = '11111111-2222-3333-4444-555555555555' ]
}

# --- write_uuid ---

@test "write_uuid: writes 0644 file with newline" {
    write_uuid '11111111-2222-3333-4444-555555555555'
    perms="$(stat -c '%a' "$ROOT_DIR/etc/airplanes/feeder-id" 2>/dev/null || stat -f '%Lp' "$ROOT_DIR/etc/airplanes/feeder-id")"
    [ "$perms" = '644' ]
    contents="$(cat "$ROOT_DIR/etc/airplanes/feeder-id")"
    [ "$contents" = '11111111-2222-3333-4444-555555555555' ]
}

@test "write_uuid: rejects invalid input" {
    run_strict "write_uuid 'not-a-uuid'"
    [ "$status" -ne 0 ]
    [[ "$output" == *'refusing to write invalid Feeder ID'* ]]
}

# --- generate_secret ---

@test "generate_secret: output passes validate_secret" {
    secret="$(generate_secret)"
    run validate_secret "$secret"
    [ "$status" -eq 0 ]
}

@test "generate_secret: two consecutive calls produce different secrets" {
    a="$(generate_secret)"
    b="$(generate_secret)"
    [ -n "$a" ]
    [ -n "$b" ]
    [ "$a" != "$b" ]
}

# --- restart_feeder_services ---

setup_systemctl_stub() {
    local active_set="$1"   # space-separated services that are is-active
    local enabled_set="$2"  # space-separated services that are is-enabled
    local fail_set="$3"     # space-separated services where restart fails
    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
case "\$1" in
  is-active)
    target="\$3"
    case " $active_set " in *" \$target "*) exit 0;; *) exit 3;; esac
    ;;
  is-enabled)
    target="\$3"
    case " $enabled_set " in *" \$target "*) exit 0;; *) exit 1;; esac
    ;;
  restart)
    target="\$2"
    case " $fail_set " in *" \$target "*) exit 1;; esac
    printf 'STUB_RESTART %s\n' "\$target" >> "$ROOT_DIR/systemctl.log"
    exit 0
    ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

@test "restart_feeder_services: ROOT != / skips and prints message" {
    ROOT="$ROOT_DIR"
    run restart_feeder_services
    [ "$status" -eq 0 ]
    [[ "$output" == *'Skipping service restart'* ]]
}

@test "restart_feeder_services: ROOT=/, no systemctl on PATH returns 0" {
    ROOT='/'
    # Scope the PATH change to a subshell so bats's teardown still
    # finds rm/etc. on the host PATH.
    output="$(PATH="$ROOT_DIR/empty-bin" restart_feeder_services)"
    [ -z "$output" ]
}

@test "restart_feeder_services: both inactive AND disabled skips silently" {
    setup_systemctl_stub '' '' ''
    ROOT='/'
    run restart_feeder_services
    [ "$status" -eq 0 ]
    [ ! -s "$ROOT_DIR/systemctl.log" ] || [ "$(wc -l < "$ROOT_DIR/systemctl.log" | tr -d ' ')" = '0' ]
}

@test "restart_feeder_services: enabled-but-inactive triggers restart" {
    setup_systemctl_stub '' 'airplanes-feed airplanes-mlat' ''
    ROOT='/'
    run restart_feeder_services
    [ "$status" -eq 0 ]
    grep -q 'STUB_RESTART airplanes-feed' "$ROOT_DIR/systemctl.log"
    grep -q 'STUB_RESTART airplanes-mlat' "$ROOT_DIR/systemctl.log"
}

@test "restart_feeder_services: active-but-disabled triggers restart" {
    setup_systemctl_stub 'airplanes-feed airplanes-mlat' '' ''
    ROOT='/'
    run restart_feeder_services
    [ "$status" -eq 0 ]
    grep -q 'STUB_RESTART airplanes-feed' "$ROOT_DIR/systemctl.log"
    grep -q 'STUB_RESTART airplanes-mlat' "$ROOT_DIR/systemctl.log"
}

@test "restart_feeder_services: mlat restart failure returns 1 with hint" {
    setup_systemctl_stub 'airplanes-feed airplanes-mlat' 'airplanes-feed airplanes-mlat' 'airplanes-mlat'
    ROOT='/'
    run restart_feeder_services
    [ "$status" -eq 1 ]
    [[ "$output" == *'Restart hint'* ]]
    [[ "$output" == *'airplanes-mlat'* ]]
}

# --- parse_common_option ---

@test "parse_common_option: --root consumes 2 args and sets ROOT" {
    rc=0
    parse_common_option --root /mnt/foo || rc=$?
    [ "$rc" -eq 2 ]
    [ "$ROOT" = '/mnt/foo' ]
}

@test "parse_common_option: --root without value dies" {
    run_strict 'parse_common_option --root'
    [ "$status" -ne 0 ]
    [[ "$output" == *'--root requires PATH'* ]]
}

@test "parse_common_option: --website-url without value dies" {
    run_strict 'parse_common_option --website-url'
    [ "$status" -ne 0 ]
    [[ "$output" == *'--website-url requires URL'* ]]
}

@test "parse_common_option: --max-retry-time consumes 2 args" {
    rc=0
    parse_common_option --max-retry-time 90 || rc=$?
    [ "$rc" -eq 2 ]
    [ "$MAX_RETRY_TIME" = '90' ]
}

@test "parse_common_option: -h prints usage and exits 0" {
    run bash -c "
        source '$LIB_DIR/common.sh'
        parse_common_option -h
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *'Usage:'* ]]
}

@test "parse_common_option: unknown flag returns 0 without consuming" {
    parse_common_option --frobnitz
    rc=$?
    [ "$rc" -eq 0 ]
}

# --- parse_field_from / json_has_key ---

@test "parse_field_from: returns scalar value" {
    printf '{"version":7}\n' > "$ROOT_DIR/x.json"
    run parse_field_from "$ROOT_DIR/x.json" '.version'
    [ "$status" -eq 0 ]
    [ "$output" = '7' ]
}

@test "parse_field_from: null becomes empty" {
    printf '{"version":null}\n' > "$ROOT_DIR/x.json"
    run parse_field_from "$ROOT_DIR/x.json" '.version'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

@test "parse_field_from: malformed JSON yields empty (|| true)" {
    printf 'not-json\n' > "$ROOT_DIR/x.json"
    run parse_field_from "$ROOT_DIR/x.json" '.version'
    [ "$status" -eq 0 ]
}

@test "json_has_key: present returns true" {
    printf '{"a":1}\n' > "$ROOT_DIR/x.json"
    run json_has_key "$ROOT_DIR/x.json" 'a'
    [ "$status" -eq 0 ]
    [ "$output" = 'true' ]
}

@test "json_has_key: absent returns false" {
    printf '{"a":1}\n' > "$ROOT_DIR/x.json"
    run json_has_key "$ROOT_DIR/x.json" 'b'
    [ "$status" -eq 0 ]
    [ "$output" = 'false' ]
}

# --- seconds_until_iso ---

@test "seconds_until_iso: future ISO yields positive integer" {
    if ! date -u -d '2025-01-01T00:00:00Z' +%s >/dev/null 2>&1; then
        skip "GNU date -d not available"
    fi
    target="$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')"
    run seconds_until_iso "$target"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
}

@test "seconds_until_iso: past ISO yields 0" {
    if ! date -u -d '2025-01-01T00:00:00Z' +%s >/dev/null 2>&1; then
        skip "GNU date -d not available"
    fi
    target="$(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%SZ')"
    run seconds_until_iso "$target"
    [ "$status" -eq 0 ]
    [ "$output" = '0' ]
}

@test "seconds_until_iso: malformed yields 0" {
    run seconds_until_iso 'not-an-iso'
    [ "$status" -eq 0 ]
    [ "$output" = '0' ]
}

# --- human_duration_ago ---

@test "human_duration_ago: under 60s returns 'Ns ago'" {
    run human_duration_ago 30
    [ "$status" -eq 0 ]
    [ "$output" = '30s ago' ]
}

@test "human_duration_ago: under 1h returns 'Nm ago'" {
    run human_duration_ago 600
    [ "$status" -eq 0 ]
    [ "$output" = '10m ago' ]
}

@test "human_duration_ago: under 1d, no minutes returns 'Nh ago'" {
    run human_duration_ago 7200
    [ "$status" -eq 0 ]
    [ "$output" = '2h ago' ]
}

@test "human_duration_ago: under 1d, with minutes returns 'Nh Nm ago'" {
    run human_duration_ago 7800
    [ "$status" -eq 0 ]
    [ "$output" = '2h 10m ago' ]
}

@test "human_duration_ago: at 1d boundary returns 'Nd ago'" {
    run human_duration_ago 86400
    [ "$status" -eq 0 ]
    [ "$output" = '1d ago' ]
}

@test "human_duration_ago: > 1d with hours returns 'Nd Nh ago'" {
    run human_duration_ago 90000
    [ "$status" -eq 0 ]
    [ "$output" = '1d 1h ago' ]
}

@test "human_duration_ago: non-numeric input echoed verbatim" {
    run human_duration_ago 'banana'
    [ "$status" -eq 0 ]
    [ "$output" = 'banana' ]
}

# --- apl_auth_token ---

@test "apl_auth_token: builds alv1.<uuid>.<secret> from canonical inputs" {
    run apl_auth_token \
        '11111111-2222-3333-4444-555555555555' \
        'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 0 ]
    [ "$output" = 'alv1.11111111-2222-3333-4444-555555555555.ABCDEFGHIJKLMNOP' ]
}

@test "apl_auth_token: canonicalizes uppercase + braces in uuid" {
    run apl_auth_token \
        '{11111111-2222-3333-4444-AAAAAAAAAAAA}' \
        'ABCDEFGHIJKLMNOP'
    [ "$status" -eq 0 ]
    [ "$output" = 'alv1.11111111-2222-3333-4444-aaaaaaaaaaaa.ABCDEFGHIJKLMNOP' ]
}

@test "apl_auth_token: canonicalizes spaces + hyphens + lowercase in secret" {
    run apl_auth_token \
        '11111111-2222-3333-4444-555555555555' \
        '  abcd-efgh ijkl-mnop  '
    [ "$status" -eq 0 ]
    [ "$output" = 'alv1.11111111-2222-3333-4444-555555555555.ABCDEFGHIJKLMNOP' ]
}

@test "apl_auth_token: rejects malformed uuid" {
    run apl_auth_token 'not-a-uuid' 'ABCDEFGHIJKLMNOP'
    [ "$status" -ne 0 ]
}

@test "apl_auth_token: rejects too-short secret after canonicalization" {
    run apl_auth_token \
        '11111111-2222-3333-4444-555555555555' \
        'ABCDEFGH'
    [ "$status" -ne 0 ]
}

@test "apl_auth_token: rejects secret with non-alphanumeric chars" {
    run apl_auth_token \
        '11111111-2222-3333-4444-555555555555' \
        'ABCDEFGH!@#$%^&*'
    [ "$status" -ne 0 ]
}

# --- _resolve_website_url ---
#
# Precedence: APL_FEED_WEBSITE_URL env > feed.env grep > built-in default.
# CLI flag wins by writing WEBSITE_URL directly in parse_common_option, not
# through the resolver — covered in test_apl_feed_cli.bats.

@test "_resolve_website_url: env var overrides feed.env" {
    local feed_env="$TMPDIR/feed.env"
    printf 'APL_FEED_WEBSITE_URL="http://from.feedenv"\n' > "$feed_env"
    APL_FEED_WEBSITE_URL="http://from.env" run _resolve_website_url "$feed_env"
    [ "$status" -eq 0 ]
    [ "$output" = "http://from.env" ]
}

@test "_resolve_website_url: reads from feed.env when env unset" {
    local feed_env="$TMPDIR/feed.env"
    printf 'APL_FEED_WEBSITE_URL="http://from.feedenv"\n' > "$feed_env"
    unset APL_FEED_WEBSITE_URL
    run _resolve_website_url "$feed_env"
    [ "$status" -eq 0 ]
    [ "$output" = "http://from.feedenv" ]
}

@test "_resolve_website_url: handles unquoted feed.env value" {
    local feed_env="$TMPDIR/feed.env"
    printf 'APL_FEED_WEBSITE_URL=http://no.quotes\n' > "$feed_env"
    unset APL_FEED_WEBSITE_URL
    run _resolve_website_url "$feed_env"
    [ "$status" -eq 0 ]
    [ "$output" = "http://no.quotes" ]
}

@test "_resolve_website_url: ignores commented lines" {
    local feed_env="$TMPDIR/feed.env"
    printf '#APL_FEED_WEBSITE_URL="http://commented.out"\n' > "$feed_env"
    unset APL_FEED_WEBSITE_URL
    run _resolve_website_url "$feed_env"
    [ "$status" -eq 0 ]
    [ "$output" = "https://airplanes.live" ]
}

@test "_resolve_website_url: last write wins when feed.env has duplicates" {
    local feed_env="$TMPDIR/feed.env"
    printf 'APL_FEED_WEBSITE_URL="http://first"\nAPL_FEED_WEBSITE_URL="http://second"\n' > "$feed_env"
    unset APL_FEED_WEBSITE_URL
    run _resolve_website_url "$feed_env"
    [ "$status" -eq 0 ]
    [ "$output" = "http://second" ]
}

@test "_resolve_website_url: empty feed.env value falls back to default" {
    local feed_env="$TMPDIR/feed.env"
    printf 'APL_FEED_WEBSITE_URL=""\n' > "$feed_env"
    unset APL_FEED_WEBSITE_URL
    run _resolve_website_url "$feed_env"
    [ "$status" -eq 0 ]
    [ "$output" = "https://airplanes.live" ]
}

@test "_resolve_website_url: missing feed.env returns default" {
    unset APL_FEED_WEBSITE_URL
    run _resolve_website_url "$TMPDIR/does-not-exist"
    [ "$status" -eq 0 ]
    [ "$output" = "https://airplanes.live" ]
}

@test "_resolve_website_url: unset env and missing file returns default" {
    unset APL_FEED_WEBSITE_URL
    run _resolve_website_url "/nonexistent/path/feed.env"
    [ "$status" -eq 0 ]
    [ "$output" = "https://airplanes.live" ]
}

# --- _set_website_host ---
#
# WEBSITE_HOST is the bare host[:port] tag used by structured journal lines
# in airplanes-diagnostics and apl-feed-config-sync. The parser must strip
# scheme, userinfo, path, query, and fragment, while keeping any explicit
# port — non-default ports are operationally useful in the journal.

@test "_set_website_host: strips scheme only on plain host" {
    WEBSITE_URL="https://airplanes.live"
    _set_website_host
    [ "$WEBSITE_HOST" = "airplanes.live" ]
}

@test "_set_website_host: preserves host:port" {
    WEBSITE_URL="http://localhost:8080"
    _set_website_host
    [ "$WEBSITE_HOST" = "localhost:8080" ]
}

@test "_set_website_host: strips path" {
    WEBSITE_URL="https://airplanes.live/api/foo"
    _set_website_host
    [ "$WEBSITE_HOST" = "airplanes.live" ]
}

@test "_set_website_host: strips query string" {
    WEBSITE_URL="https://airplanes.live?x=1"
    _set_website_host
    [ "$WEBSITE_HOST" = "airplanes.live" ]
}

@test "_set_website_host: strips fragment" {
    WEBSITE_URL="https://airplanes.live#section"
    _set_website_host
    [ "$WEBSITE_HOST" = "airplanes.live" ]
}

@test "_set_website_host: strips userinfo (credential leak prevention)" {
    WEBSITE_URL="https://user:pass@airplanes.live"
    _set_website_host
    [ "$WEBSITE_HOST" = "airplanes.live" ]
}

@test "_set_website_host: userinfo + port + path + query combined" {
    WEBSITE_URL="https://u:p@host.example:9000/path?q=1"
    _set_website_host
    [ "$WEBSITE_HOST" = "host.example:9000" ]
}

@test "_set_website_host: re-derives via parse_common_option --website-url" {
    WEBSITE_URL="https://airplanes.live"
    _set_website_host
    [ "$WEBSITE_HOST" = "airplanes.live" ]
    # Drive the real parser so the production code path is covered.
    # Return code 2 is parse_common_option's "consumed 2 args" signal, not
    # an error — || true keeps `set -e` from aborting the bats run.
    parse_common_option --website-url "http://staging.example:8443/v2" || true
    [ "$WEBSITE_URL" = "http://staging.example:8443/v2" ]
    [ "$WEBSITE_HOST" = "staging.example:8443" ]
}

@test "_set_website_host: @ in path does not capture suffix as host" {
    WEBSITE_URL="https://airplanes.live/api/user@example"
    _set_website_host
    [ "$WEBSITE_HOST" = "airplanes.live" ]
}

@test "_set_website_host: log-injection attempt becomes invalid" {
    WEBSITE_URL="https://good.example level=error injected=1"
    _set_website_host
    [ "$WEBSITE_HOST" = "invalid" ]
}

@test "_set_website_host: embedded newline becomes invalid" {
    WEBSITE_URL=$'https://good.example\nfake-line'
    _set_website_host
    [ "$WEBSITE_HOST" = "invalid" ]
}

@test "_set_website_host: empty / default produces invalid (defensive)" {
    WEBSITE_URL=""
    _set_website_host
    [ "$WEBSITE_HOST" = "invalid" ]
}
