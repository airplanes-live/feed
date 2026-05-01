#!/bin/bash
# Test-container entrypoint for apl-feed claim register. Generates a fresh
# Feeder ID for the container if none exists yet, so each `docker run`
# produces an independent registration rather than replaying the same ID.
set -euo pipefail

FEEDER_ID_PATH=/etc/airplanes/feeder-id
if [[ ! -s "$FEEDER_ID_PATH" ]]; then
    install -D -m 0644 /dev/null "$FEEDER_ID_PATH"
    cat /proc/sys/kernel/random/uuid > "$FEEDER_ID_PATH"
fi

exec /usr/local/bin/apl-feed claim register "$@"
