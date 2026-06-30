#!/usr/bin/env bats

# Per-module unit tests for scripts/apl-feed/backup.sh.
#
# Restore round-trips, --check, --uuid, rollback on secret-write
# failure, and --dry-run rejection are covered end-to-end in
# test_apl_feed_cli.bats — not duplicated here. This file isolates
# read_backup_file (validation matrix) and config_backup (write
# semantics + edge cases).

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    TMPDIR="$ROOT_DIR/tmp"
    mkdir -p "$TMPDIR" \
        "$ROOT_DIR/etc/airplanes" \
        "$ROOT_DIR/var/lib/airplanes/runtime" \
        "$ROOT_DIR/boot"
    export TMPDIR
    APL_FEED_SECRET_OWNER="$(id -un)"
    APL_FEED_SECRET_GROUP="$(id -gn)"
    export APL_FEED_SECRET_OWNER APL_FEED_SECRET_GROUP

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/backup.sh
    source "$LIB_DIR/backup.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    # Most config_backup cases need a valid local UUID + secret.
    UUID='11111111-2222-3333-4444-555555555555'
    SECRET='ABCDEFGHIJKLMNOP'
    printf '%s\n' "$UUID" > "$ROOT_DIR/etc/airplanes/feeder-id"
    printf '%s\n' "$SECRET" > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    chmod 0640 "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

write_backup() {
    # write_backup <path> <feeder_uuid|null> <secret|null> <version|null>
    local path="$1" uuid="$2" secret="$3" version="$4"
    jq -n \
        --arg uuid "$uuid" \
        --arg secret "$secret" \
        --arg version "$version" \
        '{schema_version:1, created_at:"2026-04-28T00:00:00Z", feeder_uuid:$uuid, claim:{secret:$secret, version:($version | if . == "null" then null elif . == "" then empty else tonumber end)}}' \
        > "$path"
}

# --- read_backup_file ---

@test "read_backup_file: schema_version != 1 dies" {
    jq -n '{schema_version:2, feeder_uuid:"11111111-2222-3333-4444-555555555555", claim:{secret:"ABCDEFGHIJKLMNOP"}}' > "$ROOT_DIR/bad.json"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        read_backup_file '$ROOT_DIR/bad.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'unsupported backup schema_version'* ]]
}

@test "read_backup_file: missing schema_version dies" {
    jq -n '{feeder_uuid:"11111111-2222-3333-4444-555555555555", claim:{secret:"ABCDEFGHIJKLMNOP"}}' > "$ROOT_DIR/bad.json"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        read_backup_file '$ROOT_DIR/bad.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'unsupported backup schema_version'* ]]
}

@test "read_backup_file: malformed JSON dies under strict mode" {
    printf 'not-json\n' > "$ROOT_DIR/bad.json"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        read_backup_file '$ROOT_DIR/bad.json'
    "
    [ "$status" -ne 0 ]
}

@test "read_backup_file: malformed feeder_uuid dies" {
    write_backup "$ROOT_DIR/bad.json" 'not-a-uuid' 'ABCDEFGHIJKLMNOP' 'null'
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        read_backup_file '$ROOT_DIR/bad.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'invalid feeder_uuid'* ]]
}

@test "read_backup_file: malformed claim.secret dies" {
    write_backup "$ROOT_DIR/bad.json" '11111111-2222-3333-4444-555555555555' 'too-short' 'null'
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        read_backup_file '$ROOT_DIR/bad.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'invalid claim.secret'* ]]
}

@test "read_backup_file: claim.version=null permitted, BACKUP_VERSION empty" {
    write_backup "$ROOT_DIR/ok.json" '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP' 'null'
    read_backup_file "$ROOT_DIR/ok.json"
    [ "$BACKUP_UUID" = '11111111-2222-3333-4444-555555555555' ]
    [ "$BACKUP_SECRET" = 'ABCDEFGHIJKLMNOP' ]
    [ -z "$BACKUP_VERSION" ]
}

@test "read_backup_file: missing claim.version key permitted, BACKUP_VERSION empty" {
    jq -n '{schema_version:1, created_at:"2026-04-28T00:00:00Z", feeder_uuid:"11111111-2222-3333-4444-555555555555", claim:{secret:"ABCDEFGHIJKLMNOP"}}' > "$ROOT_DIR/ok.json"
    read_backup_file "$ROOT_DIR/ok.json"
    [ "$BACKUP_UUID" = '11111111-2222-3333-4444-555555555555' ]
    [ "$BACKUP_SECRET" = 'ABCDEFGHIJKLMNOP' ]
    [ -z "$BACKUP_VERSION" ]
}

@test "read_backup_file: valid integer claim.version populates BACKUP_VERSION" {
    write_backup "$ROOT_DIR/ok.json" '11111111-2222-3333-4444-555555555555' 'ABCDEFGHIJKLMNOP' '7'
    read_backup_file "$ROOT_DIR/ok.json"
    [ "$BACKUP_VERSION" = '7' ]
}

# --- config_backup ---

@test "config_backup: refuses pre-existing output file" {
    : > "$ROOT_DIR/out.json"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup '$ROOT_DIR/out.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'already exists'* ]]
}

@test "config_backup: refuses --force flag" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup --force '$ROOT_DIR/out.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'unknown flag for backup: --force'* ]]
}

@test "config_backup: writes 0600 file" {
    config_backup "$ROOT_DIR/out.json" >/dev/null
    perms="$(stat -c '%a' "$ROOT_DIR/out.json" 2>/dev/null || stat -f '%Lp' "$ROOT_DIR/out.json")"
    [ "$perms" = '600' ]
}

@test "config_backup: version=null when no version file present" {
    config_backup "$ROOT_DIR/out.json" >/dev/null
    run jq -r '.claim.version' "$ROOT_DIR/out.json"
    [ "$status" -eq 0 ]
    [ "$output" = 'null' ]
}

@test "config_backup: integer version when version file present" {
    printf '7\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"
    config_backup "$ROOT_DIR/out.json" >/dev/null
    run jq -r '.claim.version' "$ROOT_DIR/out.json"
    [ "$output" = '7' ]
}

@test "config_backup: schema_version, feeder_uuid, secret round-trip via jq" {
    config_backup "$ROOT_DIR/out.json" >/dev/null
    [ "$(jq -r '.schema_version' "$ROOT_DIR/out.json")" = '1' ]
    [ "$(jq -r '.feeder_uuid' "$ROOT_DIR/out.json")" = "$UUID" ]
    [ "$(jq -r '.claim.secret' "$ROOT_DIR/out.json")" = "$SECRET" ]
}

@test "config_backup: created_at is ISO 8601 UTC" {
    config_backup "$ROOT_DIR/out.json" >/dev/null
    created="$(jq -r '.created_at' "$ROOT_DIR/out.json")"
    [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "config_backup: '-' writes JSON to stdout, no file created" {
    run config_backup -
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ ! -e "$ROOT_DIR/-" ]
    [ "$(printf '%s' "$output" | jq -r '.schema_version')" = '1' ]
    [ "$(printf '%s' "$output" | jq -r '.feeder_uuid')" = "$UUID" ]
    [ "$(printf '%s' "$output" | jq -r '.claim.secret')" = "$SECRET" ]
    [ "$(printf '%s' "$output" | jq -r '.claim.version')" = 'null' ]
}

@test "config_backup: '-' includes integer version when version file present" {
    printf '7\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret.version"
    run config_backup -
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.claim.version')" = '7' ]
}

@test "config_backup: '-' emits no confirmation line on stdout" {
    run config_backup -
    [ "$status" -eq 0 ]
    [[ "$output" != *"Backed up feeder config"* ]]
}

@test "config_backup: '-' is not blocked by a pre-existing file literally named '-'" {
    : > "$ROOT_DIR/-"
    cd "$ROOT_DIR"
    run config_backup -
    [ "$status" -eq 0 ]
    # The literal '-' file we created earlier stays empty — stdout-mode
    # never touches the filesystem.
    [ ! -s "$ROOT_DIR/-" ]
}

@test "config_backup: missing UUID file dies" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-id"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup '$ROOT_DIR/out.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'no Feeder ID file'* ]]
}

@test "config_backup: invalid UUID at primary path dies" {
    printf 'not-a-uuid\n' > "$ROOT_DIR/etc/airplanes/feeder-id"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup '$ROOT_DIR/out.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'invalid Feeder ID format'* ]]
}

@test "config_backup: missing existing secret file dies" {
    rm -f "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup '$ROOT_DIR/out.json'
    "
    [ "$status" -ne 0 ]
}

@test "config_backup: malformed existing secret dies" {
    printf 'too-short\n' > "$ROOT_DIR/etc/airplanes/feeder-claim-secret"
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup '$ROOT_DIR/out.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'invalid secret format'* ]]
}

@test "config_backup: requires a file argument" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'backup requires a file'* ]]
}

@test "config_backup: rejects more than one file argument" {
    run bash -c "
        set -euo pipefail
        source '$LIB_DIR/common.sh'
        source '$LIB_DIR/backup.sh'
        ROOT='$ROOT_DIR'
        config_backup '$ROOT_DIR/a.json' '$ROOT_DIR/b.json'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *'exactly one file'* ]]
}
