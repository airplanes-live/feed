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
    source "$REPO_ROOT/scripts/lib/configure-validators.sh"
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
# migrate_altitude_to_bare_metres
# ---------------------------------------------------------------------------

@test "migrate_altitude_to_bare_metres: ALTITUDE=120m → ALTITUDE=120 (strip suffix)" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="120m"
GEO_CONFIGURED=true
EOF
    migrate_altitude_to_bare_metres "$FEED_ENV"

    grep -qx 'ALTITUDE="120"' "$FEED_ENV"
    grep -qx 'LATITUDE="52.5"' "$FEED_ENV"
    grep -qx 'LONGITUDE="13.4"' "$FEED_ENV"
    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
}

@test "migrate_altitude_to_bare_metres: ALTITUDE=400ft → ALTITUDE=121.92" {
    cat > "$FEED_ENV" <<'EOF'
ALTITUDE="400ft"
EOF
    migrate_altitude_to_bare_metres "$FEED_ENV"

    grep -qx 'ALTITUDE="121.92"' "$FEED_ENV"
}

@test "migrate_altitude_to_bare_metres: bare ALTITUDE=42.5 is unchanged (idempotent)" {
    cat > "$FEED_ENV" <<'EOF'
ALTITUDE="42.5"
EOF
    local before
    before="$(cat "$FEED_ENV")"
    migrate_altitude_to_bare_metres "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$before" ]
}

@test "migrate_altitude_to_bare_metres: empty ALTITUDE is unchanged" {
    cat > "$FEED_ENV" <<'EOF'
ALTITUDE=""
EOF
    local before
    before="$(cat "$FEED_ENV")"
    migrate_altitude_to_bare_metres "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$before" ]
}

@test "migrate_altitude_to_bare_metres: missing ALTITUDE key is a no-op" {
    cat > "$FEED_ENV" <<'EOF'
LATITUDE="52.5"
LONGITUDE="13.4"
EOF
    local before
    before="$(cat "$FEED_ENV")"
    migrate_altitude_to_bare_metres "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$before" ]
}

@test "migrate_altitude_to_bare_metres: garbage value is preserved with a warning" {
    cat > "$FEED_ENV" <<'EOF'
ALTITUDE="not-a-number"
LATITUDE="52.5"
EOF
    local before
    before="$(cat "$FEED_ENV")"
    run migrate_altitude_to_bare_metres "$FEED_ENV"
    [ "$status" -eq 0 ]
    [ "$(cat "$FEED_ENV")" = "$before" ]
    [[ "$output" == *"leaving ALTITUDE=\"not-a-number\" untouched"* ]]
}

@test "migrate_altitude_to_bare_metres: out-of-range value is preserved with a warning" {
    # 33000ft is ~10058m, just above the 10000m upper bound.
    cat > "$FEED_ENV" <<'EOF'
ALTITUDE="33000ft"
EOF
    local before
    before="$(cat "$FEED_ENV")"
    run migrate_altitude_to_bare_metres "$FEED_ENV"
    [ "$status" -eq 0 ]
    [ "$(cat "$FEED_ENV")" = "$before" ]
    [[ "$output" == *"33000ft"* ]]
}

@test "migrate_altitude_to_bare_metres: second run on bare-metres state is a strict no-op" {
    cat > "$FEED_ENV" <<'EOF'
ALTITUDE="400ft"
EOF
    migrate_altitude_to_bare_metres "$FEED_ENV"
    grep -qx 'ALTITUDE="121.92"' "$FEED_ENV"
    local after_first
    after_first="$(cat "$FEED_ENV")"

    migrate_altitude_to_bare_metres "$FEED_ENV"
    [ "$(cat "$FEED_ENV")" = "$after_first" ]
}

@test "migrate_altitude_to_bare_metres: does NOT bump feed.meta.json metadata" {
    # The migration is a representation flip, not a semantic edit. The
    # sidecar's edited_at must stay where it was so a freshly-stamped
    # website edit still wins over the pre-migration feeder tuple.
    cat > "$FEED_ENV" <<'EOF'
ALTITUDE="120m"
EOF
    META="$TMP/feed.meta.json"
    cat > "$META" <<'EOF'
{"schema_version":1,"fields":{"ALTITUDE":{"edited_at":"2024-06-01T00:00:00Z","edited_by":"legacy"}}}
EOF
    local meta_before
    meta_before="$(cat "$META")"

    migrate_altitude_to_bare_metres "$FEED_ENV"

    grep -qx 'ALTITUDE="120"' "$FEED_ENV"
    [ "$(cat "$META")" = "$meta_before" ]
}

@test "migrate_altitude_to_bare_metres: preserves all non-altitude keys verbatim" {
    cat > "$FEED_ENV" <<'EOF'
INPUT="127.0.0.1:30005"
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="400ft"
GEO_CONFIGURED=true
NET_OPTIONS="--net-heartbeat 60"
GAIN=auto
EOF
    migrate_altitude_to_bare_metres "$FEED_ENV"

    grep -qx 'INPUT="127.0.0.1:30005"' "$FEED_ENV"
    grep -qx 'MLAT_USER="alice"' "$FEED_ENV"
    grep -qx 'MLAT_ENABLED=true' "$FEED_ENV"
    grep -qx 'MLAT_PRIVATE=false' "$FEED_ENV"
    grep -qx 'LATITUDE="52.5"' "$FEED_ENV"
    grep -qx 'LONGITUDE="13.4"' "$FEED_ENV"
    grep -qx 'ALTITUDE="121.92"' "$FEED_ENV"
    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
    grep -qx 'NET_OPTIONS="--net-heartbeat 60"' "$FEED_ENV"
    grep -qx 'GAIN=auto' "$FEED_ENV"
}

@test "run_config_file_migrations: altitude bare-metres flip runs in the chain" {
    cat > "$FEED_ENV" <<'EOF'
USER="alice"
LATITUDE="52.5"
LONGITUDE="13.4"
ALTITUDE="400ft"
EOF
    run_config_file_migrations "$FEED_ENV"

    grep -qx 'MLAT_USER="alice"' "$FEED_ENV"
    grep -qx 'GEO_CONFIGURED=true' "$FEED_ENV"
    grep -qx 'ALTITUDE="121.92"' "$FEED_ENV"
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
        source '$REPO_ROOT/scripts/lib/configure-validators.sh'
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

