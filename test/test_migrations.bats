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
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/legacy-mlat-translation.sh"
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

@test "migrate_user_to_mlat_split: empty USER → MLAT_USER=Anonymous, MLAT_ENABLED=true" {
    # Mirrors airplanes-webconfig's migrate-config.sh and configure.sh's
    # DEFAULT_MLAT_NAME — empty user becomes Anonymous so the daemon's
    # strict-fail on empty MLAT_USER never fires.
    printf 'USER=""\n' > "$FEED_ENV"
    migrate_user_to_mlat_split "$FEED_ENV"

    grep -q '^MLAT_USER="Anonymous"$' "$FEED_ENV"
    grep -q '^MLAT_ENABLED=true$' "$FEED_ENV"
    ! grep -q '^USER=' "$FEED_ENV"
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

# ---------------------------------------------------------------------------
# migrate_privacy_to_mlat_private
# ---------------------------------------------------------------------------

@test "migrate_privacy_to_mlat_private: PRIVACY=--privacy → MLAT_PRIVATE=true" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
PRIVACY="--privacy"
LATITUDE="52.5"
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=true' "$FEED_ENV"
    ! grep -q '^PRIVACY=' "$FEED_ENV"
    grep -q '^INPUT="127.0.0.1:30005"$' "$FEED_ENV"
    grep -q '^LATITUDE="52.5"$' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: PRIVACY=\"\" → MLAT_PRIVATE=false" {
    cat > "$FEED_ENV" <<'EOF'
PRIVACY=""
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
    ! grep -q '^PRIVACY=' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: unquoted PRIVACY=--privacy → MLAT_PRIVATE=true" {
    printf 'PRIVACY=--privacy\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=true' "$FEED_ENV"
    ! grep -q '^PRIVACY=' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: PRIVACY with surrounding whitespace tolerated" {
    printf 'PRIVACY=" --privacy "\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=true' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: CRLF line ending tolerated" {
    printf 'PRIVACY="--privacy"\r\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=true' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: PRIVACY with garbage value → MLAT_PRIVATE=false" {
    printf 'PRIVACY="--something-else"\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: both keys absent → MLAT_PRIVATE=false appended" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
LATITUDE="52.5"
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
    grep -q '^INPUT="127.0.0.1:30005"$' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: only MLAT_PRIVATE present → no-op" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
MLAT_PRIVATE=true
LATITUDE="52.5"
EOF
    local snapshot
    snapshot="$(cat "$FEED_ENV")"

    migrate_privacy_to_mlat_private "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$snapshot" ]
}

@test "migrate_privacy_to_mlat_private: both keys present → canonical wins, PRIVACY stripped" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
MLAT_PRIVATE=false
PRIVACY="--privacy"
LATITUDE="52.5"
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
    ! grep -q '^PRIVACY=' "$FEED_ENV"
    [ "$(grep -c '^MLAT_PRIVATE=' "$FEED_ENV")" -eq 1 ]
}

@test "migrate_privacy_to_mlat_private: idempotent — second call is a no-op" {
    printf 'PRIVACY="--privacy"\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"
    local snapshot
    snapshot="$(cat "$FEED_ENV")"

    migrate_privacy_to_mlat_private "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$snapshot" ]
}

@test "migrate_privacy_to_mlat_private: writes backup at .pre-privacy-split when modifying" {
    printf 'PRIVACY="--privacy"\n' > "$FEED_ENV"
    [ ! -f "$FEED_ENV.pre-privacy-split" ]

    migrate_privacy_to_mlat_private "$FEED_ENV"
    [ -f "$FEED_ENV.pre-privacy-split" ]
    grep -q '^PRIVACY="--privacy"$' "$FEED_ENV.pre-privacy-split"
}

@test "migrate_privacy_to_mlat_private: backup is NEVER overwritten on subsequent calls" {
    printf 'PRIVACY="--privacy"\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"

    local backup_snapshot
    backup_snapshot="$(cat "$FEED_ENV.pre-privacy-split")"

    # Re-introduce PRIVACY and re-migrate.
    printf 'PRIVACY=""\n' >> "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"
    [ "$(cat "$FEED_ENV.pre-privacy-split")" = "$backup_snapshot" ]
}

@test "migrate_privacy_to_mlat_private: feed.env missing → no-op (no error)" {
    [ ! -f "$FEED_ENV" ]
    migrate_privacy_to_mlat_private "$FEED_ENV"
    [ ! -f "$FEED_ENV" ]
}

@test "migrate_privacy_to_mlat_private: preserves all non-privacy keys verbatim" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
MLAT_USER="alice"
MLAT_ENABLED=true
PRIVACY="--privacy"
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="35m"
NET_OPTIONS="--net-heartbeat 60"
SOME_USER_CUSTOM_KEY="leave-me-alone"
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    for line in \
        'INPUT="127.0.0.1:30005"' \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'LATITUDE="52.5"' \
        'LONGITUDE="13.4"' \
        'ALTITUDE="35m"' \
        'NET_OPTIONS="--net-heartbeat 60"' \
        'SOME_USER_CUSTOM_KEY="leave-me-alone"' \
    ; do
        grep -qF "$line" "$FEED_ENV"
    done
}

@test "migrate_privacy_to_mlat_private: legacy PRIVACY reappearing post-migration is stripped" {
    # Simulates a legacy webconfig writing PRIVACY= via the symlink while
    # MLAT_PRIVATE is already in place. Conflict rule: canonical wins, legacy
    # stripped. (Diverges from migrate_user_to_mlat_split's re-derivation
    # because no observed legacy PRIVACY writer needs precedence.)
    cat > "$FEED_ENV" <<'EOF'
MLAT_PRIVATE=false
PRIVACY="--privacy"
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
    ! grep -q '^PRIVACY=' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: MLAT_MARKER=no → MLAT_PRIVATE=true, stripped" {
    # PHP webconfig writes MLAT_MARKER via its yes/no dropdown with
    # inverted polarity: "no" means privacy ON.
    printf 'MLAT_MARKER="no"\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=true' "$FEED_ENV"
    ! grep -q '^MLAT_MARKER=' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: MLAT_MARKER=yes → MLAT_PRIVATE=false, stripped" {
    printf 'MLAT_MARKER="yes"\n' > "$FEED_ENV"
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
    ! grep -q '^MLAT_MARKER=' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: PRIVACY wins over MLAT_MARKER when both present" {
    # PRIVACY is the more deliberate hand-edit signal (CLI fragment);
    # MLAT_MARKER is the still-shipping PHP webconfig form. If a config
    # carries both, prefer PRIVACY.
    cat > "$FEED_ENV" <<'EOF'
PRIVACY="--privacy"
MLAT_MARKER="yes"
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=true' "$FEED_ENV"
    ! grep -q '^PRIVACY=' "$FEED_ENV"
    ! grep -q '^MLAT_MARKER=' "$FEED_ENV"
}

@test "migrate_privacy_to_mlat_private: canonical MLAT_PRIVATE wins over MLAT_MARKER" {
    cat > "$FEED_ENV" <<'EOF'
MLAT_PRIVATE=false
MLAT_MARKER="no"
EOF
    migrate_privacy_to_mlat_private "$FEED_ENV"

    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
    ! grep -q '^MLAT_MARKER=' "$FEED_ENV"
}

@test "run_config_file_migrations: chains migrate_privacy_to_mlat_private after migrate_user_to_mlat_split" {
    cat > "$FEED_ENV" <<'EOF'
USER="alice"
PRIVACY="--privacy"
LATITUDE="52.5"
EOF
    run_config_file_migrations "$FEED_ENV"

    grep -qx 'MLAT_USER="alice"' "$FEED_ENV"
    grep -qx 'MLAT_ENABLED=true' "$FEED_ENV"
    grep -qx 'MLAT_PRIVATE=true' "$FEED_ENV"
    ! grep -q '^USER=' "$FEED_ENV"
    ! grep -q '^PRIVACY=' "$FEED_ENV"
}

# ---------------------------------------------------------------------------
# migrate_geo_to_configured_flag
# ---------------------------------------------------------------------------

@test "migrate_geo_to_configured_flag: both coords non-zero → GEO_CONFIGURED=true" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
    grep -qx 'LATITUDE="52.5"' "$FEED_ENV"
    grep -qx 'LONGITUDE="13.4"' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: legacy LATITUDE=0/LONGITUDE=0 → GEO_CONFIGURED=false" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="0"
LONGITUDE="0"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=false' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: equator user (LATITUDE=0, LONGITUDE non-zero) → GEO_CONFIGURED=true" {
    # The previous LATITUDE==0 sentinel falsely disabled equator users.
    # The migration heuristic recognizes single-axis zero as a legitimate
    # coordinate and heals their config.
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="0"
LONGITUDE="13.4"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: prime-meridian user (LATITUDE non-zero, LONGITUDE=0) → GEO_CONFIGURED=true" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="51.5"
LONGITUDE="0"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: LATITUDE empty (LONGITUDE non-zero) → GEO_CONFIGURED=true" {
    # Empty axis is treated as numerically zero; the other axis is real, so
    # this is still a legitimate single-axis-zero coordinate.
    cat > "$FEED_ENV" <<'EOF'
LATITUDE=""
LONGITUDE="13.4"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: both axes empty → GEO_CONFIGURED=false" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE=""
LONGITUDE=""
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=false' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: decimal-zero pair (0.00000/0.00000) → GEO_CONFIGURED=false" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="0.00000"
LONGITUDE="0.00000"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=false' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: signed-zero pair (+0/-0) → GEO_CONFIGURED=false" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="+0"
LONGITUDE="-0"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    grep -qx 'GEO_CONFIGURED=false' "$FEED_ENV"
}

@test "migrate_geo_to_configured_flag: GEO_CONFIGURED already present → no-op" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="0"
LONGITUDE="0"
GEO_CONFIGURED=true
EOF
    local snapshot
    snapshot="$(cat "$FEED_ENV")"

    migrate_geo_to_configured_flag "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$snapshot" ]
}

@test "migrate_geo_to_configured_flag: idempotent — second call is a no-op" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"
    local snapshot
    snapshot="$(cat "$FEED_ENV")"

    migrate_geo_to_configured_flag "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$snapshot" ]
}

@test "migrate_geo_to_configured_flag: feed.env missing → no-op (no error)" {
    [ ! -f "$FEED_ENV" ]
    migrate_geo_to_configured_flag "$FEED_ENV"
    [ ! -f "$FEED_ENV" ]
}

@test "migrate_geo_to_configured_flag: preserves all other keys verbatim" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="35m"
NET_OPTIONS="--net-heartbeat 60"
EOF
    migrate_geo_to_configured_flag "$FEED_ENV"

    for line in \
        'INPUT="127.0.0.1:30005"' \
        'MLAT_USER="alice"' \
        'MLAT_ENABLED=true' \
        'MLAT_PRIVATE=false' \
        'LATITUDE="52.5"' \
        'LONGITUDE="13.4"' \
        'ALTITUDE="35m"' \
        'NET_OPTIONS="--net-heartbeat 60"' \
    ; do
        grep -qF "$line" "$FEED_ENV"
    done
}

@test "run_config_file_migrations: chains migrate_geo_to_configured_flag last in the pipeline" {
    cat > "$FEED_ENV" <<'EOF'
USER="alice"
LATITUDE="52.5"
LONGITUDE="13.4"
EOF
    run_config_file_migrations "$FEED_ENV"

    grep -qx 'MLAT_USER="alice"' "$FEED_ENV"
    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
}

# ---------------------------------------------------------------------------
# migrate_seed_feed_meta_json (DEV-380)
# ---------------------------------------------------------------------------

@test "migrate_seed_feed_meta_json: seeds the 6 tracked fields from a typical feed.env" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="35m"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
GAIN=auto
EOF
    META="$TMP/feed.meta.json"
    migrate_seed_feed_meta_json "$FEED_ENV" "$META"

    [ -f "$META" ]
    [ "$(jq -r '.schema_version' "$META")" = "1" ]
    for k in LATITUDE LONGITUDE ALTITUDE MLAT_USER MLAT_ENABLED MLAT_PRIVATE; do
        [ "$(jq -r ".fields.${k}.edited_at" "$META")" = "2020-01-01T00:00:00Z" ]
        [ "$(jq -r ".fields.${k}.edited_by" "$META")" = "legacy" ]
    done
    # GAIN is NOT tracked.
    [ "$(jq -r '.fields | has("GAIN")' "$META")" = "false" ]
}

@test "migrate_seed_feed_meta_json: idempotent when sidecar already exists" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
MLAT_USER="alice"
EOF
    META="$TMP/feed.meta.json"
    cat > "$META" <<EOF
{"schema_version":1,"fields":{"MLAT_USER":{"edited_at":"2026-05-12T10:00:00Z","edited_by":"website"}}}
EOF
    cp "$META" "$META.before"
    migrate_seed_feed_meta_json "$FEED_ENV" "$META"
    diff -u "$META.before" "$META"
}

@test "migrate_seed_feed_meta_json: skips when feed.env missing (no sidecar created)" {
    META="$TMP/feed.meta.json"
    migrate_seed_feed_meta_json "$FEED_ENV" "$META"
    [ ! -f "$META" ]
}

@test "migrate_seed_feed_meta_json: skips when jq missing" {
    cat > "$FEED_ENV" <<'EOF'
MLAT_USER="alice"
EOF
    META="$TMP/feed.meta.json"
    # Override `command` so the `command -v jq` lookup inside the migration
    # returns non-zero, mirroring a system that doesn't have jq installed.
    # Everything else falls through to the bash builtin.
    command() {
        if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    migrate_seed_feed_meta_json "$FEED_ENV" "$META"
    unset -f command
    [ ! -f "$META" ]
}

@test "migrate_seed_feed_meta_json: handles partial feed.env (only LATITUDE/LONGITUDE present)" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
EOF
    META="$TMP/feed.meta.json"
    migrate_seed_feed_meta_json "$FEED_ENV" "$META"

    [ -f "$META" ]
    [ "$(jq -r '.fields | has("LATITUDE")' "$META")" = "true" ]
    [ "$(jq -r '.fields | has("LONGITUDE")' "$META")" = "true" ]
    # Other tracked fields not present in feed.env → not in meta either.
    [ "$(jq -r '.fields | has("ALTITUDE")' "$META")" = "false" ]
    [ "$(jq -r '.fields | has("MLAT_USER")' "$META")" = "false" ]
}

@test "migrate_seed_feed_meta_json: seeds present-but-empty MLAT_USER (key-presence rule)" {
    cat > "$FEED_ENV" <<'EOF'
MLAT_USER=""
MLAT_ENABLED=false
EOF
    META="$TMP/feed.meta.json"
    migrate_seed_feed_meta_json "$FEED_ENV" "$META"

    [ "$(jq -r '.fields | has("MLAT_USER")' "$META")" = "true" ]
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$META")" = "legacy" ]
}

@test "migrate_seed_feed_meta_json: failure returns 0 (no update.sh abort under set -e)" {
    cat > "$FEED_ENV" <<'EOF'
MLAT_USER="alice"
EOF
    # Point sidecar at a path whose parent cannot be created (parent is a
    # regular file).
    BAD_PARENT="$TMP/not-a-dir"
    : > "$BAD_PARENT"
    META="$BAD_PARENT/feed.meta.json"
    run bash -c "
        set -e
        source '$COMMON_LIB'
        source '$LIB'
        migrate_seed_feed_meta_json '$FEED_ENV' '$META'
    "
    # set -e + return 0 from the migration ⇒ status 0 even on internal failure.
    [ "$status" -eq 0 ]
    [ ! -f "$META" ]
}

@test "run_config_file_migrations: produces feed.meta.json alongside feed.env" {
    cat > "$FEED_ENV" <<'EOF'
USER="alice"
LATITUDE="52.5"
LONGITUDE="13.4"
EOF
    run_config_file_migrations "$FEED_ENV"
    META="$(dirname "$FEED_ENV")/feed.meta.json"
    [ -f "$META" ]
    [ "$(jq -r '.schema_version' "$META")" = "1" ]
    # MLAT_USER landed via migrate_user_to_mlat_split; key presence triggers seed.
    [ "$(jq -r '.fields.MLAT_USER.edited_by' "$META")" = "legacy" ]
}

# ---------------------------------------------------------------------------
# migrate_net_options_mlat_forwarding
# ---------------------------------------------------------------------------

@test "migrate_net_options_mlat_forwarding: no feed.env → no-op" {
    rm -f "$FEED_ENV"
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    [ ! -f "$FEED_ENV" ]
}

@test "migrate_net_options_mlat_forwarding: feed.env without NET_OPTIONS → no-op" {
    # Fresh manual install relies on the wrapper default (which already
    # includes both knobs + loopback bind). Nothing to migrate.
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
LATITUDE="52.5"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    ! grep -q -- '--forward-mlat' "$FEED_ENV"
    ! grep -q -- '--net-bi-port' "$FEED_ENV"
    [ ! -f "${FEED_ENV}.pre-mlat-forwarding" ]
}

@test "migrate_net_options_mlat_forwarding: legacy single-line NET_OPTIONS gets both knobs appended" {
    # Canonical legacy /etc/default/airplanes shape after migration via cp.
    # 30004,30104 was the legacy bi-port pair; 30187 is the new MLAT-feedback
    # listener. --forward-mlat was never set in legacy NET_OPTIONS.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-heartbeat 60 --net-ri-port 30001 --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004,30104 --net-bo-port 30005"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -q -- '--net-bi-port 30004,30104,30187' "$FEED_ENV"
    grep -q -- '--forward-mlat' "$FEED_ENV"
    # Existing port list members preserved.
    grep -q -- '--net-bo-port 30005' "$FEED_ENV"
    grep -q -- '--net-ri-port 30001' "$FEED_ENV"
    # Backup written.
    [ -f "${FEED_ENV}.pre-mlat-forwarding" ]
}

@test "migrate_net_options_mlat_forwarding: legacy multi-line NET_OPTIONS gets normalized + both knobs appended" {
    # The verbatim shape from airplanes-update/boot-configs/airplanes-env.
    # cp -fp preserves multi-line; the migration normalizes to single-line
    # as a side effect of the rewrite.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-heartbeat 60 --net-ro-size 1200 --net-ro-interval 0.1 \
        --net-ri-port 30001 --net-ro-port 30002 --net-sbs-port 30003 \
        --net-bi-port 30004,30104 --net-bo-port 30005"
INPUT="127.0.0.1:30005"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    # After migration, NET_OPTIONS is single-line.
    [ "$(grep -c '^NET_OPTIONS=' "$FEED_ENV")" = "1" ]
    # No backslash-continuation remains in the file (would be a sign the
    # join didn't happen).
    if grep -qE '\\$' "$FEED_ENV"; then
        return 1
    fi
    # Knobs appended.
    grep -q -- '--net-bi-port 30004,30104,30187' "$FEED_ENV"
    grep -q -- '--forward-mlat' "$FEED_ENV"
    # Other keys (INPUT) unaffected.
    grep -q '^INPUT="127.0.0.1:30005"$' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: NET_OPTIONS already has --forward-mlat + 30187 → no-op" {
    # Operator already hand-edited (or migration already applied). Must
    # not duplicate the appends.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bi-port 30004,30104,30187 --forward-mlat"
EOF
    local before
    before="$(cat "$FEED_ENV")"
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$before" ]
    [ ! -f "${FEED_ENV}.pre-mlat-forwarding" ]
}

@test "migrate_net_options_mlat_forwarding: idempotent — running twice is identical to running once" {
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bi-port 30004,30104 --net-bo-port 30005"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    local after_once
    after_once="$(cat "$FEED_ENV")"
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$after_once" ]
}

@test "migrate_net_options_mlat_forwarding: NET_OPTIONS without --net-bi-port at all → flag appended" {
    # Operator may have hand-stripped --net-bi-port. Migration adds it
    # rather than trying to be clever about preserving operator intent.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-heartbeat 60 --net-ro-port 0"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -q -- '--net-bi-port 30187' "$FEED_ENV"
    grep -q -- '--forward-mlat' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: NET_OPTIONS has 30187 but lacks --forward-mlat → only --forward-mlat appended" {
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bi-port 30187 --net-bo-port 30005"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -q -- '--forward-mlat' "$FEED_ENV"
    # 30187 not duplicated.
    [ "$(grep -o -- '30187' "$FEED_ENV" | wc -l)" = "1" ]
}

@test "migrate_net_options_mlat_forwarding: NET_OPTIONS has --forward-mlat but lacks 30187 → only 30187 added to bi-port list" {
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bi-port 30004,30104 --forward-mlat"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -q -- '--net-bi-port 30004,30104,30187' "$FEED_ENV"
    # --forward-mlat not duplicated.
    [ "$(grep -o -- '--forward-mlat' "$FEED_ENV" | wc -l)" = "1" ]
}

@test "migrate_net_options_mlat_forwarding: 30187 boundary match — port list with 130187 does not skip the migration" {
    # Pathological port-list with 130187 must not match \b30187\b. The
    # migration should still recognize 30187 as absent and extend.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bi-port 130187,30104"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -q -- '--net-bi-port 130187,30104,30187' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: does NOT touch --net-bind-address (preserves legacy 0.0.0.0 posture)" {
    # Migrated installs keep their pre-existing bind posture. A legacy
    # NET_OPTIONS without --net-bind-address stays without it after
    # migration — only the MLAT knobs are appended.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bi-port 30004,30104"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    ! grep -q -- '--net-bind-address' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: preserves an existing operator-set --net-bind-address" {
    # If the operator set their own bind-address (loopback or other), the
    # migration leaves it alone.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bind-address 10.0.0.5 --net-bi-port 30004,30104"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -q -- '--net-bind-address 10.0.0.5' "$FEED_ENV"
    grep -q -- '--net-bi-port 30004,30104,30187' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: commented --forward-mlat does NOT trick idempotency into skipping" {
    # Detection must look at the ACTIVE NET_OPTIONS value, not the whole
    # file. A pre-migration feed.env with a comment line that happens to
    # mention --forward-mlat must still trigger the migration on the
    # actual NET_OPTIONS line below.
    cat > "$FEED_ENV" <<'EOF'
# Note: --forward-mlat was historically off; we now enable it.
NET_OPTIONS="--net --net-bi-port 30004,30104"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    # Active NET_OPTIONS now has the appends.
    grep -qE '^NET_OPTIONS=.*--forward-mlat' "$FEED_ENV"
    grep -qE '^NET_OPTIONS=.*30187' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: commented --net-bi-port 30187 does NOT trick idempotency into skipping" {
    cat > "$FEED_ENV" <<'EOF'
# Old shape: NET_OPTIONS="--net-bi-port 30187,30004,30104"
NET_OPTIONS="--net --net-bi-port 30004,30104 --forward-mlat"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -qE '^NET_OPTIONS=.*--net-bi-port 30004,30104,30187' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: single-quoted NET_OPTIONS still gets the appends (extract-modify-rewrite)" {
    # The extract-modify-rewrite refactor handles single-quoted shapes
    # that the original sed-substring pass would have silently skipped.
    # Re-emitted as double-quoted, matching the canonical schema.
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS='--net --net-bi-port 30004,30104'
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    grep -qE '^NET_OPTIONS="--net --net-bi-port 30004,30104,30187 --forward-mlat"$' "$FEED_ENV"
}

@test "migrate_net_options_mlat_forwarding: backup written once and never overwritten" {
    cat > "$FEED_ENV" <<'EOF'
NET_OPTIONS="--net --net-bi-port 30004,30104"
EOF
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    local first_backup_mtime
    first_backup_mtime="$(stat -c '%Y' "${FEED_ENV}.pre-mlat-forwarding")"
    # Mutate feed.env, run again, confirm backup unchanged.
    sleep 1
    printf 'NET_OPTIONS="--changed"\n' > "$FEED_ENV"
    migrate_net_options_mlat_forwarding "$FEED_ENV"
    [ "$(stat -c '%Y' "${FEED_ENV}.pre-mlat-forwarding")" = "$first_backup_mtime" ]
}

