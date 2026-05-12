#!/usr/bin/env bash
# Centralized registry for /etc/airplanes/feed.env keys.
#
# Single source of truth consumed by:
#   - feed-env-apply.sh   (per-key validation, restart map)
#   - apl-feed/schema.sh  (HTTP-readable schema for webconfig boot)
#   - apl-feed/import.sh  (legacy-key mapping target set)
#
# Loads four bash globals into the caller's scope (no other side effects):
#
#   APL_FEED_WRITABLE_KEYS    indexed array, canonical write-order
#   APL_FEED_READABLE_KEYS    indexed array, canonical read-order (superset)
#   APL_FEED_KEY_TYPE         associative; type tag per key, drives validators
#   APL_FEED_KEY_RESTART      associative; space-separated service list per key
#
# Pure-data file. Safe to re-source.

declare -ga APL_FEED_WRITABLE_KEYS=(
    LATITUDE
    LONGITUDE
    ALTITUDE
    GEO_CONFIGURED
    MLAT_USER
    MLAT_ENABLED
    MLAT_PRIVATE
    GAIN
    UAT_INPUT
    DUMP978_SDR_SERIAL
    DUMP978_GAIN
)

declare -ga APL_FEED_READABLE_KEYS=(
    LATITUDE
    LONGITUDE
    ALTITUDE
    GEO_CONFIGURED
    MLAT_USER
    MLAT_ENABLED
    MLAT_PRIVATE
    INPUT
    INPUT_TYPE
    GAIN
    UAT_INPUT
    DUMP978_SDR_SERIAL
    DUMP978_GAIN
)

declare -gA APL_FEED_KEY_TYPE=(
    [LATITUDE]=latitude
    [LONGITUDE]=longitude
    [ALTITUDE]=altitude
    [GEO_CONFIGURED]=bool
    [MLAT_USER]=mlat_user
    [MLAT_ENABLED]=bool
    [MLAT_PRIVATE]=bool
    [GAIN]=gain
    [UAT_INPUT]=uat_input
    [DUMP978_SDR_SERIAL]=dump978_serial
    [DUMP978_GAIN]=dump978_gain
)

# Restart map: a key landing on disk → space-separated list of systemd units
# that must be restarted. Audited from the EnvironmentFile= consumers on
# the image side (readsb.sh, airplanes-feed.sh, airplanes-mlat.sh,
# airplanes-978.sh, dump978-fa.sh). GEO_CONFIGURED is consumed in-process
# by the daemon state classifier and does not require a restart.
declare -gA APL_FEED_KEY_RESTART=(
    [LATITUDE]="readsb airplanes-feed airplanes-978 airplanes-mlat"
    [LONGITUDE]="readsb airplanes-feed airplanes-978 airplanes-mlat"
    [ALTITUDE]="airplanes-mlat"
    [GEO_CONFIGURED]=""
    [MLAT_USER]="airplanes-mlat"
    [MLAT_ENABLED]="airplanes-mlat"
    [MLAT_PRIVATE]="airplanes-mlat"
    [GAIN]="readsb"
    [UAT_INPUT]="airplanes-feed dump978-fa airplanes-978"
    [DUMP978_SDR_SERIAL]="dump978-fa airplanes-978"
    [DUMP978_GAIN]="dump978-fa"
)

apl_feed_is_writable_key() {
    local needle="$1" k
    for k in "${APL_FEED_WRITABLE_KEYS[@]}"; do
        [[ "$k" == "$needle" ]] && return 0
    done
    return 1
}

apl_feed_is_readable_key() {
    local needle="$1" k
    for k in "${APL_FEED_READABLE_KEYS[@]}"; do
        [[ "$k" == "$needle" ]] && return 0
    done
    return 1
}
