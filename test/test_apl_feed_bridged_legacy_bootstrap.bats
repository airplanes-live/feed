#!/usr/bin/env bats

# End-to-end regression for the bridged-legacy bootstrap path:
# `apl-feed mlat enable` / `apl-feed mlat disable` / `apl-feed 978 enable`
# / `apl-feed 978 disable` on a box where /usr/bin/airplanes-feeder is
# present, /boot/airplanes-config.txt is populated by the legacy PHP
# webconfig, and /etc/airplanes/feed.env does NOT yet exist. The writer
# adapters call feed_env_ensure_canonical_for_write() before invoking
# apl_feed_apply, which calls apl_feed_import_legacy_config to seed the
# canonical file from the legacy source. apl_feed_apply is real here —
# no stub — so the assertions verify actual canonical state after the
# command, not just the resolver inputs.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../scripts/apl-feed"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    mkdir -p "$STUB_DIR"

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/configure-validators.sh"
    # shellcheck source=../scripts/lib/feed-env-keys.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-keys.sh"
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/feed-env-apply.sh"
    # shellcheck source=../scripts/lib/legacy-mlat-translation.sh
    source "$BATS_TEST_DIRNAME/../scripts/lib/legacy-mlat-translation.sh"
    # shellcheck source=../scripts/apl-feed/common.sh
    source "$LIB_DIR/common.sh"
    # shellcheck source=../scripts/apl-feed/import.sh
    source "$LIB_DIR/import.sh"
    # shellcheck source=../scripts/apl-feed/mlat.sh
    source "$LIB_DIR/mlat.sh"
    # shellcheck source=../scripts/apl-feed/uat.sh
    source "$LIB_DIR/uat.sh"
    eval "$bats_exit_trap"
    ROOT="$ROOT_DIR"

    APL_TEST_LOCK_FILE="$ROOT_DIR/feed-env.lock"
    feed_env_lock_path() { printf '%s\n' "$APL_TEST_LOCK_FILE"; }

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
case "\$1" in
    is-active) echo active ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    # No-op logger stub so the apply-time journald audit doesn't reach
    # the host's real /dev/log.
    cat > "$STUB_DIR/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/logger"
    PATH="$STUB_DIR:$PATH"
    export PATH

    # Bridged-legacy shape: airplanes-feeder installed, no canonical
    # feed.env, legacy boot config carrying operational keys.
    mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/boot" "$ROOT_DIR/etc/airplanes"
    : > "$ROOT_DIR/usr/bin/airplanes-feeder"
    chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"
    cat > "$ROOT_DIR/boot/airplanes-config.txt" <<EOF
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
MLAT_MARKER=no
EOF
}

teardown() {
    rm -rf "$ROOT_DIR"
}

@test "mlat disable on bridged-legacy: bootstrap + canonical write, legacy untouched" {
    local source_before
    source_before="$(cat "$ROOT_DIR/boot/airplanes-config.txt")"
    [ ! -e "$ROOT_DIR/etc/airplanes/feed.env" ]

    apl_feed_mlat_disable

    [ -f "$ROOT_DIR/etc/airplanes/feed.env" ]
    grep -qE '^MLAT_USER="alice"$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE '^MLAT_ENABLED=(false|"false")$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE '^MLAT_PRIVATE=(true|"true")$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE '^LATITUDE="?52\.5"?$' "$ROOT_DIR/etc/airplanes/feed.env"

    # Source legacy file must be byte-unchanged: the writer must never
    # rewrite the bridged-legacy reader-fallback target.
    [ "$source_before" = "$(cat "$ROOT_DIR/boot/airplanes-config.txt")" ]
}

@test "mlat enable on bridged-legacy: bootstrap satisfies geo-gate" {
    # Before the bootstrap helper landed, mlat enable on this shape died
    # with "GEO_CONFIGURED=<unset>" before it ever reached the writer.
    local source_before
    source_before="$(cat "$ROOT_DIR/boot/airplanes-config.txt")"

    apl_feed_mlat_enable

    [ -f "$ROOT_DIR/etc/airplanes/feed.env" ]
    grep -qE '^MLAT_ENABLED=(true|"true")$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE '^GEO_CONFIGURED=(true|"true")$' "$ROOT_DIR/etc/airplanes/feed.env"
    grep -qE '^MLAT_USER="alice"$' "$ROOT_DIR/etc/airplanes/feed.env"
    [ "$source_before" = "$(cat "$ROOT_DIR/boot/airplanes-config.txt")" ]
}

@test "978 disable on bridged-legacy: bootstrap then write canonical UAT_INPUT" {
    # Seed the fixture with a canonical UAT_INPUT so the bootstrap carries
    # it through, then 978 disable clears it.
    cat >> "$ROOT_DIR/boot/airplanes-config.txt" <<'EOF'
UAT_INPUT=127.0.0.1:30978
EOF
    local source_before
    source_before="$(cat "$ROOT_DIR/boot/airplanes-config.txt")"

    apl_feed_uat_disable

    [ -f "$ROOT_DIR/etc/airplanes/feed.env" ]
    grep -qE '^UAT_INPUT=""?$' "$ROOT_DIR/etc/airplanes/feed.env"
    [ "$source_before" = "$(cat "$ROOT_DIR/boot/airplanes-config.txt")" ]
}

@test "second invocation is idempotent: no double-bootstrap, canonical reused" {
    apl_feed_mlat_disable
    local feed_env_first
    feed_env_first="$(cat "$ROOT_DIR/etc/airplanes/feed.env")"

    # Second call reads canonical, no bootstrap needed.
    apl_feed_mlat_disable

    local feed_env_second
    feed_env_second="$(cat "$ROOT_DIR/etc/airplanes/feed.env")"
    [ "$feed_env_first" = "$feed_env_second" ]
}

@test "bootstrap failure under set -e does not exit before structured error" {
    # apl-feed.sh runs set -euo pipefail. A bare feed_env_ensure_canonical_
    # for_write that returned non-zero on bootstrap failure would exit the
    # script before _mlat_emit_result could surface the structured error
    # to the operator. Verify the helper always returns 0 so the bare-call
    # writers stay set-e-safe.
    rm -rf "$ROOT_DIR/etc/airplanes"
    # Stub the import to force a failure path.
    apl_feed_import_legacy_config() { return 1; }

    run bash -c '
set -euo pipefail
source "'"$BATS_TEST_DIRNAME"'/../scripts/lib/configure-validators.sh"
source "'"$BATS_TEST_DIRNAME"'/../scripts/lib/feed-env-keys.sh"
source "'"$BATS_TEST_DIRNAME"'/../scripts/apl-feed/common.sh"
ROOT='"$ROOT_DIR"'
mkdir -p "$ROOT/usr/bin" "$ROOT/boot"
: > "$ROOT/usr/bin/airplanes-feeder"
chmod +x "$ROOT/usr/bin/airplanes-feeder"
: > "$ROOT/boot/airplanes-config.txt"
apl_feed_import_legacy_config() { return 1; }
feed_env_ensure_canonical_for_write
echo "survived: rc=$?"
'
    [ "$status" -eq 0 ]
    [[ "$output" == *'survived: rc=0'* ]]
    [[ "$output" == *'bootstrap import failed'* ]]
}
