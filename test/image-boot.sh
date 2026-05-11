#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash "$0" "$@"
fi

FEED_DIR="${AIRPLANES_FEED_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
IMAGE_RELEASE_REPO="${AIRPLANES_IMAGE_RELEASE_REPO:-airplanes-live/image}"
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
# Asset selection (regex + strict-mode) is owned by lib/image-source.sh and
# derived from CONTRACT/CHANNEL/ARCH. AIRPLANES_IMAGE_ASSET_REGEX is kept as
# a manual override; AIRPLANES_IMAGE_SOURCE_TIERS picks the tier order.
AIRPLANES_IMAGE_SOURCE_TIERS="${AIRPLANES_IMAGE_SOURCE_TIERS:-release-any}"
# shellcheck source=lib/image-source.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/image-source.sh"

FEED_BRANCH="${AIRPLANES_BOOT_SMOKE_FEED_BRANCH:-boot-smoke}"
QEMU_TIMEOUT="${AIRPLANES_BOOT_SMOKE_QEMU_TIMEOUT:-8m}"
MAX_BOOT_ATTEMPTS="${AIRPLANES_BOOT_SMOKE_MAX_BOOT_ATTEMPTS:-2}"
QEMU_MACHINE_MODE="${AIRPLANES_BOOT_SMOKE_QEMU_MACHINE:-auto}"
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
READSB_SOURCE="$WORK_DIR/readsb-source"
READSB_BARE="$WORK_DIR/readsb.git"

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

cmdline_set_arg() {
    local cmdline="$1"
    local key="$2"
    local value="$3"
    local arg found
    local -a args output
    read -r -a args <<< "$cmdline"
    found=0
    output=()
    for arg in "${args[@]}"; do
        if [[ "$arg" == "$key="* ]]; then
            output+=("$key=$value")
            found=1
        else
            output+=("$arg")
        fi
    done
    if [[ "$found" == "0" ]]; then
        output+=("$key=$value")
    fi
    printf '%s\n' "${output[*]}"
}

cmdline_add_flag() {
    local cmdline="$1"
    local flag="$2"
    local arg
    for arg in $cmdline; do
        if [[ "$arg" == "$flag" ]]; then
            printf '%s\n' "$cmdline"
            return 0
        fi
    done
    printf '%s %s\n' "$cmdline" "$flag"
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

partition_uuid() {
    local part="$1"
    local disk_id uuid
    if uuid="$(sfdisk --part-uuid "$IMAGE_FILE" "$part" 2>/dev/null)" && [[ -n "$uuid" ]]; then
        printf '%s\n' "$uuid"
        return 0
    fi
    if disk_id="$(sfdisk --disk-id "$IMAGE_FILE" 2>/dev/null)" && [[ "$disk_id" == 0x* ]]; then
        disk_id="${disk_id#0x}"
        printf '%s-%02x\n' "${disk_id,,}" "$part"
        return 0
    fi
    return 1
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

make_readsb_repo() {
    rm -rf "$READSB_SOURCE" "$READSB_BARE"
    mkdir -p "$READSB_SOURCE"
    git -C "$READSB_SOURCE" init -q -b dev
    git -C "$READSB_SOURCE" config user.email "boot-smoke@example.invalid"
    git -C "$READSB_SOURCE" config user.name "Image Boot Smoke"
    printf '%s\n' "readsb fixture" > "$READSB_SOURCE/README"
    git -C "$READSB_SOURCE" add README
    git -C "$READSB_SOURCE" commit -q -m "readsb fixture"
    git clone --quiet --bare "$READSB_SOURCE" "$READSB_BARE"
}

copy_boot_file() {
    local name="$1"
    [[ -f "$BOOT_MNT/$name" ]] || fail "boot file missing: $name"
    cp "$BOOT_MNT/$name" "$BOOT_FILES/$name"
}

copy_optional_boot_file() {
    local name="$1"
    if [[ -f "$BOOT_MNT/$name" ]]; then
        cp "$BOOT_MNT/$name" "$BOOT_FILES/$name"
        return 0
    fi
    return 1
}

prepare_qemu_kernel() {
    local source="$1"
    local qemu_kernel="$source"
    copy_boot_file "$source"

    if file -b "$BOOT_FILES/$source" | grep -qi 'gzip compressed'; then
        qemu_kernel="${source%.img}.uncompressed.img"
        gzip -dc "$BOOT_FILES/$source" > "$BOOT_FILES/$qemu_kernel"
        echo "Prepared uncompressed QEMU kernel: $qemu_kernel" >&2
    fi

    printf '%s\n' "$qemu_kernel"
}

kernel_version_from_image() {
    local kernel_path="$1"
    local versions
    versions="$(strings "$kernel_path" | sed -nE 's/^Linux version ([^[:space:]]+).*/\1/p')"
    printf '%s\n' "$versions" | sed -n '1p'
}

modprobe_dep_file() {
    local module="$1"
    printf '%s\n' "$WORK_DIR/modprobe-deps-$module.$$"
}

modprobe_err_file() {
    local module="$1"
    printf '%s\n' "$WORK_DIR/modprobe-err-$module.$$"
}

kernel_module_version() {
    local kernel="$1"
    local qemu_kernel="$2"
    local version module_dirs candidates

    if version="$(kernel_version_from_image "$BOOT_FILES/$qemu_kernel")" \
        && [[ -d "$ROOT_MNT/lib/modules/$version" ]]; then
        printf '%s\n' "$version"
        return 0
    fi

    module_dirs="$(find "$ROOT_MNT/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V)"
    case "$kernel" in
        kernel8.img)
            candidates="$(printf '%s\n' "$module_dirs" | grep -E '(^|-)rpi-v8$|v8$' || true)"
            ;;
        kernel7l.img)
            candidates="$(printf '%s\n' "$module_dirs" | grep -E '(^|-)rpi-v7l$|v7l$' || true)"
            ;;
        kernel7.img)
            candidates="$(printf '%s\n' "$module_dirs" | grep -E '(^|-)rpi-v7$|v7$' || true)"
            ;;
        *)
            candidates="$module_dirs"
            ;;
    esac

    version="$(printf '%s\n' "$candidates" | sed '/^$/d' | tail -n1)"
    if [[ -n "$version" && -d "$ROOT_MNT/lib/modules/$version" ]]; then
        printf '%s\n' "$version"
        return 0
    fi

    echo "Observed module directories:" >&2
    printf '%s\n' "$module_dirs" >&2
    fail "could not map $kernel to a /lib/modules version"
}

copy_module_dependency() {
    local initrd_root="$1"
    local source_path="$2"
    local source_file rel_path

    if [[ "$source_path" == "$ROOT_MNT/"* ]]; then
        source_file="$source_path"
        rel_path="${source_path#"$ROOT_MNT/"}"
    else
        rel_path="${source_path#/}"
        source_file="$ROOT_MNT/$rel_path"
    fi

    [[ -f "$source_file" ]] || fail "module dependency missing from rootfs: $source_path"
    mkdir -p "$initrd_root/$(dirname "$rel_path")"
    cp -a "$source_file" "$initrd_root/$rel_path"
}

copy_module_with_dependencies() {
    local initrd_root="$1"
    local kernel_version="$2"
    local module="$3"
    local line source_path rc dep_file err_file

    dep_file="$(modprobe_dep_file "$module")"
    err_file="$(modprobe_err_file "$module")"
    rm -f "$dep_file" "$err_file"

    if modprobe -D -d "$ROOT_MNT" -S "$kernel_version" "$module" >"$dep_file" 2>"$err_file"; then
        rc=0
    else
        rc=$?
    fi

    if [[ "$rc" != "0" ]]; then
        if grep -qE "(^|/)$module\\.ko(\\.xz|\\.zst|\\.gz)?$|^kernel/.*/$module\\.ko" \
            "$ROOT_MNT/lib/modules/$kernel_version/modules.builtin" 2>/dev/null; then
            rm -f "$dep_file" "$err_file"
            return 0
        fi
        cat "$err_file" >&2 || true
        rm -f "$dep_file" "$err_file"
        fail "rootfs kernel $kernel_version does not provide module: $module"
    fi

    while IFS= read -r line; do
        [[ "$line" == insmod\ * ]] || continue
        source_path="${line#insmod }"
        source_path="${source_path%%[[:space:]]*}"
        copy_module_dependency "$initrd_root" "$source_path"
    done < "$dep_file"
    rm -f "$dep_file" "$err_file"
}

prepare_virt_initrd() {
    local initrd="$1"
    local kernel="$2"
    local qemu_kernel="$3"
    local kernel_version initrd_work initrd_root out module part
    local -a required_modules

    kernel_version="$(kernel_module_version "$kernel" "$qemu_kernel")"
    initrd_work="$WORK_DIR/initramfs-qemu"
    initrd_root="$initrd_work/root"
    out="qemu-$initrd"
    rm -rf "$initrd_work"
    mkdir -p "$initrd_root"

    unmkinitramfs "$BOOT_FILES/$initrd" "$initrd_work/unpacked" >/dev/null
    if [[ -d "$initrd_work/unpacked/main" ]]; then
        for part in early early2 main; do
            [[ -d "$initrd_work/unpacked/$part" ]] || continue
            cp -a "$initrd_work/unpacked/$part/." "$initrd_root/"
        done
    else
        cp -a "$initrd_work/unpacked/." "$initrd_root/"
    fi

    mkdir -p "$initrd_root/lib/modules/$kernel_version"
    find "$ROOT_MNT/lib/modules/$kernel_version" -maxdepth 1 -type f -name 'modules.*' \
        -exec cp -a {} "$initrd_root/lib/modules/$kernel_version/" \;

    required_modules=(ahci sd_mod)
    for module in "${required_modules[@]}"; do
        copy_module_with_dependencies "$initrd_root" "$kernel_version" "$module"
    done

    mkdir -p "$initrd_root/conf"
    {
        [[ -f "$initrd_root/conf/modules" ]] && cat "$initrd_root/conf/modules"
        printf '%s\n' ahci sd_mod
    } | awk 'NF && !seen[$0]++' > "$initrd_root/conf/modules.qemu"
    mv "$initrd_root/conf/modules.qemu" "$initrd_root/conf/modules"

    (
        cd "$initrd_root"
        find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$BOOT_FILES/$out"
    )

    echo "Prepared QEMU virt initramfs with AHCI storage modules: $out (kernel modules: $kernel_version)" >&2
    printf '%s\n' "$out"
}

select_initrd() {
    local kernel="$1"
    local config="$BOOT_MNT/config.txt"
    local explicit candidate
    if [[ -f "$config" ]]; then
        explicit="$(awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*initramfs[[:space:]]+/ { print $2; exit }
        ' "$config")"
        if [[ -n "$explicit" && -f "$BOOT_MNT/$explicit" ]]; then
            printf '%s\n' "$explicit"
            return 0
        fi
    fi

    case "$kernel" in
        kernel8.img)
            for candidate in initramfs8 initramfs_2710 initrd.img; do
                [[ -f "$BOOT_MNT/$candidate" ]] && printf '%s\n' "$candidate" && return 0
            done
            ;;
        kernel7l.img)
            for candidate in initramfs7l initramfs_2711 initrd.img; do
                [[ -f "$BOOT_MNT/$candidate" ]] && printf '%s\n' "$candidate" && return 0
            done
            ;;
        kernel7.img)
            for candidate in initramfs7 initramfs_2709 initrd.img; do
                [[ -f "$BOOT_MNT/$candidate" ]] && printf '%s\n' "$candidate" && return 0
            done
            ;;
        kernel.img)
            for candidate in initramfs initrd.img; do
                [[ -f "$BOOT_MNT/$candidate" ]] && printf '%s\n' "$candidate" && return 0
            done
            ;;
    esac
    return 1
}

try_dtmerge() {
    local source_dtb="$1"
    local output_dtb="$2"
    local dtmerge="$ROOT_MNT/usr/bin/dtmerge"
    local emulator
    [[ -x "$dtmerge" ]] || return 1

    case "$(file -b "$dtmerge")" in
        *aarch64*)
            emulator="qemu-aarch64-static"
            ;;
        *ARM*)
            emulator="qemu-arm-static"
            ;;
        *)
            return 1
            ;;
    esac
    command -v "$emulator" >/dev/null 2>&1 || return 1

    "$emulator" -L "$ROOT_MNT" "$dtmerge" "$source_dtb" "$output_dtb" - uart0=on >/dev/null 2>&1 \
        || return 1
    if [[ -f "$BOOT_MNT/overlays/disable-bt.dtbo" ]]; then
        "$emulator" -L "$ROOT_MNT" "$dtmerge" "$output_dtb" "$output_dtb.tmp" \
            "$BOOT_MNT/overlays/disable-bt.dtbo" >/dev/null 2>&1 \
            || return 1
        mv "$output_dtb.tmp" "$output_dtb"
    fi
}

prepare_qemu_dtb() {
    local dtb="$1"
    local merged="qemu-$dtb"
    if try_dtmerge "$BOOT_FILES/$dtb" "$BOOT_FILES/$merged"; then
        echo "Prepared QEMU DTB with uart0=on and disable-bt overlay when available: $merged" >&2
        printf '%s\n' "$merged"
        return 0
    fi
    echo "Using unmodified DTB: $dtb" >&2
    printf '%s\n' "$dtb"
}

prepare_boot_files() {
    local kernel qemu_kernel dtb qemu_dtb cmdline initrd qemu_initrd root_partuuid boot_mode
    mkdir -p "$BOOT_FILES"

    if [[ -f "$BOOT_MNT/kernel8.img" ]]; then
        kernel="kernel8.img"
        dtb="bcm2710-rpi-3-b.dtb"
    elif [[ -f "$BOOT_MNT/kernel7.img" ]]; then
        kernel="kernel7.img"
        dtb="bcm2709-rpi-2-b.dtb"
    elif [[ -f "$BOOT_MNT/kernel7l.img" ]]; then
        kernel="kernel7l.img"
        dtb="bcm2711-rpi-4-b.dtb"
    else
        fail "no supported Raspberry Pi kernel found in boot partition"
    fi

    if [[ "$kernel" == "kernel8.img" && "$QEMU_MACHINE_MODE" != "raspi" ]]; then
        boot_mode="virt"
    else
        boot_mode="raspi"
    fi

    qemu_kernel="$(prepare_qemu_kernel "$kernel")"
    if [[ "$boot_mode" == "raspi" ]]; then
        copy_boot_file "$dtb"
        qemu_dtb="$(prepare_qemu_dtb "$dtb")"
    else
        qemu_dtb=""
    fi

    if initrd="$(select_initrd "$kernel")"; then
        copy_optional_boot_file "$initrd"
        if [[ "$boot_mode" == "virt" ]]; then
            qemu_initrd="$(prepare_virt_initrd "$initrd" "$kernel" "$qemu_kernel")"
        else
            qemu_initrd="$initrd"
        fi
        printf '%s\n' "$qemu_initrd" > "$BOOT_FILES/initrd-name"
        echo "Using initramfs for direct QEMU boot: $initrd"
    else
        rm -f "$BOOT_FILES/initrd-name"
        echo "No initramfs selected for direct QEMU boot"
    fi

    cmdline="$(tr -d '\n' < "$BOOT_MNT/cmdline.txt")"
    cmdline="${cmdline//console=serial0,115200/console=ttyAMA0,115200}"
    cmdline="${cmdline//console=serial0/console=ttyAMA0,115200}"
    cmdline="$(printf '%s\n' "$cmdline" \
        | sed -E 's/(^| )init=[^ ]+//g; s/(^| )quiet( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
    if [[ "$boot_mode" == "virt" ]]; then
        cmdline="$(cmdline_set_arg "$cmdline" root "/dev/sda2")"
    elif root_partuuid="$(partition_uuid 2)"; then
        cmdline="$(cmdline_set_arg "$cmdline" root "PARTUUID=$root_partuuid")"
    fi
    cmdline="$(cmdline_add_flag "$cmdline" rootwait)"
    cmdline="$(cmdline_set_arg "$cmdline" rootfstype ext4)"
    printf '%s systemd.unit=multi-user.target systemd.show_status=1 nr_cpus=1 maxcpus=1\n' "$cmdline" > "$BOOT_FILES/cmdline.txt"
    printf '%s\n' "$qemu_kernel" > "$BOOT_FILES/kernel-name"
    printf '%s\n' "$qemu_dtb" > "$BOOT_FILES/dtb-name"
    printf '%s\n' "$boot_mode" > "$BOOT_FILES/boot-mode"
}

write_guest_probe() {
    install -d -m 0755 "$ROOT_MNT/opt/airplanes-boot-smoke"
    install -d -m 0755 "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
    rsync -a --delete "$FEED_SOURCE/" "$ROOT_MNT/opt/airplanes-boot-smoke/feed-worktree/"
    rsync -a --delete "$FEED_BARE/" "$ROOT_MNT/opt/airplanes-boot-smoke/feed.git/"
    rsync -a --delete "$MLAT_BARE/" "$ROOT_MNT/opt/airplanes-boot-smoke/mlat.git/"
    rsync -a --delete "$READSB_BARE/" "$ROOT_MNT/opt/airplanes-boot-smoke/readsb.git/"
    printf '%s\n' "$IMAGE_CONTRACT" > "$ROOT_MNT/opt/airplanes-boot-smoke/image-contract"

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
IMAGE_CONTRACT="$(cat /opt/airplanes-boot-smoke/image-contract 2>/dev/null || echo legacy)"
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

assert_regex() {
    grep -qE -- "$2" "$1" || fail "$1 does not match regex: $2"
}

assert_not_exists() {
    [[ ! -e "$1" ]] || fail "unexpected path exists: $1"
}

assert_valid_uuid_file() {
    local path="$1"
    local raw uuid
    assert_file "$path"
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

assert_image_contracts() {
    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        assert_file /boot/airplanes-config.txt
        assert_file /boot/airplanes-env
    else
        assert_file /etc/airplanes/feed.env
    fi
    assert_valid_uuid_file /etc/airplanes/feeder-id
    assert_symlink_target /usr/local/share/airplanes/airplanes-uuid '../../../../etc/airplanes/feeder-id'
    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        assert_exec /usr/bin/airplanes-feeder
    else
        assert_exec /usr/local/share/airplanes/feed-airplanes
    fi
    assert_exec /usr/local/bin/apl-feed
    assert_file /usr/local/share/airplanes/update.sh
    assert_file /usr/local/share/airplanes/airplanes-feed.sh
    assert_file /usr/local/share/airplanes/airplanes-mlat.sh
    assert_file /usr/local/share/airplanes/apl-feed/common.sh
    assert_file /etc/systemd/system/airplanes-feed.service
    assert_file /etc/systemd/system/airplanes-mlat.service
    assert_file /etc/systemd/system/airplanes-first-run.service
    assert_contains /etc/systemd/system/airplanes-feed.service 'ExecStart=/usr/local/share/airplanes/airplanes-feed.sh'
    assert_regex /etc/systemd/system/airplanes-feed.service '^After=.*airplanes-first-run.service'
    assert_contains /etc/systemd/system/airplanes-mlat.service 'ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh'
    assert_regex /etc/systemd/system/airplanes-mlat.service '^After=.*airplanes-first-run.service'
    assert_contains /usr/local/share/airplanes/airplanes-feed.sh 'feed2.airplanes.live,64004'
    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        assert_not_exists /etc/airplanes/feed.env
        [[ -L /etc/default/airplanes ]] || fail "/etc/default/airplanes is not a symlink"
        [[ "$(readlink /etc/default/airplanes)" == "/boot/airplanes-config.txt" ]] \
            || fail "/etc/default/airplanes does not point at /boot/airplanes-config.txt"
    fi
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

prepare_readsb_fixture() {
    local readsb_version
    install -d -m 0755 /usr/local/share/airplanes
    if [[ ! -x /usr/bin/airplanes-feeder && ! -x /usr/local/share/airplanes/feed-airplanes ]]; then
        cat > /usr/local/share/airplanes/feed-airplanes <<'SH'
#!/usr/bin/env bash
exit 0
SH
        chmod 0755 /usr/local/share/airplanes/feed-airplanes
    fi
    readsb_version="$(git --git-dir=/opt/airplanes-boot-smoke/readsb.git rev-parse refs/heads/dev)"
    printf '%s\n' "$readsb_version" > /usr/local/share/airplanes/readsb_version
}

run_feed_update() {
    prepare_mlat_fixture
    prepare_readsb_fixture
    APL_FEED_BIN=/opt/airplanes-boot-smoke/apl-feed-stub \
    APL_FEED_MAX_RETRY_TIME=1 \
    AIRPLANES_PACKAGE_MANAGER=none \
    AIRPLANES_FEED_REPO=file:///opt/airplanes-boot-smoke/feed.git \
    AIRPLANES_FEED_BRANCH=boot-smoke \
    AIRPLANES_MLAT_REPO=file:///opt/airplanes-boot-smoke/mlat.git \
    AIRPLANES_MLAT_BRANCH=master \
    AIRPLANES_READSB_REPO=file:///opt/airplanes-boot-smoke/readsb.git \
    AIRPLANES_READSB_BRANCH=dev \
        bash /opt/airplanes-boot-smoke/feed-worktree/update.sh
}

feed_binary_path() {
    # The feed binary lives in different places per contract: legacy images
    # ship an image-baked binary at /usr/bin/airplanes-feeder; new-contract
    # installs build the binary into /usr/local/share/airplanes/feed-airplanes.
    # Idempotency assertions need the right one.
    if [[ "$IMAGE_CONTRACT" == "legacy" ]]; then
        printf '%s\n' /usr/bin/airplanes-feeder
    else
        printf '%s\n' /usr/local/share/airplanes/feed-airplanes
    fi
}

snapshot_post_update_state() {
    # Captures things that should be stable across reboot + idempotent re-run:
    #   - feed + mlat binary mtimes (update.sh fast-path skip MUST not rebuild)
    #   - feeder-id content hash (UUID must survive reboot byte-stable)
    local feed_bin mlat_bin
    feed_bin="$(feed_binary_path)"
    mlat_bin=/usr/local/share/airplanes/venv/bin/mlat-client
    stat -c '%Y %n' "$feed_bin" "$mlat_bin" > "$STATE_DIR/snapshot-mtimes"
    sha256sum /etc/airplanes/feeder-id > "$STATE_DIR/snapshot-feeder-id"
}

assert_state_file_schema_v1() {
    local path="$1"
    assert_file "$path"
    grep -q '^schema_version=1$' "$path" \
        || fail "$path missing schema_version=1 (daemon state-file contract)"
}

assert_service_healthy() {
    local unit="$1"
    # is-active is the load-bearing check: catches inactive, dead, never-started.
    systemctl is-active --quiet "$unit" \
        || fail "$unit is not active"
    # is-failed is an additional diagnostic: catches the explicit failed state
    # that is-active alone would already cover, but surfaces it loudly with a
    # distinct message.
    if systemctl is-failed --quiet "$unit"; then
        fail "$unit reports failed state"
    fi
}

assert_uuid_stable_across_reboot() {
    local before after
    before="$(cut -d' ' -f1 < "$STATE_DIR/snapshot-feeder-id")"
    after="$(sha256sum /etc/airplanes/feeder-id | cut -d' ' -f1)"
    [[ "$before" == "$after" ]] \
        || fail "feeder-id changed across reboot (before=$before after=$after)"
}

assert_binaries_unchanged() {
    # Idempotency: a second update.sh run on a freshly-updated rootfs must
    # take the version-match fast path and leave the costly artifacts alone.
    local pre_snap post_snap
    pre_snap="$STATE_DIR/snapshot-mtimes"
    post_snap="$STATE_DIR/snapshot-mtimes-post-rerun"
    local feed_bin mlat_bin
    feed_bin="$(feed_binary_path)"
    mlat_bin=/usr/local/share/airplanes/venv/bin/mlat-client
    stat -c '%Y %n' "$feed_bin" "$mlat_bin" > "$post_snap"
    if ! diff -q "$pre_snap" "$post_snap" >/dev/null; then
        echo "pre-rerun snapshot:" >&2
        cat "$pre_snap" >&2
        echo "post-rerun snapshot:" >&2
        cat "$post_snap" >&2
        fail "idempotent update.sh rerun changed binary mtimes (legacy must not rebuild image-baked binary; new must hit the version-match fast path)"
    fi
}

phase="$(cat "$STATE_DIR/phase" 2>/dev/null || true)"
case "$phase" in
    '')
        echo "airplanes image boot smoke: initial update phase"
        run_feed_update
        assert_image_contracts
        assert_service_healthy airplanes-feed.service
        snapshot_post_update_state
        printf '%s\n' updated > "$STATE_DIR/phase"
        sync
        systemctl reboot
        ;;
    updated)
        echo "airplanes image boot smoke: post-reboot verification phase"
        assert_image_contracts
        assert_service_healthy airplanes-feed.service
        # mlat unit stays active even when MLAT_ENABLED=false (it self-disables
        # via sleep+exit per the daemon classifier in rules/architecture.md),
        # so is-active is a safe assertion across both branches.
        assert_service_healthy airplanes-mlat.service
        assert_state_file_schema_v1 /run/airplanes-feed/state
        assert_state_file_schema_v1 /run/airplanes-mlat/state
        assert_uuid_stable_across_reboot

        echo "airplanes image boot smoke: idempotency rerun phase"
        # Re-run update.sh against the same fixture repos. The version-match
        # fast paths in update-builds.sh should leave the binaries alone.
        run_feed_update
        assert_binaries_unchanged
        assert_service_healthy airplanes-feed.service
        assert_service_healthy airplanes-mlat.service

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
    local kernel dtb cmdline boot_mode qemu_bin machine cpu smp initrd
    local -a args
    kernel="$(cat "$BOOT_FILES/kernel-name")"
    dtb="$(cat "$BOOT_FILES/dtb-name")"
    cmdline="$(cat "$BOOT_FILES/cmdline.txt")"
    boot_mode="$(cat "$BOOT_FILES/boot-mode")"

    if [[ "$boot_mode" == "virt" ]]; then
        qemu_bin="qemu-system-aarch64"
        machine="virt"
        cpu="cortex-a53"
        smp="4"
    elif [[ "$kernel" == "kernel8.img" || "$kernel" == "kernel8.uncompressed.img" ]]; then
        qemu_bin="qemu-system-aarch64"
        machine="raspi3b"
        cpu="cortex-a53"
        smp="4"
    else
        qemu_bin="qemu-system-arm"
        machine="raspi2b"
        cpu=""
        smp="1"
    fi

    require_command "$qemu_bin"
    args=("$qemu_bin" -M "$machine")
    if [[ -n "$cpu" ]]; then
        args+=(-cpu "$cpu")
    fi
    args+=(
        -smp "$smp"
        -m 1G
        -kernel "$BOOT_FILES/$kernel"
    )
    if [[ -n "$dtb" ]]; then
        args+=(-dtb "$BOOT_FILES/$dtb")
    fi
    if [[ -f "$BOOT_FILES/initrd-name" ]]; then
        initrd="$(cat "$BOOT_FILES/initrd-name")"
        args+=(-initrd "$BOOT_FILES/$initrd")
    fi
    args+=(-append "$cmdline")
    if [[ "$boot_mode" == "virt" ]]; then
        args+=(
            -nic none
            -drive "file=$IMAGE_FILE,format=raw,if=none,id=hd0"
            -device "ich9-ahci,id=ahci"
            -device "ide-hd,drive=hd0,bus=ahci.0"
        )
    else
        args+=(
            -drive "file=$IMAGE_FILE,format=raw,if=sd"
            -netdev "user,id=net0"
            -device "usb-net,netdev=net0"
        )
    fi
    args+=(-serial mon:stdio -display none -no-reboot)
    printf '%q ' "${args[@]}"
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
    local image_archive rc
    require_commands curl jq git rsync parted sfdisk awk mount umount find cp tee timeout file
    require_commands strings modprobe unmkinitramfs cpio
    require_commands unzip xz gzip gh
    if [[ -n "${AIRPLANES_IMAGE_PATH:-}" ]]; then
        image_archive="$AIRPLANES_IMAGE_PATH"
        [[ -f "$image_archive" ]] || fail "AIRPLANES_IMAGE_PATH does not exist: $image_archive"
    else
        # Capture under temporarily-relaxed errexit so the 64 sentinel
        # (tier exhaustion) can be handled as a skip rather than hard fail.
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
    resize_image_for_qemu_sd
    make_feed_repo
    make_mlat_repo
    make_readsb_repo

    mount_partitions
    prepare_boot_files
    write_guest_probe
    unmount_partitions

    run_boot_smoke
}

main "$@"
