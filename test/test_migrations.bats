#!/usr/bin/env bats

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/scripts/lib/update-migrations.sh"
    COMMON_LIB="$REPO_ROOT/scripts/lib/install-update-common.sh"
    TMP="$(mktemp -d)"
    FEED_ENV="$TMP/feed.env"

    AIRPLANES_ROOT="$TMP/root"
    mkdir -p "$AIRPLANES_ROOT"
    AIRPLANES_BUILD_MODE=
    export AIRPLANES_ROOT AIRPLANES_BUILD_MODE

    # shellcheck source=/dev/null
    source "$COMMON_LIB"
    # shellcheck source=/dev/null
    source "$LIB"
}

teardown() {
    rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# migrate_user_to_mlat_split
# ---------------------------------------------------------------------------

@test "migrate_user_to_mlat_split: USER=<name> → MLAT_USER=<name>, MLAT_ENABLED=true" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
USER="william34-london"
LATITUDE="52.5"
EOF
    migrate_user_to_mlat_split "$FEED_ENV"

    grep -q '^MLAT_USER="william34-london"$' "$FEED_ENV"
    grep -q '^MLAT_ENABLED=true$' "$FEED_ENV"
    ! grep -q '^USER=' "$FEED_ENV"
    grep -q '^INPUT="127.0.0.1:30005"$' "$FEED_ENV"
    grep -q '^LATITUDE="52.5"$' "$FEED_ENV"
}

@test "migrate_user_to_mlat_split: USER=0 → MLAT_USER=, MLAT_ENABLED=false" {
    printf 'USER="0"\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    grep -q '^MLAT_USER=""$' "$FEED_ENV"
    grep -q '^MLAT_ENABLED=false$' "$FEED_ENV"
    ! grep -q '^USER=' "$FEED_ENV"
}

@test "migrate_user_to_mlat_split: USER=disable → MLAT_USER=, MLAT_ENABLED=false" {
    printf 'USER="disable"\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    grep -q '^MLAT_USER=""$' "$FEED_ENV"
    grep -q '^MLAT_ENABLED=false$' "$FEED_ENV"
}

@test "migrate_user_to_mlat_split: USER=changeme → MLAT_USER=changeme, MLAT_ENABLED=true (changeme isn't a sentinel)" {
    printf 'USER="changeme"\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    grep -q '^MLAT_USER="changeme"$' "$FEED_ENV"
    grep -q '^MLAT_ENABLED=true$' "$FEED_ENV"
}

@test "migrate_user_to_mlat_split: unquoted USER=name parses correctly" {
    printf 'USER=alice\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    grep -q '^MLAT_USER="alice"$' "$FEED_ENV"
    grep -q '^MLAT_ENABLED=true$' "$FEED_ENV"
}

@test "migrate_user_to_mlat_split: idempotent — second call is a no-op" {
    printf 'USER="alice"\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"
    local snapshot
    snapshot="$(cat "$FEED_ENV")"

    migrate_user_to_mlat_split "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$snapshot" ]
}

@test "migrate_user_to_mlat_split: no USER → no-op (MLAT_USER not invented)" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
LATITUDE="52.5"
EOF
    migrate_user_to_mlat_split "$FEED_ENV"

    ! grep -q '^MLAT_USER=' "$FEED_ENV"
    ! grep -q '^MLAT_ENABLED=' "$FEED_ENV"
}

@test "migrate_user_to_mlat_split: legacy USER reappearing with existing MLAT_* re-derives" {
    # Simulates legacy webconfig writing USER= via the symlink while
    # MLAT_USER/MLAT_ENABLED are already in place from a prior migration.
    cat > "$FEED_ENV" <<'EOF'
MLAT_USER="alice"
MLAT_ENABLED=true
USER="0"
EOF
    migrate_user_to_mlat_split "$FEED_ENV"

    grep -q '^MLAT_USER=""$' "$FEED_ENV"
    grep -q '^MLAT_ENABLED=false$' "$FEED_ENV"
    ! grep -q '^USER=' "$FEED_ENV"
}

@test "migrate_user_to_mlat_split: writes backup at .pre-mlat-split on first migration" {
    printf 'USER="alice"\n' > "$FEED_ENV"
    [ ! -f "$FEED_ENV.pre-mlat-split" ]

    migrate_user_to_mlat_split "$FEED_ENV"
    [ -f "$FEED_ENV.pre-mlat-split" ]
    grep -q '^USER="alice"$' "$FEED_ENV.pre-mlat-split"
}

@test "migrate_user_to_mlat_split: backup is NEVER overwritten on subsequent calls" {
    printf 'USER="alice"\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    local backup_snapshot
    backup_snapshot="$(cat "$FEED_ENV.pre-mlat-split")"

    # Re-introduce USER and re-migrate.
    printf 'USER="bob"\n' >> "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"
    [ "$(cat "$FEED_ENV.pre-mlat-split")" = "$backup_snapshot" ]
}

@test "migrate_user_to_mlat_split: feed.env missing → no-op (no error)" {
    [ ! -f "$FEED_ENV" ]
    migrate_user_to_mlat_split "$FEED_ENV"
    [ ! -f "$FEED_ENV" ]
}

@test "migrate_user_to_mlat_split: preserves all non-MLAT keys verbatim" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
USER="alice"
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="35m"
NET_OPTIONS="--net-heartbeat 60"
TARGET="--net-connector feed2.airplanes.live,64004"
UAT_INPUT="127.0.0.1:30978"
SOME_USER_CUSTOM_KEY="leave-me-alone"
EOF
    migrate_user_to_mlat_split "$FEED_ENV"

    for line in \
        'INPUT="127.0.0.1:30005"' \
        'LATITUDE="52.5"' \
        'LONGITUDE="13.4"' \
        'ALTITUDE="35m"' \
        'NET_OPTIONS="--net-heartbeat 60"' \
        'TARGET="--net-connector feed2.airplanes.live,64004"' \
        'UAT_INPUT="127.0.0.1:30978"' \
        'SOME_USER_CUSTOM_KEY="leave-me-alone"' \
    ; do
        grep -qF "$line" "$FEED_ENV"
    done
}

# ---------------------------------------------------------------------------
# prepare_legacy_feed_env_migration: symlink handling
# ---------------------------------------------------------------------------

@test "prepare_legacy_feed_env_migration: regular legacy file → copied to feed.env" {
    LEGACY="$TMP/etc/default/airplanes"
    ETC_AIRPLANES_DIR="$TMP/etc/airplanes"
    mkdir -p "$(dirname "$LEGACY")"
    printf 'USER="alice"\n' > "$LEGACY"

    prepare_legacy_feed_env_migration "$LEGACY" "$FEED_ENV" "$ETC_AIRPLANES_DIR"

    [ -f "$FEED_ENV" ]
    grep -q '^USER="alice"$' "$FEED_ENV"
}

@test "prepare_legacy_feed_env_migration: legacy symlink → feed.env → no-op" {
    LEGACY="$TMP/etc/default/airplanes"
    ETC_AIRPLANES_DIR="$TMP/etc/airplanes"
    mkdir -p "$(dirname "$LEGACY")" "$ETC_AIRPLANES_DIR"
    printf 'MLAT_USER="alice"\n' > "$FEED_ENV"
    ln -sfn "$FEED_ENV" "$LEGACY"

    local snapshot
    snapshot="$(cat "$FEED_ENV")"

    prepare_legacy_feed_env_migration "$LEGACY" "$FEED_ENV" "$ETC_AIRPLANES_DIR"
    [ "$(cat "$FEED_ENV")" = "$snapshot" ]
}

@test "prepare_legacy_feed_env_migration: legacy symlink → /boot/airplanes-env → followed and copied" {
    LEGACY="$TMP/etc/default/airplanes"
    BOOT_ENV="$TMP/boot/airplanes-env"
    ETC_AIRPLANES_DIR="$TMP/etc/airplanes"
    mkdir -p "$(dirname "$LEGACY")" "$(dirname "$BOOT_ENV")"
    printf 'USER="alice"\n' > "$BOOT_ENV"
    ln -sfn "$BOOT_ENV" "$LEGACY"

    [ ! -f "$FEED_ENV" ]
    prepare_legacy_feed_env_migration "$LEGACY" "$FEED_ENV" "$ETC_AIRPLANES_DIR"

    [ -f "$FEED_ENV" ]
    grep -q '^USER="alice"$' "$FEED_ENV"
}

@test "prepare_legacy_feed_env_migration: existing feed.env wins over legacy symlink target" {
    LEGACY="$TMP/etc/default/airplanes"
    BOOT_ENV="$TMP/boot/airplanes-env"
    ETC_AIRPLANES_DIR="$TMP/etc/airplanes"
    mkdir -p "$(dirname "$LEGACY")" "$(dirname "$BOOT_ENV")" "$ETC_AIRPLANES_DIR"
    printf 'USER="from-boot"\n' > "$BOOT_ENV"
    printf 'MLAT_USER="from-feed-env"\n' > "$FEED_ENV"
    ln -sfn "$BOOT_ENV" "$LEGACY"

    prepare_legacy_feed_env_migration "$LEGACY" "$FEED_ENV" "$ETC_AIRPLANES_DIR"

    grep -q '^MLAT_USER="from-feed-env"$' "$FEED_ENV"
    ! grep -q '^USER="from-boot"$' "$FEED_ENV"
}

# ---------------------------------------------------------------------------
# _extract_env_value
# ---------------------------------------------------------------------------

@test "_extract_env_value: double-quoted value" {
    printf 'KEY="hello"\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "hello" ]
}

@test "_extract_env_value: single-quoted value" {
    printf "KEY='hello'\n" > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "hello" ]
}

@test "_extract_env_value: unquoted value" {
    printf 'KEY=hello\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "hello" ]
}

@test "_extract_env_value: last-wins on duplicate keys" {
    printf 'KEY="first"\nKEY="last"\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "last" ]
}

@test "_extract_env_value: missing key → empty" {
    printf 'OTHER="value"\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "" ]
}

@test "_extract_env_value: anchors on start of line (KEY!=OTHER_KEY)" {
    printf 'OTHER_KEY="other"\nKEY="real"\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "real" ]
}

@test "_extract_env_value: strips CRLF line ending" {
    printf 'KEY="0"\r\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "0" ]
}

@test "_extract_env_value: unquoted value with trailing comment" {
    printf 'KEY=0 # disabled\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "0" ]
}

@test "_extract_env_value: unquoted value with trailing whitespace" {
    printf 'KEY=disable   \n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "disable" ]
}

@test "_extract_env_value: quoted value preserves # inside quotes" {
    printf 'KEY="hash#in-name" # comment\n' > "$FEED_ENV"
    [ "$(_extract_env_value "$FEED_ENV" KEY)" = "hash#in-name" ]
}

# ---------------------------------------------------------------------------
# migrate_user_to_mlat_split: shell-escape correctness
# ---------------------------------------------------------------------------

@test "migrate_user_to_mlat_split: USER with \$ does not expand on re-source" {
    printf 'USER="price$5"\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    # Re-source in a clean subshell and check the literal value survives.
    local resourced_value
    resourced_value="$(env -i bash -c "source \"$FEED_ENV\"; printf '%s' \"\${MLAT_USER}\"")"
    [ "$resourced_value" = "price\$5" ]
}

@test "migrate_user_to_mlat_split: USER with backticks does not execute on re-source" {
    printf 'USER="`whoami`"\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    local resourced_value
    resourced_value="$(env -i bash -c "source \"$FEED_ENV\"; printf '%s' \"\${MLAT_USER}\"")"
    [ "$resourced_value" = "\`whoami\`" ]
}

# NOTE: _extract_env_value treats values as opaque strings — it does not unwind
# bash's source-time backslash-escape semantics for double-quoted strings. So
# values with embedded \" or \\ aren't preserved through round-trip. Real
# feeder names are sanitized in configure.sh to letters/digits/underscores/
# dashes/spaces (no backslashes, no quotes), so this corner only matters for
# hand-edited feed.env files. Documented here, not enforced.
