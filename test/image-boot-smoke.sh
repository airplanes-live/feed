#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash "$0" "$@"
fi

FEED_DIR="${AIRPLANES_FEED_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
IMAGE_RELEASE_REPO="${AIRPLANES_IMAGE_RELEASE_REPO:-airplanes-live/image-releases}"
IMAGE_ASSET_REGEX="${AIRPLANES_IMAGE_ASSET_REGEX:-(?i)\\.(img|img\\.xz|img\\.gz|zip|7z)$}"
FEED_BRANCH="${AIRPLANES_BOOT_SMOKE_FEED_BRANCH:-boot-smoke}"
QEMU_TIMEOUT="${AIRPLANES_BOOT_SMOKE_QEMU_TIMEOUT:-12m}"
MAX_BOOT_ATTEMPTS="${AIRPLANES_BOOT_SMOKE_MAX_BOOT_ATTEMPTS:-4}"
WORK_DIR="${AIRPLANES_BOOT_SMOKE_WORK_DIR:-}"
KEEP_WORK_DIR="${AIRPLANES_BOOT_SMOKE_KEEP_WORK_DIR:-0}"

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
else
    mkdir -p "$WORK_DIR"
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
fi

IMAGE_FILE="$WORK_DIR/airplanes-image.img"
ROOT_MNT="$WORK_DIR/rootfs"
BOOT_MNT="$WORK_DIR/bootfs"
BOOT_FILES="$WORK_DIR/boot-files"
DOWNLOAD_DIR="$WORK_DIR/download"
FEED_SOURCE="$WORK_DIR/feed-source"
FEED_BARE="$WORK_DIR/feed.git"
MLAT_SOURCE="$WORK_DIR/mlat-source"
MLAT_BARE="$WORK_DIR/mlat.git"

cleanup() {
    set +e
    if mountpoint -q "$ROOT_MNT"; then
        umount "$ROOT_MNT"
    fi
    if mountpoint -q "$BOOT_MNT"; then
        umount "$BOOT_MNT"
    fi
    if [[ "$KEEP_WORK_DIR" != "1" ]]; then
        rm -rf "$WORK_DIR"
    else
        echo "Keeping boot smoke work dir: $WORK_DIR"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    if [[ -d "$WORK_DIR/qemu-logs" ]]; then
        find "$WORK_DIR/qemu-logs" -maxdepth 1 -type f -print -exec tail -n 120 {} \; >&2 || true
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

github_api() {
    local url="$1"
    local -a headers
    headers=(-H "Accept: application/vnd.github+json")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(
            -H "Authorization: Bearer $GITHUB_TOKEN"
            -H "X-GitHub-Api-Version: 2022-11-28"
        )
    fi
    curl --fail --location --silent --show-error "${headers[@]}" "$url"
}

download_latest_release_image() {
    local release_json asset_name asset_url output
    mkdir -p "$DOWNLOAD_DIR"
    release_json="$DOWNLOAD_DIR/latest-release.json"

    echo "Fetching latest image release from $IMAGE_RELEASE_REPO" >&2
    github_api "https://api.github.com/repos/$IMAGE_RELEASE_REPO/releases/latest" > "$release_json"

    asset_name="$(jq -r --arg re "$IMAGE_ASSET_REGEX" '
        [.assets[] | select(.name | test($re))] as $matches
        | (($matches | map(select(.name | test("qemu"; "i"))) | first) // ($matches | first) // empty)
        | .name // empty
    ' "$release_json")"
    asset_url="$(jq -r --arg name "$asset_name" '
        .assets[] | select(.name == $name) | .browser_download_url
    ' "$release_json")"

    [[ -n "$asset_name" && -n "$asset_url" ]] || {
        jq -r '.assets[].name' "$release_json" >&2
        fail "no release asset in $IMAGE_RELEASE_REPO matched $IMAGE_ASSET_REGEX"
    }

    output="$DOWNLOAD_DIR/$asset_name"
    echo "Downloading image asset: $asset_name" >&2
    curl --fail --location --show-error --output "$output" "$asset_url"
    printf '%s\n' "$output"
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
            cp --reflink=auto "$(find_single_image "$extract_dir")" "$IMAGE_FILE" 2>/dev/null \
                || cp "$(find_single_image "$extract_dir")" "$IMAGE_FILE"
            ;;
        *.7z)
            7z x "-o$extract_dir" "$archive"
            cp --reflink=auto "$(find_single_image "$extract_dir")" "$IMAGE_FILE" 2>/dev/null \
                || cp "$(find_single_image "$extract_dir")" "$IMAGE_FILE"
            ;;
        *)
            fail "unsupported image archive: $archive"
            ;;
    esac

    [[ -s "$IMAGE_FILE" ]] || fail "extracted image is empty: $IMAGE_FILE"
    echo "Prepared image: $IMAGE_FILE"
    ls -lh "$IMAGE_FILE"
}

resize_image_for_qemu_sd() {
    local size target
    size="$(stat -c '%s' "$IMAGE_FILE")"
    target=1
    while ((target < size)); do
        target=$((target * 2))
    done
    if ((target != size)); then
        echo "Padding image to QEMU SD power-of-two size: $target bytes"
        truncate -s "$target" "$IMAGE_FILE"
        ls -lh "$IMAGE_FILE"
    fi
}

partition_values() {
    local part="$1"
    parted -ms "$IMAGE_FILE" unit B print \
        | awk -F: -v part="$part" '$1 == part { gsub(/B/, "", $2); gsub(/B/, "", $4); print $2, $4 }'
}

mount_partitions() {
    local boot_start boot_size root_start root_size
    mkdir -p "$ROOT_MNT" "$BOOT_MNT"
    read -r boot_start boot_size < <(partition_values 1)
    read -r root_start root_size < <(partition_values 2)
    [[ -n "${boot_start:-}" && -n "${root_start:-}" ]] || fail "could not read image partition table"

    mount -o "loop,offset=$boot_start,sizelimit=$boot_size,rw" "$IMAGE_FILE" "$BOOT_MNT"
    mount -o "loop,offset=$root_start,sizelimit=$root_size,rw" "$IMAGE_FILE" "$ROOT_MNT"
}

unmount_partitions() {
    sync
    if mountpoint -q "$ROOT_MNT"; then
        umount "$ROOT_MNT"
    fi
    if mountpoint -q "$BOOT_MNT"; then
        umount "$BOOT_MNT"
    fi
}

make_feed_repo() {
    rm -rf "$FEED_SOURCE" "$FEED_BARE"
    mkdir -p "$FEED_SOURCE"
    rsync -a --delete --exclude .git "$FEED_DIR/" "$FEED_SOURCE/"
    git -C "$FEED_SOURCE" init -q -b "$FEED_BRANCH"
    git -C "$FEED_SOURCE" config user.email "boot-smoke@example.invalid"
    git -C "$FEED_SOURCE" config user.name "Image Boot Smoke"
    git -C "$FEED_SOURCE" add .
    git -C "$FEED_SOURCE" commit -q -m "boot smoke feed fixture"
    git clone --quiet --bare "$FEED_SOURCE" "$FEED_BARE"
}

make_mlat_repo() {
    rm -rf "$MLAT_SOURCE" "$MLAT_BARE"
    mkdir -p "$MLAT_SOURCE"
    git -C "$MLAT_SOURCE" init -q -b master
    git -C "$MLAT_SOURCE" config user.email "boot-smoke@example.invalid"
    git -C "$MLAT_SOURCE" config user.name "Image Boot Smoke"
    printf '%s\n' "mlat fixture" > "$MLAT_SOURCE/README"
    git -C "$MLAT_SOURCE" add README
    git -C "$MLAT_SOURCE" commit -q -m "mlat fixture"
    git clone --quiet --bare "$MLAT_SOURCE" "$MLAT_BARE"
}

copy_boot_file() {
    local name="$1"
    [[ -f "$BOOT_MNT/$name" ]] || fail "boot file missing: $name"
    cp "$BOOT_MNT/$name" "$BOOT_FILES/$name"
}

prepare_boot_files() {
    local kernel dtb cmdline
    mkdir -p "$BOOT_FILES"

    if [[ -f "$BOOT_MNT/kernel7.img" ]]; then
        kernel="kernel7.img"
        dtb="bcm2709-rpi-2-b.dtb"
    elif [[ -f "$BOOT_MNT/kernel7l.img" ]]; then
        kernel="kernel7l.img"
        dtb="bcm2711-rpi-4-b.dtb"
    elif [[ -f "$BOOT_MNT/kernel8.img" ]]; then
        kernel="kernel8.img"
        dtb="bcm2710-rpi-3-b.dtb"
    else
        fail "no supported Raspberry Pi kernel found in boot partition"
    fi

    copy_boot_file "$kernel"
    copy_boot_file "$dtb"

    cmdline="$(tr -d '\n' < "$BOOT_MNT/cmdline.txt")"
    cmdline="${cmdline//console=serial0,115200/console=ttyAMA0,115200}"
    cmdline="${cmdline//console=serial0/console=ttyAMA0,115200}"
    cmdline="$(printf '%s\n' "$cmdline" \
        | sed -E 's/(^| )init=[^ ]+//g; s/(^| )quiet( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
    printf '%s systemd.unit=multi-user.target systemd.show_status=1\n' "$cmdline" > "$BOOT_FILES/cmdline.txt"
    printf '%s\n' "$kernel" > "$BOOT_FILES/kernel-name"
    printf '%s\n' "$dtb" > "$BOOT_FILES/dtb-name"
}

write_guest_probe() {
    install -d -m 0755 "$ROOT_MNT/opt/airplanes-boot-smoke"
    install -d -m 0755 "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
    rsync -a --delete "$FEED_SOURCE/" "$ROOT_MNT/opt/airplanes-boot-smoke/feed-worktree/"
    rsync -a --delete "$FEED_BARE/" "$ROOT_MNT/opt/airplanes-boot-smoke/feed.git/"
    rsync -a --delete "$MLAT_BARE/" "$ROOT_MNT/opt/airplanes-boot-smoke/mlat.git/"

    cat > "$ROOT_MNT/opt/airplanes-boot-smoke/apl-feed-stub" <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/lib/airplanes-boot-smoke
printf 'apl-feed %s\n' "$*" >> /var/lib/airplanes-boot-smoke/apl-feed.log
exit 0
GUEST
    chmod 0755 "$ROOT_MNT/opt/airplanes-boot-smoke/apl-feed-stub"

    cat > "$ROOT_MNT/opt/airplanes-boot-smoke/run.sh" <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/var/lib/airplanes-boot-smoke
mkdir -p "$STATE_DIR"
exec > >(tee -a "$STATE_DIR/run.log" /dev/console) 2>&1

fail() {
    echo "FAIL: $*" >&2
    printf '%s\n' "$*" > "$STATE_DIR/failure"
    sync
    systemctl poweroff
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

assert_exec() {
    [[ -x "$1" ]] || fail "missing executable: $1"
}

assert_contains() {
    grep -q -- "$2" "$1" || fail "$1 does not contain $2"
}

assert_not_exists() {
    [[ ! -e "$1" ]] || fail "unexpected path exists: $1"
}

assert_image_contracts() {
    assert_file /boot/airplanes-config.txt
    assert_file /boot/airplanes-env
    assert_file /boot/airplanes-uuid
    assert_exec /usr/bin/airplanes-feeder
    assert_exec /usr/local/bin/apl-feed
    assert_file /usr/local/share/airplanes/update.sh
    assert_file /usr/local/share/airplanes/airplanes-feed.sh
    assert_file /usr/local/share/airplanes/airplanes-mlat.sh
    assert_file /usr/local/share/airplanes/apl-feed/common.sh
    assert_file /etc/systemd/system/airplanes-feed.service
    assert_file /etc/systemd/system/airplanes-mlat.service
    assert_file /etc/systemd/system/airplanes-first-run.service
    assert_contains /etc/systemd/system/airplanes-feed.service 'EnvironmentFile=/boot/airplanes-config.txt'
    assert_contains /etc/systemd/system/airplanes-feed.service 'ExecStart=/usr/local/share/airplanes/airplanes-feed.sh'
    assert_contains /etc/systemd/system/airplanes-feed.service 'After=airplanes-first-run.service'
    assert_contains /etc/systemd/system/airplanes-mlat.service 'EnvironmentFile=/boot/airplanes-config.txt'
    assert_contains /etc/systemd/system/airplanes-mlat.service 'ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh'
    assert_contains /etc/systemd/system/airplanes-mlat.service 'After=airplanes-first-run.service'
    assert_contains /usr/local/share/airplanes/airplanes-feed.sh 'feed2.airplanes.live,64004'
    assert_not_exists /etc/airplanes/feed.env
    [[ -L /etc/default/airplanes ]] || fail "/etc/default/airplanes is not a symlink"
    [[ "$(readlink /etc/default/airplanes)" == "/boot/airplanes-config.txt" ]] \
        || fail "/etc/default/airplanes does not point at /boot/airplanes-config.txt"
}

prepare_mlat_fixture() {
    local mlat_version
    install -d -m 0755 /usr/local/share/airplanes/venv/bin
    if [[ ! -x /usr/local/share/airplanes/venv/bin/mlat-client ]]; then
        cat > /usr/local/share/airplanes/venv/bin/mlat-client <<'SH'
#!/usr/bin/env bash
sleep 3600
SH
        chmod 0755 /usr/local/share/airplanes/venv/bin/mlat-client
    fi
    mlat_version="$(git --git-dir=/opt/airplanes-boot-smoke/mlat.git rev-parse refs/heads/master)"
    printf '%s\n' "$mlat_version" > /usr/local/share/airplanes/mlat_version
}

run_feed_update() {
    prepare_mlat_fixture
    APL_FEED_BIN=/opt/airplanes-boot-smoke/apl-feed-stub \
    APL_FEED_MAX_RETRY_TIME=1 \
    AIRPLANES_PACKAGE_MANAGER=none \
    AIRPLANES_FEED_REPO=file:///opt/airplanes-boot-smoke/feed.git \
    AIRPLANES_FEED_BRANCH=boot-smoke \
    AIRPLANES_MLAT_REPO=file:///opt/airplanes-boot-smoke/mlat.git \
    AIRPLANES_MLAT_BRANCH=master \
        bash /opt/airplanes-boot-smoke/feed-worktree/update.sh
}

phase="$(cat "$STATE_DIR/phase" 2>/dev/null || true)"
case "$phase" in
    '')
        echo "airplanes image boot smoke: initial update phase"
        run_feed_update
        assert_image_contracts
        systemctl is-active --quiet airplanes-feed.service \
            || fail "airplanes-feed.service is not active after update"
        printf '%s\n' updated > "$STATE_DIR/phase"
        sync
        systemctl reboot
        ;;
    updated)
        echo "airplanes image boot smoke: post-reboot verification phase"
        assert_image_contracts
        systemctl is-active --quiet airplanes-feed.service \
            || fail "airplanes-feed.service is not active after reboot"
        printf '%s\n' success > "$STATE_DIR/result"
        sync
        systemctl poweroff
        ;;
    *)
        fail "unknown boot smoke phase: $phase"
        ;;
esac
GUEST
    chmod 0755 "$ROOT_MNT/opt/airplanes-boot-smoke/run.sh"

    cat > "$ROOT_MNT/etc/systemd/system/airplanes-boot-smoke.service" <<'UNIT'
[Unit]
Description=airplanes.live image boot smoke
After=airplanes-first-run.service

[Service]
Type=oneshot
TimeoutStartSec=35min
ExecStart=/opt/airplanes-boot-smoke/run.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
    ln -sfn ../airplanes-boot-smoke.service \
        "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/airplanes-boot-smoke.service"
}

qemu_command() {
    local kernel dtb cmdline qemu_bin machine
    kernel="$(cat "$BOOT_FILES/kernel-name")"
    dtb="$(cat "$BOOT_FILES/dtb-name")"
    cmdline="$(cat "$BOOT_FILES/cmdline.txt")"

    if [[ "$kernel" == "kernel8.img" ]]; then
        qemu_bin="qemu-system-aarch64"
        machine="raspi3b"
    else
        qemu_bin="qemu-system-arm"
        machine="raspi2b"
    fi

    require_command "$qemu_bin"
    printf '%q ' \
        "$qemu_bin" \
        -M "$machine" \
        -m 1G \
        -kernel "$BOOT_FILES/$kernel" \
        -dtb "$BOOT_FILES/$dtb" \
        -append "$cmdline" \
        -drive "file=$IMAGE_FILE,format=raw,if=sd" \
        -netdev user,id=net0 \
        -device usb-net,netdev=net0 \
        -serial mon:stdio \
        -display none \
        -no-reboot
}

run_one_boot() {
    local attempt="$1"
    local log="$WORK_DIR/qemu-logs/boot-$attempt.log"
    local qemu_line rc
    mkdir -p "$WORK_DIR/qemu-logs"
    qemu_line="$(qemu_command)"
    echo "QEMU boot attempt $attempt"
    echo "$qemu_line"
    set +e
    timeout --foreground "$QEMU_TIMEOUT" bash -c "$qemu_line" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$rc" == "124" ]]; then
        fail "QEMU boot attempt $attempt timed out after $QEMU_TIMEOUT"
    fi
    if [[ "$rc" != "0" ]]; then
        echo "QEMU boot attempt $attempt exited with rc=$rc; inspecting guest state"
    fi
}

guest_state_value() {
    local path="$1"
    if [[ -f "$ROOT_MNT/$path" ]]; then
        cat "$ROOT_MNT/$path"
    fi
}

inspect_guest_state() {
    local failure result phase
    mount_partitions
    failure="$(guest_state_value var/lib/airplanes-boot-smoke/failure)"
    result="$(guest_state_value var/lib/airplanes-boot-smoke/result)"
    phase="$(guest_state_value var/lib/airplanes-boot-smoke/phase)"
    if [[ -f "$ROOT_MNT/var/lib/airplanes-boot-smoke/run.log" ]]; then
        cp "$ROOT_MNT/var/lib/airplanes-boot-smoke/run.log" "$WORK_DIR/qemu-logs/guest-run.log" || true
    fi
    unmount_partitions

    if [[ -n "$failure" ]]; then
        fail "guest smoke failed: $failure"
    fi
    if [[ "$result" == "success" ]]; then
        return 0
    fi
    echo "Guest smoke incomplete after boot: phase=${phase:-<unset>}"
    return 1
}

run_boot_smoke() {
    local attempt
    for ((attempt = 1; attempt <= MAX_BOOT_ATTEMPTS; attempt++)); do
        run_one_boot "$attempt"
        if inspect_guest_state; then
            echo "image boot smoke passed"
            return 0
        fi
    done
    fail "guest smoke did not finish after $MAX_BOOT_ATTEMPTS boot attempts"
}

main() {
    local image_archive
    require_commands curl jq git rsync parted awk mount umount find cp tee timeout
    require_commands unzip xz gzip
    if [[ -n "${AIRPLANES_IMAGE_PATH:-}" ]]; then
        image_archive="$AIRPLANES_IMAGE_PATH"
        [[ -f "$image_archive" ]] || fail "AIRPLANES_IMAGE_PATH does not exist: $image_archive"
    else
        image_archive="$(download_latest_release_image)"
    fi

    echo "Work dir: $WORK_DIR"
    df -h .
    extract_image "$image_archive"
    resize_image_for_qemu_sd
    make_feed_repo
    make_mlat_repo

    mount_partitions
    prepare_boot_files
    write_guest_probe
    unmount_partitions

    run_boot_smoke
}

main "$@"
