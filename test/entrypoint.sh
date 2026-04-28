#!/bin/bash
# Test-container entrypoint for apl-feed claim register. Generates a fresh
# UUID for the container if none exists yet, so each `docker run` produces
# an independent registration rather than replaying the same UUID.
set -euo pipefail

UUID_PATH=/usr/local/share/airplanes/airplanes-uuid
if [[ ! -s "$UUID_PATH" ]]; then
    install -D -m 0644 /dev/null "$UUID_PATH"
    cat /proc/sys/kernel/random/uuid > "$UUID_PATH"
fi

exec /usr/local/bin/apl-feed claim register "$@"
