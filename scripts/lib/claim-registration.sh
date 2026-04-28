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
