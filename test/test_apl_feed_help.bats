#!/usr/bin/env bats

# Contextual --help and usage-error behavior for the apl-feed CLI.
#
# Contract:
#   - `apl-feed` / `apl-feed -h`             -> concise index, stdout, exit 0
#   - `apl-feed <group>` (no subcommand)     -> group help, stderr, exit 2
#   - `apl-feed <group> --help`              -> group help, stdout, exit 0
#   - `apl-feed <group> <bogus>`             -> ERROR + group help, stderr, exit 2
#   - `apl-feed <…> --help` on any leaf      -> that leaf's help, stdout, exit 0
#   - unknown top-level command              -> ERROR + index, stderr, exit 2
# Usage errors exit 2 (distinct from die()'s exit 1).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/apl-feed.sh"
}

# --- top-level index ------------------------------------------------------

@test "apl-feed (no args): concise index on stdout, exit 0" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Commands:'* ]]
    [[ "$output" == *"Run 'apl-feed <command> --help'"* ]]
    [[ "$output" == *'claim'* ]]
    [[ "$output" == *'mlat'* ]]
}

@test "apl-feed -h / --help: concise index, exit 0" {
    run "$SCRIPT" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *'Commands:'* ]]
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'Commands:'* ]]
}

@test "apl-feed -h prints to stdout (not stderr)" {
    run bash -c "'$SCRIPT' -h 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Commands:'* ]]
}

@test "unknown top-level command: ERROR + index on stderr, exit 2" {
    run "$SCRIPT" frobnitz
    [ "$status" -eq 2 ]
    [[ "$output" == *'unknown command: frobnitz'* ]]
    [[ "$output" == *'Commands:'* ]]
}

@test "unknown top-level command writes nothing to stdout" {
    run bash -c "'$SCRIPT' frobnitz 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

# --- group: bare (exit 2) + --help (exit 0) -------------------------------

@test "claim: bare shows group help on stderr, exit 2" {
    run "$SCRIPT" claim
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed claim <subcommand>'* ]]
    [[ "$output" == *'register'* ]]
}

@test "claim: bare writes nothing to stdout" {
    run bash -c "'$SCRIPT' claim 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "claim --help: group help on stdout, exit 0" {
    run bash -c "'$SCRIPT' claim --help 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed claim <subcommand>'* ]]
}

@test "claim <bogus>: ERROR + group help, exit 2" {
    run "$SCRIPT" claim bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *'unknown claim subcommand: bogus'* ]]
    [[ "$output" == *'register'* ]]
}

@test "id: bare exit 2, --help exit 0" {
    run "$SCRIPT" id
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed id <subcommand>'* ]]
    run "$SCRIPT" id --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed id <subcommand>'* ]]
}

@test "mlat: bare exit 2, --help exit 0" {
    run "$SCRIPT" mlat
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed mlat <subcommand>'* ]]
    run "$SCRIPT" mlat --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed mlat <subcommand>'* ]]
    [[ "$output" == *'private'* ]]
}

@test "mlat private: bare exit 2, --help exit 0" {
    run "$SCRIPT" mlat private
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed mlat private <subcommand>'* ]]
    run "$SCRIPT" mlat private --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed mlat private <subcommand>'* ]]
}

@test "978: bare exit 2, --help exit 0" {
    run "$SCRIPT" 978
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed 978 <subcommand>'* ]]
    run "$SCRIPT" 978 --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed 978 <subcommand>'* ]]
}

@test "diagnostics: bare exit 2, --help exit 0" {
    run "$SCRIPT" diagnostics
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed diagnostics <subcommand>'* ]]
    run "$SCRIPT" diagnostics --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed diagnostics <subcommand>'* ]]
}

@test "config: bare exit 2, --help exit 0" {
    run "$SCRIPT" config
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed config <subcommand>'* ]]
    run "$SCRIPT" config --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed config <subcommand>'* ]]
}

@test "import: bare exit 2, --help exit 0" {
    run "$SCRIPT" import
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed import <subcommand>'* ]]
    run "$SCRIPT" import --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed import <subcommand>'* ]]
}

# --- per-leaf --help (stdout, exit 0) -------------------------------------

@test "claim register --help: leaf-specific help" {
    run "$SCRIPT" claim register --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed claim register'* ]]
}

@test "claim set --help: mentions stdin + --force" {
    run "$SCRIPT" claim set --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed claim set'* ]]
    [[ "$output" == *'--force'* ]]
}

@test "claim rotate --help: mentions --abort" {
    run "$SCRIPT" claim rotate --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed claim rotate'* ]]
    [[ "$output" == *'--abort'* ]]
}

@test "id set --help: leaf help" {
    run "$SCRIPT" id set --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed id set'* ]]
}

@test "mlat geo --help: geo-specific help" {
    run "$SCRIPT" mlat geo --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed mlat geo <lat> <lon> <alt>'* ]]
}

@test "mlat user --help: user-specific help" {
    run "$SCRIPT" mlat user --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed mlat user'* ]]
    [[ "$output" == *'--clear'* ]]
}

@test "mlat private enable --help: leaf help" {
    run "$SCRIPT" mlat private enable --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed mlat private enable'* ]]
}

@test "978 enable --help: mentions --serial/--gain" {
    run "$SCRIPT" 978 enable --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed 978 enable'* ]]
    [[ "$output" == *'--serial'* ]]
}

@test "config sync --help: sync-specific help" {
    run "$SCRIPT" config sync --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed config sync'* ]]
    [[ "$output" == *'--dry-run'* ]]
}

@test "import legacy-config --help: leaf help" {
    run "$SCRIPT" import legacy-config --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed import legacy-config'* ]]
}

@test "status --help: status help" {
    run "$SCRIPT" status --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed status'* ]]
    [[ "$output" == *'--json'* ]]
}

@test "backup -h: backup help" {
    run "$SCRIPT" backup -h
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed backup'* ]]
}

@test "restore -h: restore help mentions --uuid" {
    run "$SCRIPT" restore -h
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed restore'* ]]
    [[ "$output" == *'--uuid'* ]]
}

# --- backup/restore missing operand -> usage error (exit 2) ---------------

@test "backup with no file: usage error, exit 2" {
    run "$SCRIPT" backup
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed backup'* ]]
}

@test "restore with no source: usage error, exit 2" {
    run "$SCRIPT" restore
    [ "$status" -eq 2 ]
    [[ "$output" == *'apl-feed restore'* ]]
}

# --- help must not require jq --------------------------------------------

@test "apply --help works with jq absent from PATH" {
    local stub
    stub="$(mktemp -d)"
    ln -s /usr/bin/* "$stub"/ 2>/dev/null || true
    ln -s /bin/* "$stub"/ 2>/dev/null || true
    rm -f "$stub/jq"
    run env PATH="$stub" "$SCRIPT" apply --help
    rm -rf "$stub"
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed apply'* ]]
}

@test "schema --help works with jq absent from PATH" {
    local stub
    stub="$(mktemp -d)"
    ln -s /usr/bin/* "$stub"/ 2>/dev/null || true
    ln -s /bin/* "$stub"/ 2>/dev/null || true
    rm -f "$stub/jq"
    run env PATH="$stub" "$SCRIPT" schema --help
    rm -rf "$stub"
    [ "$status" -eq 0 ]
    [[ "$output" == *'apl-feed schema'* ]]
}
