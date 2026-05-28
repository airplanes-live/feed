#!/usr/bin/env bats
#
# Covers airplanes_is_overlay_managed_root and airplanes_guard_overlay_managed_root
# from scripts/lib/install-update-common.sh.
#
# The guard refuses to run feed's install.sh / update.sh on a system whose
# feed stack is delivered by the airplanes-live runtime overlay — so an
# operator who SSHs onto an image-managed feeder and runs the upstream
# installer cannot replace overlay-owned symlinks with stale real files.

setup() {
    HELPER="$BATS_TEST_DIRNAME/../scripts/lib/install-update-common.sh"
    ROOT_DIR="$(mktemp -d)"
    mkdir -p "$ROOT_DIR/etc/airplanes"
    export AIRPLANES_ROOT="$ROOT_DIR"
    unset AIRPLANES_ALLOW_OVERLAY_BYPASS
    unset AIRPLANES_BUILD_MODE
    # shellcheck source=../scripts/lib/install-update-common.sh
    source "$HELPER"
    airplanes_init_paths
}

teardown() {
    rm -rf "$ROOT_DIR"
}

manifest_path() {
    printf '%s' "$ROOT_DIR/etc/airplanes/runtime-manifest.json"
}

write_regular_manifest() {
    printf '{"version":"0.0.0-test"}\n' > "$(manifest_path)"
}

write_symlink_manifest_to_real_file() {
    local target="$ROOT_DIR/opt/airplanes-runtime/releases/v0.0.0-test/manifest.json"
    mkdir -p "$(dirname "$target")"
    printf '{"version":"0.0.0-test"}\n' > "$target"
    mkdir -p "$ROOT_DIR/opt/airplanes-runtime"
    # `current` and the manifest symlink both use relative targets so the
    # chain resolves against the test's AIRPLANES_ROOT — this case must
    # genuinely exercise `-e` (healthy chain) rather than degenerate into
    # the dangling-link case covered separately below.
    ln -sfn "releases/v0.0.0-test" "$ROOT_DIR/opt/airplanes-runtime/current"
    ln -sfn "../../opt/airplanes-runtime/current/manifest.json" "$(manifest_path)"
}

write_dangling_symlink_manifest() {
    ln -sfn "/opt/airplanes-runtime/current/manifest.json" "$(manifest_path)"
}

# ---------------------------------------------------------------------------
# airplanes_is_overlay_managed_root — pure predicate
# ---------------------------------------------------------------------------

@test "is_overlay_managed_root: returns 0 when marker is a regular file" {
    write_regular_manifest
    run airplanes_is_overlay_managed_root
    [ "$status" -eq 0 ]
}

@test "is_overlay_managed_root: returns 0 when marker is a symlink to a real file" {
    write_symlink_manifest_to_real_file
    run airplanes_is_overlay_managed_root
    [ "$status" -eq 0 ]
}

@test "is_overlay_managed_root: returns 0 when marker is a dangling symlink" {
    write_dangling_symlink_manifest
    run airplanes_is_overlay_managed_root
    [ "$status" -eq 0 ]
}

@test "is_overlay_managed_root: returns 1 when marker is absent" {
    run airplanes_is_overlay_managed_root
    [ "$status" -ne 0 ]
}

@test "is_overlay_managed_root: returns 1 when /etc/airplanes does not exist" {
    rm -rf "$ROOT_DIR/etc/airplanes"
    run airplanes_is_overlay_managed_root
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# airplanes_guard_overlay_managed_root — abort / bypass paths
# ---------------------------------------------------------------------------

@test "guard: aborts with EX_CONFIG (78) when marker present" {
    write_regular_manifest
    run airplanes_guard_overlay_managed_root "feed update.sh"
    [ "$status" -eq 78 ]
    [[ "$output" == *"airplanes-live runtime overlay"* ]]
    [[ "$output" == *"feed update.sh"* ]]
    [[ "$output" == *"AIRPLANES_ALLOW_OVERLAY_BYPASS=1"* ]]
}

@test "guard: error message names the manifest path" {
    write_regular_manifest
    run airplanes_guard_overlay_managed_root
    [ "$status" -eq 78 ]
    [[ "$output" == *"$(manifest_path)"* ]]
}

@test "guard: returns 0 silently when marker absent" {
    run airplanes_guard_overlay_managed_root
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "guard: AIRPLANES_ALLOW_OVERLAY_BYPASS=1 prints warning and returns 0 when marker present" {
    write_regular_manifest
    AIRPLANES_ALLOW_OVERLAY_BYPASS=1 run airplanes_guard_overlay_managed_root
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: AIRPLANES_ALLOW_OVERLAY_BYPASS=1"* ]]
}

@test "guard: AIRPLANES_ALLOW_OVERLAY_BYPASS=1 is silent when marker absent" {
    AIRPLANES_ALLOW_OVERLAY_BYPASS=1 run airplanes_guard_overlay_managed_root
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "guard: build mode skips the guard even when marker present" {
    write_regular_manifest
    AIRPLANES_BUILD_MODE=1 run airplanes_guard_overlay_managed_root
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "guard: build-mode synonyms (true/yes) also skip the guard" {
    write_regular_manifest
    AIRPLANES_BUILD_MODE=true run airplanes_guard_overlay_managed_root
    [ "$status" -eq 0 ]
    AIRPLANES_BUILD_MODE=yes run airplanes_guard_overlay_managed_root
    [ "$status" -eq 0 ]
}

@test "guard: build-mode trumps bypass when both set with marker present" {
    # Belt-and-suspenders: build-mode skip wins over the explicit bypass path
    # (it should return 0 silently, not the warning path).
    write_regular_manifest
    AIRPLANES_BUILD_MODE=1 AIRPLANES_ALLOW_OVERLAY_BYPASS=1 run airplanes_guard_overlay_managed_root
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# Integration: confirm the guard actually fires update.sh / install.sh aborts
# ---------------------------------------------------------------------------
#
# update.sh and install.sh both call airplanes_guard_overlay_managed_root
# early in their flow. Wrap each in a fresh `bash -c` to keep set -e and
# its dynamic-scope semantics honest (see rules/testing.md).

@test "update.sh: aborts 78 when manifest present and not bypassed" {
    write_regular_manifest
    # Pre-create $IPATH bits update.sh would touch — guard fires before
    # most setup, but airplanes_require_root needs the skip flag.
    AIRPLANES_SKIP_ROOT_CHECK=1 \
    AIRPLANES_FEED_BRANCH=dev \
        run bash "$BATS_TEST_DIRNAME/../update.sh"
    [ "$status" -eq 78 ]
    [[ "$output" == *"airplanes-live runtime overlay"* ]]
}

@test "install.sh: aborts 78 when manifest present and not bypassed" {
    write_regular_manifest
    AIRPLANES_SKIP_ROOT_CHECK=1 \
    AIRPLANES_FEED_BRANCH=dev \
        run bash "$BATS_TEST_DIRNAME/../install.sh"
    [ "$status" -eq 78 ]
    [[ "$output" == *"airplanes-live runtime overlay"* ]]
}
