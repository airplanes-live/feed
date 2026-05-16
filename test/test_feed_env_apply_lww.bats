#!/usr/bin/env bats

# Tests for the metadata-LWW gate in scripts/lib/feed-env-apply.sh.
# When an apl_feed_apply call carries per-key incoming metadata (the
# APL_APPLY_INCOMING_META_* globals), the library compares each key's
# incoming `edited_at` against the on-disk `edited_at` in feed.meta.json
# and skips writes whose incoming tuple is NOT strictly newer.
#
# The gate is the prerequisite that makes `apl-feed config sync` safe
# against a concurrent operator write that lands between the sync's
# snapshot read and its apply step.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/scripts/lib"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    SYSTEMCTL_LOG="$ROOT_DIR/systemctl.log"
    mkdir -p "$STUB_DIR" "$ROOT_DIR/etc/airplanes" "$ROOT_DIR/run/airplanes"

    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck source=../scripts/lib/configure-validators.sh
    source "$LIB/configure-validators.sh"
    # shellcheck source=../scripts/lib/feed-env-keys.sh
    source "$LIB/feed-env-keys.sh"
    # shellcheck source=../scripts/lib/feed-env-apply.sh
    source "$LIB/feed-env-apply.sh"
    eval "$bats_exit_trap"

    FEED_ENV="$ROOT_DIR/etc/airplanes/feed.env"
    META_FILE="$ROOT_DIR/etc/airplanes/feed.meta.json"
    LOCK_FILE="$ROOT_DIR/run/airplanes/feed-env.lock"

    cat > "$STUB_DIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    cat > "$STUB_DIR/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/logger"
    PATH="$STUB_DIR:$PATH"
    export PATH

    # Deterministic clock for the LWW gate: anchor "now" at a fixed
    # 2026-05-14T12:00:00Z. The bogus-future-heal threshold becomes
    # 2026-05-14T12:05:00Z — anything on-disk past that point heals,
    # anything at or before stays under LWW.
    _apl_feed_apply_iso_now() { printf '2026-05-14T12:00:00Z'; }
    _apl_feed_apply_iso_plus_seconds() { printf '2026-05-14T12:05:00Z'; }
}

teardown() {
    rm -rf "$ROOT_DIR"
}

seed_feed_env() {
    cat > "$FEED_ENV" <<EOF
LATITUDE="52.52"
LONGITUDE="13.40"
ALTITUDE="120m"
GEO_CONFIGURED=true
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_PRIVATE=false
GAIN=auto
EOF
}

# Build feed.meta.json from a flat (KEY, edited_at) pair list. Every
# entry's edited_by is "feeder" — the LWW gate only reads edited_at.
seed_meta() {
    local -a pairs=("$@")
    local filter='{schema_version: 1, fields: {}}'
    local jq_args=()
    local i=0 k at
    while (( i < ${#pairs[@]} )); do
        k="${pairs[$i]}"
        at="${pairs[$((i + 1))]}"
        jq_args+=(--arg "k${i}" "$k" --arg "a${i}" "$at")
        filter+=" | .fields[\$k${i}] = {edited_at: \$a${i}, edited_by: \"feeder\"}"
        i=$((i + 2))
    done
    jq -nc "${jq_args[@]}" "$filter" > "$META_FILE"
}

# Clear incoming-metadata globals so each test starts clean.
reset_incoming_meta() {
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
}

do_apply() {
    APL_APPLY_RC=0
    apl_feed_apply --feed-env "$FEED_ENV" --lock-file "$LOCK_FILE" "$@" \
        || APL_APPLY_RC=$?
}

read_disk_value() {
    local key="$1"
    # feed.env values may be unquoted (booleans) or quoted (strings).
    grep -E "^${key}=" "$FEED_ENV" | head -n 1 | sed -E 's/^[A-Z_]+=//; s/^"//; s/"$//'
}

read_meta_edited_at() {
    local key="$1"
    jq -r --arg k "$key" '.fields[$k].edited_at // empty' "$META_FILE"
}

@test "LWW skips an older incoming write" {
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T12:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T10:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="feeder"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ "${#APL_APPLY_CHANGED[@]}" -eq 0 ]
    [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " MLAT_USER " ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2026-05-14T12:00:00Z" ]
}

@test "LWW applies a strictly-newer incoming write" {
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T10:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T12:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="website"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ " ${APL_APPLY_CHANGED[*]} " = " MLAT_USER " ]
    [ "${#APL_APPLY_SKIPPED_BY_LWW[@]}" -eq 0 ]
    [ "$(read_disk_value MLAT_USER)" = "bob" ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2026-05-14T12:00:00Z" ]
}

@test "LWW favors disk on exact-equal edited_at" {
    # Symmetric with the server-side LWW: tie -> existing tuple wins.
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T12:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T12:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="feeder"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " MLAT_USER " ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
}

@test "LWW applies when sidecar has no entry for the key (bootstrap)" {
    seed_feed_env
    # Empty fields object -> on-disk metadata absent for every key.
    seed_meta
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2020-01-01T00:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="legacy"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_STATUS" = "applied" ]
    [ " ${APL_APPLY_CHANGED[*]} " = " MLAT_USER " ]
    [ "${#APL_APPLY_SKIPPED_BY_LWW[@]}" -eq 0 ]
    [ "$(read_disk_value MLAT_USER)" = "bob" ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2020-01-01T00:00:00Z" ]
}

@test "bare-string write bypasses LWW gate" {
    # Existing operator-facing callers (mlat user, etc.) don't pass
    # incoming metadata; the lib stamps now() on their behalf. The gate
    # must not affect them.
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T11:30:00Z"
    reset_incoming_meta

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_STATUS" = "applied" ]
    [ " ${APL_APPLY_CHANGED[*]} " = " MLAT_USER " ]
    [ "$(read_disk_value MLAT_USER)" = "bob" ]
}

@test "fractional-second incoming beats unfractioned on-disk same-second stamp" {
    # Microsecond precision is preserved through normalize so a writer
    # that lands a few microseconds after a same-second on-disk stamp
    # is ordered correctly. The on-disk no-fraction form normalizes to
    # `.000000`; an incoming `.000001` is strictly newer.
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T12:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T12:00:00.000001Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="feeder"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_STATUS" = "applied" ]
    [ " ${APL_APPLY_CHANGED[*]} " = " MLAT_USER " ]
    [ "${#APL_APPLY_SKIPPED_BY_LWW[@]}" -eq 0 ]
    [ "$(read_disk_value MLAT_USER)" = "bob" ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2026-05-14T12:00:00.000001Z" ]
}

@test "sub-second LWW orders two same-second incoming writes" {
    # Two webconfig saves within the same wall-clock-second must not
    # collide under LWW: the second one is strictly newer and applies.
    # Without microsecond-preserving normalize the second save was
    # silently dropped (DEV-383 review finding).
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T12:00:00.100000Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T12:00:00.500000Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="feeder"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_STATUS" = "applied" ]
    [ " ${APL_APPLY_CHANGED[*]} " = " MLAT_USER " ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2026-05-14T12:00:00.500000Z" ]
}

@test "sub-second LWW skips an older same-second incoming write" {
    # Mirror of the test above with ordering reversed: an incoming
    # stamp earlier than the on-disk stamp inside the same second loses.
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T12:00:00.500000Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T12:00:00.100000Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="feeder"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " MLAT_USER " ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
}

@test "normalize pads bare on-disk stamps to microsecond width for compare" {
    # Older sidecar entries written before the microsecond-preserving
    # normalize landed will have second-precision stamps. They must
    # still compare correctly against new microsecond stamps. An
    # incoming `12:00:00.000000Z` ties an on-disk `12:00:00Z` (both
    # normalize to .000000) and the tie favors disk.
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T12:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T12:00:00.000000Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="feeder"

    do_apply --no-restart MLAT_USER=bob

    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " MLAT_USER " ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
}

@test "mixed batch: one skip, one apply" {
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T11:30:00Z" ALTITUDE "2020-01-01T00:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T10:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="website"
    APL_APPLY_INCOMING_META_EDITED_AT[ALTITUDE]="2026-05-14T10:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[ALTITUDE]="website"

    do_apply --no-restart MLAT_USER=bob ALTITUDE=200m

    [ "$APL_APPLY_STATUS" = "applied" ]
    [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " MLAT_USER " ]
    # Only ALTITUDE should be in CHANGED.
    [ " ${APL_APPLY_CHANGED[*]} " = " ALTITUDE " ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
    [ "$(read_disk_value ALTITUDE)" = "200m" ]
}

@test "all-skip batch resolves to no_change" {
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T11:30:00Z" ALTITUDE "2026-05-14T11:30:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T10:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="website"
    APL_APPLY_INCOMING_META_EDITED_AT[ALTITUDE]="2026-05-14T10:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[ALTITUDE]="website"

    do_apply --no-restart MLAT_USER=bob ALTITUDE=200m

    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ "${#APL_APPLY_CHANGED[@]}" -eq 0 ]
    [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " ALTITUDE MLAT_USER " ] \
        || [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " MLAT_USER ALTITUDE " ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
    [ "$(read_disk_value ALTITUDE)" = "120m" ]
}

@test "bogus-future heal uses APL_APPLY_INCOMING_SERVER_TIME when set" {
    # A feeder whose local clock is ahead would have computed
    # `now + 300s` past the on-disk stamp, marking it as legitimate and
    # re-skipping the heal. With the server-time override the threshold
    # is computed against trusted time and the heal fires.
    seed_feed_env
    # On-disk stamp is 3 hours past stubbed local now (12:00) but only
    # a few seconds past stubbed server now (set below).
    seed_meta MLAT_USER "2026-05-14T15:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T15:01:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="website"
    # Without server time, local-now + 5min = 12:05, on-disk 15:00 > 12:05
    # would already be flagged as bogus-future and heal. Pin server time
    # to 15:00:30 — only 30s before on-disk's 15:00, well inside the
    # 300s skew window, so the heal MUST be driven by the bogus-future
    # logic re-anchored on server time.
    APL_APPLY_INCOMING_SERVER_TIME="2026-05-14T15:00:30Z"

    do_apply --no-restart MLAT_USER=alice

    # incoming 15:01 > on-disk 15:00 — applies normally; the server-time
    # path doesn't change the per-key result here. Test the negative
    # case below to prove the path actually fires.
    [ "$APL_APPLY_STATUS" = "applied" ]
    APL_APPLY_INCOMING_SERVER_TIME=""
}

@test "fast local clock cannot self-mask future on-disk stamps when server_time is supplied" {
    # Reproduces Codex finding: feeder clock fast by 6 min relative to
    # the server. On-disk has a future-stamped tuple (6 min ahead of
    # server). Without server_time the feeder would compute the heal
    # threshold from its own already-fast local-now, conclude the stamp
    # is fine, and skip the heal forever.
    seed_feed_env
    # On-disk stamp is 12:06:00, 6 minutes past server-now.
    seed_meta MLAT_USER "2026-05-14T12:06:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T12:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="feeder"
    # Server time is the trusted reference. Bogus-future threshold is
    # server_time + 300s = 12:05:00. On-disk 12:06:00 > 12:05:00 -> bogus.
    APL_APPLY_INCOMING_SERVER_TIME="2026-05-14T12:00:00Z"

    do_apply --no-restart MLAT_USER=alice  # same value, just metadata heal

    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "${#APL_APPLY_SKIPPED_BY_LWW[@]}" -eq 0 ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2026-05-14T12:00:00Z" ]
    APL_APPLY_INCOMING_SERVER_TIME=""
}

@test "bogus-future on-disk edited_at is healed by incoming server tuple" {
    # rejected_fields-healing scenario: server rejected the feeder's
    # POST because the on-disk edited_at was wildly in the future
    # (e.g. clock misconfig). The server returns its own tuple; the
    # apply must NOT skip via LWW even though incoming is older than
    # the bogus on-disk stamp.
    seed_feed_env
    seed_meta MLAT_USER "3000-01-01T00:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T10:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="website"

    do_apply --no-restart MLAT_USER=alice  # same value, just metadata heal

    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "${#APL_APPLY_SKIPPED_BY_LWW[@]}" -eq 0 ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2026-05-14T10:00:00Z" ]
}

@test "LWW skip survives a no-systemctl environment" {
    # Build-mode skips lock acquisition and sidecar write entirely. The
    # gate should still emit no_change rather than blindly writing.
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T11:30:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T10:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="website"

    AIRPLANES_BUILD_MODE=1 do_apply MLAT_USER=bob

    # In build mode no lock_fd is acquired so the LWW gate's sidecar
    # read sees the on-disk file (file-system read doesn't depend on
    # the lock). The skip still fires.
    [ "$APL_APPLY_STATUS" = "no_change" ]
    [ " ${APL_APPLY_SKIPPED_BY_LWW[*]} " = " MLAT_USER " ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
}

@test "explicit metadata on unchanged tracked key still bumps sidecar edited_at" {
    # Pins the load-bearing behavior the image-webconfig metadata
    # gate depends on (DEV-383): when an incoming object-form payload
    # carries metadata for a tracked key, the sidecar is updated
    # regardless of whether the canonical value changed, provided the
    # LWW gate accepts the incoming edited_at.
    #
    # This is what makes the stuck-future-timestamp heal work
    # (apl-feed config sync reconciles by sending the server tuple
    # even when value matches). It is ALSO why webconfig must not
    # attach metadata to unchanged tracked keys — if it did, every
    # form save would push a fresh edited_at into the sidecar for
    # untouched fields and clobber legitimate concurrent edits under
    # LWW. The omission lives in
    # image-webconfig/internal/feedmeta.BuildApplyPayload; this test
    # guards the apply-side assumption that omission targets.
    seed_feed_env
    seed_meta MLAT_USER "2026-05-14T10:00:00Z"
    reset_incoming_meta
    APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="2026-05-14T11:00:00Z"
    APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="website"

    do_apply --no-restart MLAT_USER=alice  # value unchanged

    [ "$APL_APPLY_RC" -eq 0 ]
    [ "$APL_APPLY_STATUS" = "applied" ]
    [ "${#APL_APPLY_CHANGED[@]}" -eq 0 ]
    [ "${#APL_APPLY_SKIPPED_BY_LWW[@]}" -eq 0 ]
    [ "$(read_disk_value MLAT_USER)" = "alice" ]
    [ "$(read_meta_edited_at MLAT_USER)" = "2026-05-14T11:00:00Z" ]
}
