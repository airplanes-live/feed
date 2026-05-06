#!/usr/bin/env bash

register_claim_secret() {
    local retry_time feed_bin
    retry_time="${APL_FEED_MAX_RETRY_TIME:-15}"
    feed_bin="${APL_FEED_BIN:-/usr/local/bin/apl-feed}"

    echo "Registering feeder claim secret"
    if ! APL_FEED_MAX_RETRY_TIME="$retry_time" \
        "$feed_bin" claim register \
            --max-retry-time "$retry_time"
    then
        echo "---------------------------------"
        echo "WARNING: claim registration did not complete."
        echo "Your feeder will continue feeding. The next update will retry registration."
        echo "You can also retry manually:"
        echo "sudo apl-feed claim register"
        echo "---------------------------------"
    fi
}

# Hand off ownership of any pre-existing claim-state files in the given
# /etc/airplanes/-equivalent to the daemon user, so feeders that registered
# under an older feed (which left files root:root mode 0600) heal on the
# next update without needing a re-register. Idempotent. Owner-only —
# `chown user` (no trailing colon) leaves the group untouched. Non-fatal
# on chown failure but warns to stderr so a stuck root-owned secret is
# visible in update logs instead of silently keeping webconfig broken.
heal_claim_state_ownership() {
    local etc="$1"
    local owner="${APL_FEED_SECRET_OWNER:-airplanes-feed}"
    local file path
    for file in feeder-claim-secret feeder-claim-secret.pending feeder-claim-secret.version; do
        path="$etc/$file"
        [[ -f "$path" ]] || continue
        if ! chown "$owner" "$path" 2>/dev/null; then
            echo "WARNING: failed to chown $path to $owner; webconfig 'claim show' may stay broken on this feeder" >&2
        fi
    done
}
