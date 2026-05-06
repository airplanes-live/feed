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

# Heal claim-state files left over from feed versions that wrote them as
# root:root mode 0600 (or as airplanes-feed:nogroup owner-only mode 0600 from
# the brief pre-group pivot). Sets owner=group=airplanes-feed and mode 0640
# so service accounts in the airplanes-feed group can read directly without
# escalating to root. Idempotent. Non-fatal on chown/chmod failure but warns
# to stderr so a stuck file is visible in update logs instead of silently
# keeping webconfig broken.
heal_claim_state_ownership() {
    local etc="$1"
    local owner="${APL_FEED_SECRET_OWNER:-airplanes-feed}"
    local group="${APL_FEED_SECRET_GROUP:-$owner}"
    local file path
    for file in feeder-claim-secret feeder-claim-secret.pending feeder-claim-secret.version; do
        path="$etc/$file"
        [[ -f "$path" ]] || continue
        if ! chown "$owner":"$group" "$path" 2>/dev/null; then
            echo "WARNING: failed to chown $path to $owner:$group; webconfig 'claim show' may stay broken on this feeder" >&2
            continue
        fi
        if ! chmod 640 "$path" 2>/dev/null; then
            echo "WARNING: failed to chmod $path to 0640" >&2
        fi
    done
}
