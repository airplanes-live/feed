#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash "$0" "$@"
fi

FEED_DIR="${AIRPLANES_FEED_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
IMAGE_RELEASE_REPO="${AIRPLANES_IMAGE_RELEASE_REPO:-airplanes-live/image-releases}"
IMAGE_CHANNEL="${AIRPLANES_IMAGE_CHANNEL:-stable}"
IMAGE_ARCH="${AIRPLANES_IMAGE_ARCH:-arm64}"
IMAGE_CONTRACT="${AIRPLANES_IMAGE_CONTRACT:-}"
if [[ -z "$IMAGE_CONTRACT" ]]; then
    if [[ "$IMAGE_RELEASE_REPO" == "airplanes-live/image" ]]; then
        IMAGE_CONTRACT="new"
    else
        IMAGE_CONTRACT="legacy"
    fi
fi
# Asset selection (regex + strict-mode defaults) is owned by
# test/lib/image-source.sh, derived from CONTRACT/CHANNEL/ARCH. The historical
# AIRPLANES_IMAGE_ASSET_REGEX env var is still honored as an override.
# AIRPLANES_IMAGE_SOURCE_TIERS picks the tier order; default `release-any`
# preserves legacy behavior (the historical /releases/latest path picked the
# newest non-prerelease release; release-any now also accepts the rolling
# `dev-latest` prerelease for new-image dev-channel runs).
AIRPLANES_IMAGE_SOURCE_TIERS="${AIRPLANES_IMAGE_SOURCE_TIERS:-release-any}"
# shellcheck source=lib/image-source.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/image-source.sh"

FEED_BRANCH="${AIRPLANES_RELEASE_ROOTFS_FEED_BRANCH:-release-rootfs-smoke}"
WORK_DIR="${AIRPLANES_RELEASE_ROOTFS_WORK_DIR:-}"
KEEP_WORK_DIR="${AIRPLANES_RELEASE_ROOTFS_KEEP_WORK_DIR:-0}"

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
else
    mkdir -p "$WORK_DIR"
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
fi

IMAGE_FILE="$WORK_DIR/airplanes-image.img"
ROOT_MNT="$WORK_DIR/rootfs"
FEED_BOOT_DIR="$ROOT_MNT/boot"
BOOT_MNT="$ROOT_MNT/boot"
DOWNLOAD_DIR="$WORK_DIR/download"
FEED_SOURCE="$WORK_DIR/feed-source"
FEED_BARE="$WORK_DIR/feed.git"
MLAT_SOURCE="$WORK_DIR/mlat-source"
MLAT_BARE="$WORK_DIR/mlat.git"
READSB_SOURCE="$WORK_DIR/readsb-source"
READSB_BARE="$WORK_DIR/readsb.git"
STUB_DIR="$WORK_DIR/bin"
COMMAND_LOG="$WORK_DIR/commands.log"
CLAIM_LOG="$WORK_DIR/claim.log"
RUNTIME_ARG_LOG="$WORK_DIR/feed-runtime.args"

cleanup() {
    set +e
    if mountpoint -q "$BOOT_MNT"; then
        umount "$BOOT_MNT"
    fi
    if mountpoint -q "$ROOT_MNT"; then
        umount "$ROOT_MNT"
    fi
    if [[ "$KEEP_WORK_DIR" != "1" ]]; then
        rm -rf "$WORK_DIR"
    else
        echo "Keeping release rootfs smoke work dir: $WORK_DIR"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    if [[ -f "$COMMAND_LOG" ]]; then
        echo "--- command log ---" >&2
        cat "$COMMAND_LOG" >&2
    fi
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_commands() {
    local command
    for command in "$@"; do
        require_command "$command"
    done
}

find_single_image() {
    local dir="$1"
    local image
    image="$(find "$dir" -type f -name '*.img' -print | sort | head -n 1)"
    [[ -n "$image" ]] || fail "no .img file found in $dir"
    printf '%s\n' "$image"
}

extract_image() {
    local archive="$1"
    local extract_dir="$WORK_DIR/extracted"
    local image
    mkdir -p "$extract_dir"

    case "$archive" in
        *.img)
            cp --reflink=auto "$archive" "$IMAGE_FILE" 2>/dev/null || cp "$archive" "$IMAGE_FILE"
            ;;
        *.img.xz|*.xz)
            xz -dc "$archive" > "$IMAGE_FILE"
            ;;
        *.img.gz|*.gz)
            gzip -dc "$archive" > "$IMAGE_FILE"
            ;;
        *.zip)
            unzip -q "$archive" -d "$extract_dir"
            image="$(find_single_image "$extract_dir")"
            cp --reflink=auto "$image" "$IMAGE_FILE" 2>/dev/null || cp "$image" "$IMAGE_FILE"
            ;;
        *.7z)
            7z x "-o$extract_dir" "$archive"
            image="$(find_single_image "$extract_dir")"
            cp --reflink=auto "$image" "$IMAGE_FILE" 2>/dev/null || cp "$image" "$IMAGE_FILE"
            ;;
        *)
            fail "unsupported image archive: $archive"
            ;;
    esac

    [[ -s "$IMAGE_FILE" ]] || fail "extracted image is empty: $IMAGE_FILE"
    echo "Prepared image: $IMAGE_FILE"
    ls -lh "$IMAGE_FILE"
}

partition_values() {
    local part="$1"
    parted -ms "$IMAGE_FILE" unit B print \
        | awk -F: -v part="$part" '$1 == part { gsub(/B/, "", $2); gsub(/B/, "", $4); print $2, $4 }'
}

mount_partitions() {
    local boot_start boot_size root_start root_size configured_boot
    mkdir -p "$ROOT_MNT"
    read -r boot_start boot_size < <(partition_values 1)
    read -r root_start root_size < <(partition_values 2)
    [[ -n "${boot_start:-}" && -n "${root_start:-}" ]] || fail "could not read image partition table"

    mount -o "loop,offset=$root_start,sizelimit=$root_size,rw" "$IMAGE_FILE" "$ROOT_MNT"

    configured_boot="$(awk '$2 == "/boot" || $2 == "/boot/firmware" { print $2; exit }' "$ROOT_MNT/etc/fstab" 2>/dev/null || true)"
    if [[ -n "$configured_boot" ]]; then
        BOOT_MNT="$ROOT_MNT$configured_boot"
        mkdir -p "$BOOT_MNT"
        mount -o "loop,offset=$boot_start,sizelimit=$boot_size,rw" "$IMAGE_FILE" "$BOOT_MNT"
        echo "Mounted image boot partition at $configured_boot"
    else
        BOOT_MNT="$ROOT_MNT/boot"
        echo "Image fstab does not mount a boot partition; using rootfs /boot"
    fi
}

make_repo() {
    local source="$1"
    local branch="$2"
    local bare="$3"
    git -C "$source" init -q -b "$branch"
    git -C "$source" config user.email "release-rootfs-smoke@example.invalid"
    git -C "$source" config user.name "Release Rootfs Smoke"
    git -C "$source" add .
    git -C "$source" commit -q -m "release rootfs smoke fixture"
    git clone --quiet --bare "$source" "$bare"
}

make_feed_repo() {
    rm -rf "$FEED_SOURCE" "$FEED_BARE"
    mkdir -p "$FEED_SOURCE"
    rsync -a --delete --exclude .git "$FEED_DIR/" "$FEED_SOURCE/"
    make_repo "$FEED_SOURCE" "$FEED_BRANCH" "$FEED_BARE"
}

make_mlat_repo() {
    rm -rf "$MLAT_SOURCE" "$MLAT_BARE"
    mkdir -p "$MLAT_SOURCE"
    printf '%s\n' "mlat fixture" > "$MLAT_SOURCE/README"
    make_repo "$MLAT_SOURCE" master "$MLAT_BARE"
}

make_readsb_repo() {
    rm -rf "$READSB_SOURCE" "$READSB_BARE"
    mkdir -p "$READSB_SOURCE"
    printf '%s\n' "readsb fixture" > "$READSB_SOURCE/README"
    make_repo "$READSB_SOURCE" dev "$READSB_BARE"
}

write_stubs() {
    mkdir -p "$STUB_DIR"
    cat > "$STUB_DIR/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
    cat > "$STUB_DIR/id" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" && "${2:-}" == "airplanes-feed" ]]; then
    exit 0
fi
if [[ "${1:-}" == "-u" ]]; then
    printf '0\n'
    exit 0
fi
/usr/bin/id "$@"
SH
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${COMMAND_LOG:?}"
if [[ "${1:-}" == "is-enabled" ]]; then
    printf 'disabled\n'
fi
exit 0
SH
    cat > "$STUB_DIR/journalctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$STUB_DIR/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    cat > "$STUB_DIR/nc" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    cat > "$STUB_DIR/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$STUB_DIR/make" <<'SH'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >> "${COMMAND_LOG:?}"
if [[ "${1:-}" == "clean" ]]; then
    rm -f readsb viewadsb
    exit 0
fi
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > readsb
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > viewadsb
chmod +x readsb viewadsb
exit 0
SH
    cat > "$STUB_DIR/renice" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$STUB_DIR/adduser" <<'SH'
#!/usr/bin/env bash
printf 'adduser %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
    cat > "$STUB_DIR/useradd" <<'SH'
#!/usr/bin/env bash
printf 'useradd %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
    cat > "$STUB_DIR/apl-feed-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLAIM_LOG:?}"
exit 0
SH
    cat > "$STUB_DIR/feed-bin-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${AIRPLANES_RUNTIME_ARG_LOG:?}"
exit 0
SH
    chmod +x "$STUB_DIR"/*
}

set_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    if grep -q "^$key=" "$file"; then
        sed -i -e "s|^$key=.*|$key=\"$value\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$file"
    fi
}

list_boot_dir() {
    local label="$1"
    local path="$2"
    echo "Observed $label contents ($path):" >&2
    if [[ -d "$path" ]]; then
        find "$path" -maxdepth 2 -mindepth 1 -printf '%P\n' | sort | head -n 80 >&2 || true
    else
        echo "<missing>" >&2
    fi
}

require_feed_boot_file() {
    local name="$1"
    if [[ -f "$FEED_BOOT_DIR/$name" ]]; then
        return 0
    fi
    list_boot_dir "feed /boot" "$FEED_BOOT_DIR"
    if [[ "$BOOT_MNT" != "$FEED_BOOT_DIR" ]]; then
        list_boot_dir "mounted boot partition" "$BOOT_MNT"
    fi
    fail "release image lacks /boot/$name"
}

prepare_mounted_image() {
    local ipath mlat_version
    ipath="$ROOT_MNT/usr/local/share/airplanes"

    [[ -f "$ROOT_MNT/etc/systemd/system/airplanes-first-run.service" ]] \
        || fail "release image lacks airplanes-first-run.service"

    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        [[ -x "$ROOT_MNT/usr/bin/airplanes-feeder" ]] || fail "release image lacks /usr/bin/airplanes-feeder"
        require_feed_boot_file airplanes-config.txt
        require_feed_boot_file airplanes-env
        set_env_value "$FEED_BOOT_DIR/airplanes-config.txt" USER "image-release-rootfs-smoke"
        set_env_value "$FEED_BOOT_DIR/airplanes-config.txt" LATITUDE "52.52000"
        set_env_value "$FEED_BOOT_DIR/airplanes-config.txt" LONGITUDE "13.40500"
        set_env_value "$FEED_BOOT_DIR/airplanes-config.txt" ALTITUDE "35m"
        # Simulate airplanes-update's pre-feed-update migrator step.
        # Without this the strict guard in feed/update.sh fires on the
        # legacy USER= schema. The migration itself is unit-tested in
        # airplanes-webconfig and integration-tested in airplanes-update.
        set_env_value "$FEED_BOOT_DIR/airplanes-config.txt" MLAT_USER "image-release-rootfs-smoke"
        set_env_value "$FEED_BOOT_DIR/airplanes-config.txt" MLAT_ENABLED "true"
    else
        [[ -f "$ROOT_MNT/etc/airplanes/feed.env" ]] || fail "new image lacks /etc/airplanes/feed.env"
        rm -f "$ROOT_MNT/usr/bin/airplanes-feeder"
        set_env_value "$ROOT_MNT/etc/airplanes/feed.env" USER "image-release-rootfs-smoke"
        set_env_value "$ROOT_MNT/etc/airplanes/feed.env" LATITUDE "52.52000"
        set_env_value "$ROOT_MNT/etc/airplanes/feed.env" LONGITUDE "13.40500"
        set_env_value "$ROOT_MNT/etc/airplanes/feed.env" ALTITUDE "35m"
    fi

    mkdir -p "$ipath/venv/bin"
    cat > "$ipath/venv/bin/mlat-client" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$ipath/venv/bin/mlat-client"
    mlat_version="$(git --git-dir="$MLAT_BARE" rev-parse refs/heads/master)"
    printf '%s\n' "$mlat_version" > "$ipath/mlat_version"
}

run_update_against_image() {
    local -a build_mode_env
    build_mode_env=()
    if [[ "$IMAGE_CONTRACT" == "new" ]]; then
        build_mode_env=(AIRPLANES_BUILD_MODE=1)
    fi

    env \
        PATH="$STUB_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        COMMAND_LOG="$COMMAND_LOG" \
        CLAIM_LOG="$CLAIM_LOG" \
        AIRPLANES_ROOT="$ROOT_MNT" \
        AIRPLANES_SKIP_ROOT_CHECK=1 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        AIRPLANES_FEED_REPO="file://$FEED_BARE" \
        AIRPLANES_FEED_BRANCH="$FEED_BRANCH" \
        AIRPLANES_MLAT_REPO="file://$MLAT_BARE" \
        AIRPLANES_MLAT_BRANCH=master \
        AIRPLANES_READSB_REPO="file://$READSB_BARE" \
        AIRPLANES_READSB_BRANCH=dev \
        APL_FEED_BIN="$STUB_DIR/apl-feed-stub" \
        "${build_mode_env[@]}" \
        bash "$FEED_SOURCE/update.sh"
}

run_runtime_probe() {
    PATH="$STUB_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    AIRPLANES_ROOT="$ROOT_MNT" \
    AIRPLANES_FEED_BIN="$STUB_DIR/feed-bin-stub" \
    AIRPLANES_RUNTIME_ARG_LOG="$RUNTIME_ARG_LOG" \
        bash "$ROOT_MNT/usr/local/share/airplanes/airplanes-feed.sh"
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$file" || fail "$file does not contain $pattern"
}

assert_not_exists() {
    local path="$1"
    [[ ! -e "$path" ]] || fail "unexpected path exists: $path"
}

assert_valid_uuid_file() {
    local path="$1"
    local raw uuid
    [[ -f "$path" ]] || fail "missing UUID file: $path"
    raw="$(tr -d '\n\r{}' < "$path")"
    uuid="$(printf '%s' "$raw" | tr 'A-F' 'a-f')"
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid UUID in $path: $raw"
}

assert_symlink_target() {
    local path="$1"
    local target="$2"
    [[ -L "$path" ]] || fail "$path is not a symlink"
    [[ "$(readlink "$path")" == "$target" ]] || fail "$path does not point at $target"
}

assert_updated_image_contracts() {
    local ipath="$ROOT_MNT/usr/local/share/airplanes"

    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        [[ -f "$FEED_BOOT_DIR/airplanes-config.txt" ]] || fail "missing boot config"
        [[ -f "$FEED_BOOT_DIR/airplanes-env" ]] || fail "missing boot env"
        assert_valid_uuid_file "$ROOT_MNT/etc/airplanes/feeder-id"
        assert_symlink_target "$ipath/airplanes-uuid" '../../../../etc/airplanes/feeder-id'
    else
        [[ -f "$ROOT_MNT/etc/airplanes/feed.env" ]] || fail "missing canonical feed.env"
        [[ -f "$ROOT_MNT/etc/airplanes/image-install" ]] || fail "missing image-install marker"
        assert_not_exists "$ROOT_MNT/etc/airplanes/feeder-id"
        assert_not_exists "$ipath/airplanes-uuid"
    fi
    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        [[ -x "$ROOT_MNT/usr/bin/airplanes-feeder" ]] || fail "missing image feed binary"
        [[ ! -e "$ipath/feed-airplanes" ]] || fail "legacy image should use image feed binary"
    else
        [[ ! -e "$ROOT_MNT/usr/bin/airplanes-feeder" ]] || fail "new image should not require /usr/bin/airplanes-feeder"
        [[ -x "$ipath/feed-airplanes" ]] || fail "missing build-mode feed binary"
    fi
    [[ -x "$ROOT_MNT/usr/local/bin/apl-feed" ]] || fail "missing apl-feed command"
    [[ -f "$ipath/update.sh" ]] || fail "missing installed update.sh"
    [[ -f "$ipath/airplanes-feed.sh" ]] || fail "missing airplanes-feed.sh"
    [[ -f "$ipath/airplanes-mlat.sh" ]] || fail "missing airplanes-mlat.sh"
    [[ -f "$ipath/apl-feed/common.sh" ]] || fail "missing apl-feed common.sh"
    [[ -f "$ROOT_MNT/etc/systemd/system/airplanes-feed.service" ]] || fail "missing feed service"
    [[ -f "$ROOT_MNT/etc/systemd/system/airplanes-mlat.service" ]] || fail "missing mlat service"
    [[ -f "$ROOT_MNT/etc/systemd/system/airplanes-first-run.service" ]] || fail "missing first-run service"
    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        assert_not_exists "$ROOT_MNT/etc/airplanes/feed.env"
        [[ -L "$ROOT_MNT/etc/default/airplanes" ]] || fail "/etc/default/airplanes is not a symlink"
        [[ "$(readlink "$ROOT_MNT/etc/default/airplanes")" == "/boot/airplanes-config.txt" ]] \
            || fail "/etc/default/airplanes does not point at /boot/airplanes-config.txt"
    fi

    assert_contains "$ROOT_MNT/etc/systemd/system/airplanes-feed.service" 'ExecStart=/usr/local/share/airplanes/airplanes-feed.sh'
    grep -qE '^After=.*airplanes-first-run.service' "$ROOT_MNT/etc/systemd/system/airplanes-feed.service" \
        || fail "airplanes-feed.service missing After=airplanes-first-run.service"
    assert_contains "$ROOT_MNT/etc/systemd/system/airplanes-feed.service" 'User=airplanes-feed'
    assert_contains "$ROOT_MNT/etc/systemd/system/airplanes-mlat.service" 'ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh'
    grep -qE '^After=.*airplanes-first-run.service' "$ROOT_MNT/etc/systemd/system/airplanes-mlat.service" \
        || fail "airplanes-mlat.service missing After=airplanes-first-run.service"
    assert_contains "$ROOT_MNT/etc/systemd/system/airplanes-mlat.service" 'User=airplanes-feed'
    assert_contains "$ipath/airplanes-feed.sh" 'feed2.airplanes.live,64004'
    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        assert_contains "$CLAIM_LOG" 'claim register'
        assert_contains "$COMMAND_LOG" 'systemctl restart airplanes-feed'
        assert_contains "$COMMAND_LOG" 'systemctl restart airplanes-mlat'
        [[ "$(grep -c 'systemctl daemon-reload' "$COMMAND_LOG")" == "1" ]] \
            || fail "expected one systemctl daemon-reload call"
    else
        assert_not_exists "$CLAIM_LOG"
        assert_contains "$COMMAND_LOG" 'systemctl enable airplanes-feed'
        assert_contains "$COMMAND_LOG" 'systemctl enable airplanes-mlat'
        ! grep -q 'systemctl restart' "$COMMAND_LOG" || fail "build mode restarted a service"
        ! grep -q 'systemctl is-active' "$COMMAND_LOG" || fail "build mode checked live systemd state"
        ! grep -q 'systemctl daemon-reload' "$COMMAND_LOG" || fail "build mode reloaded live systemd"
    fi
}

assert_runtime_args() {
    assert_contains "$RUNTIME_ARG_LOG" '--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004'
    assert_contains "$RUNTIME_ARG_LOG" '--net-ro-interval 0.2'
    assert_contains "$RUNTIME_ARG_LOG" '--db-file=none'
    assert_contains "$RUNTIME_ARG_LOG" '--max-range 450'
    if grep -q -- '--net-bi-port 30004,30104' "$RUNTIME_ARG_LOG"; then
        fail "decoder NET_OPTIONS leaked into feed runtime args"
    fi
}

main() {
    local image_archive rc
    require_commands curl jq git rsync parted awk mount umount find cp tee unzip xz gzip gh
    if [[ -n "${AIRPLANES_IMAGE_PATH:-}" ]]; then
        image_archive="$AIRPLANES_IMAGE_PATH"
        [[ -f "$image_archive" ]] || fail "AIRPLANES_IMAGE_PATH does not exist: $image_archive"
    else
        # The library writes the resolved path to stdout. Capture under a
        # temporarily-relaxed errexit so the 64 sentinel (tier exhaustion)
        # can be handled as a skip rather than a hard failure.
        mkdir -p "$DOWNLOAD_DIR"
        rc=0
        set +e
        image_archive="$(image_source_resolve \
            "$IMAGE_RELEASE_REPO" "$IMAGE_CONTRACT" "$IMAGE_CHANNEL" "$IMAGE_ARCH" \
            "$AIRPLANES_IMAGE_SOURCE_TIERS" "$DOWNLOAD_DIR" "${AIRPLANES_IMAGE_ASSET_REGEX:-}")"
        rc=$?
        set -e
        case "$rc" in
            0) ;;
            64)
                echo "::notice::no asset available in tiers [$AIRPLANES_IMAGE_SOURCE_TIERS] for $IMAGE_RELEASE_REPO ($IMAGE_CONTRACT/$IMAGE_CHANNEL/$IMAGE_ARCH); skipping smoke"
                exit 0
                ;;
            *)
                fail "image source resolution failed with rc=$rc"
                ;;
        esac
    fi

    echo "Work dir: $WORK_DIR"
    df -h .
    extract_image "$image_archive"
    make_feed_repo
    make_mlat_repo
    make_readsb_repo
    write_stubs

    mount_partitions
    prepare_mounted_image
    run_update_against_image
    assert_updated_image_contracts
    run_runtime_probe
    assert_runtime_args

    echo "image release rootfs smoke passed"
}

main "$@"
