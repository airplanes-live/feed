#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/install-update-common.sh
source "$SCRIPT_DIR/scripts/lib/install-update-common.sh"
airplanes_enable_build_mode_from_args "$@"
airplanes_init_paths

if airplanes_is_build_mode; then
    echo "Build mode: skipping per-device feeder ID generation."
    exit 0
fi

valid_uuid() {
    [[ "$1" =~ ^\{?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}\}?$ ]]
}

normalize_uuid() {
    tr -d '\n\r{}' < "$1" | tr 'A-F' 'a-f'
}

read_existing_uuid() {
    local candidate raw pre_fhs_uuid
    # Pre-FHS installs kept the legacy UUID under the old $IPATH at
    # /usr/local/share/airplanes/airplanes-uuid. LEGACY_UUID_FILE now points at
    # the new $STATE location, so include the old path explicitly — otherwise an
    # upgrade across the FHS layout move would lose feeder identity before it has
    # been migrated into /etc/airplanes/feeder-id.
    pre_fhs_uuid="$(airplanes_path /usr/local/share/airplanes/airplanes-uuid)"
    for candidate in "$FEEDER_ID_FILE" "$LEGACY_UUID_FILE" "$pre_fhs_uuid" "$BOOT_UUID_FILE"; do
        [[ -f "$candidate" ]] || continue
        raw="$(normalize_uuid "$candidate")"
        if valid_uuid "$raw"; then
            UUID="$raw"
            UUID_SOURCE="$candidate"
            return 0
        fi
        echo "WARNING: Data in UUID file $candidate was invalid. Ignoring it."
    done
    return 1
}

generate_uuid() {
    sleep 0.$RANDOM
    sleep 0.$RANDOM
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    UUID_SOURCE=''
    echo "New Feeder ID: $UUID"
}

write_feeder_id() {
    local tmp
    mkdir -p "$ETC_AIRPLANES"
    tmp="$FEEDER_ID_FILE.$$"
    printf '%s\n' "$UUID" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$FEEDER_ID_FILE"
}

install_legacy_uuid_symlink() {
    mkdir -p "$(dirname "$LEGACY_UUID_FILE")"
    rm -f "$LEGACY_UUID_FILE"
    ln -sfn '../../../../etc/airplanes/feeder-id' "$LEGACY_UUID_FILE"
}

if read_existing_uuid; then
    echo "Using existing valid Feeder ID ($UUID) from $UUID_SOURCE"
else
    echo "WARNING: No valid Feeder ID found, generating a new one..."
    generate_uuid
fi

write_feeder_id
install_legacy_uuid_symlink

exit 0
