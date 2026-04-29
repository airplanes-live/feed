#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/install-update-common.sh
source "$SCRIPT_DIR/scripts/lib/install-update-common.sh"
airplanes_init_paths

if [ -f "$BOOT_CONFIG" ]; then
    UUID_FILE="$(airplanes_path /boot/airplanes-uuid)"
else
    mkdir -p "$IPATH"
    UUID_FILE="$IPATH/airplanes-uuid"
    # move old file position
    BOOT_UUID="$(airplanes_path /boot/airplanes-uuid)"
    if [ -f "$BOOT_UUID" ]; then
        mv -f "$BOOT_UUID" "$UUID_FILE"
    fi
fi

function generateUUID() {
    rm -f "$UUID_FILE"
    sleep 0.$RANDOM; sleep 0.$RANDOM
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo New UUID: $UUID
    echo "$UUID" > "$UUID_FILE"
}

# Check for a (valid) UUID...
if [ -f "$UUID_FILE" ]; then
    UUID=$(cat "$UUID_FILE")
    if ! [[ $UUID =~ ^\{?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}\}?$ ]]; then
        # Data in UUID file is invalid.  Regenerate it!
        echo "WARNING: Data in UUID file was invalid.  Regenerating UUID."
        generateUUID
    else
        echo "Using existing valid UUID ($UUID) from $UUID_FILE"
    fi
else
    # not found generate uuid and save it
    echo "WARNING: No UUID file found, generating new UUID..."
    generateUUID
fi

exit 0
