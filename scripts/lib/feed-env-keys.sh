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
# Also provides the feed.env documentation renderers (_apl_feed_render_header,
# _apl_feed_render_key_doc) so both writers — configure.sh and
# feed-env-apply.sh's _apl_feed_apply_write — emit the same header and per-key
# comments from one source. Safe to re-source; no side effects beyond the
# global definitions above.

declare -ga APL_FEED_WRITABLE_KEYS=(
    LATITUDE
    LONGITUDE
    ALTITUDE
    GEO_CONFIGURED
    MLAT_USER
    MLAT_ENABLED
    MLAT_PRIVATE
    GAIN
    READSB_SDR_SERIAL
    UAT_INPUT
    DUMP978_SDR_SERIAL
    DUMP978_GAIN
    REPORT_STATUS
    REMOTE_CONFIG_ENABLED
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
    READSB_SDR_SERIAL
    UAT_INPUT
    DUMP978_SDR_SERIAL
    DUMP978_GAIN
    REPORT_STATUS
    REMOTE_CONFIG_ENABLED
    # Read-only backend pointer (like INPUT/INPUT_TYPE it has no writer
    # here): consumers such as the webconfig claim page need the website
    # host a custom-backend feeder registered against, and `config show`
    # is the supported way to read it without parsing feed.env.
    APL_FEED_WEBSITE_URL
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
    [READSB_SDR_SERIAL]=readsb_sdr_serial
    [UAT_INPUT]=uat_input
    [DUMP978_SDR_SERIAL]=dump978_serial
    [DUMP978_GAIN]=dump978_gain
    [REPORT_STATUS]=bool
    [REMOTE_CONFIG_ENABLED]=bool
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
    [READSB_SDR_SERIAL]="readsb"
    [UAT_INPUT]="airplanes-feed dump978-fa airplanes-978"
    [DUMP978_SDR_SERIAL]="dump978-fa airplanes-978"
    [DUMP978_GAIN]="dump978-fa"
    [REPORT_STATUS]=""
    [REMOTE_CONFIG_ENABLED]=""
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

# Top comment block for feed.env. Emitted first by every writer so the
# operator-config preamble, the format contract, and the diagnostics /
# REPORT_STATUS hand-edit warning survive every rewrite (a webconfig save
# goes through _apl_feed_apply_write, which would otherwise strip them).
# Single-quoted heredoc: the text contains no expansions and must never be
# subject to any. All lines are full-line `#` comments — safe for shell
# `source`, systemd EnvironmentFile, and the strict apl-feed reader.
_apl_feed_render_header() {
    cat <<'EOF'
# /etc/airplanes/feed.env — operator-supplied configuration for the
# airplanes.live feeder daemons. Product-side defaults (brand endpoints,
# readsb tuning, the local RESULTS output bundle, REDUCE_INTERVAL) live
# in the daemon scripts; add overrides here only if you run a custom
# airplanes.live backend or non-default decoder hardware.
#
# Format contract: one KEY=value or KEY="value" per line, plain scalar
# values only — no shell expansion or escapes, no 'export' prefix, no
# comment on a value's line, no line continuations. This file has
# several consumers (shell, systemd, the apl-feed CLI); other shapes
# parse differently between them and may be dropped on rewrite. Read
# values with 'apl-feed config show' instead of parsing this file.
#
# Diagnostics push: every 10 minutes the feeder reports anonymized CPU,
# temperature, disk, memory, uptime, service health, and version info to
# airplanes.live. Visible only on your own logged-in dashboard. The
# schema excludes hostname, MAC, LAN IP, SSID, and Pi serial number.
#
# Default: enabled. Toggle via the CLI (the canonical writer, which also
# runs through validation + the apply lock):
#   sudo apl-feed diagnostics enable
#   sudo apl-feed diagnostics disable
# Don't hand-edit REPORT_STATUS below — direct edits bypass validation
# and the lock that webconfig holds during concurrent writes.
#REPORT_STATUS=true
EOF
}

# Per-key documentation comment, printed immediately above the key's value
# line. Documented set mirrors what configure.sh historically emitted;
# every other key (LATITUDE/LONGITUDE/ALTITUDE covered by the header,
# REPORT_STATUS explained in the header, and the SDR/UAT tuning keys)
# returns nothing. `case` (not an associative-array lookup) keeps this
# safe under `set -u` when called for unowned keys like APL_FEED_WEBSITE_URL.
# Single-quoted heredocs: comment text must never expand. INPUT_TYPE has no
# entry — INPUT carries the shared decoder note for the pair so the apply
# writer (which emits the keys consecutively) prints it once.
_apl_feed_render_key_doc() {
    case "$1" in
        GEO_CONFIGURED)
            cat <<'EOF'
# Explicit "user has provided real coordinates" flag. The daemon refuses
# to start MLAT until this is true; the legacy "LATITUDE=0 means unset"
# sentinel is retired. Image freeze writes false; configure.sh writes
# true when both coords are non-zero (Atlantic 0,0 placeholders stay
# false). The webconfig UI writes this explicitly when the user saves.
EOF
            ;;
        MLAT_USER)
            cat <<'EOF'
# Display name shown on the MLAT map. Used as mlat-client's --user.
EOF
            ;;
        MLAT_ENABLED)
            cat <<'EOF'
# Explicit on/off toggle. When false, airplanes-mlat exits early.
EOF
            ;;
        MLAT_PRIVATE)
            cat <<'EOF'
# Hide the feed name on the public MLAT map. true|false. Position is
# never shown accurately no matter the setting. Toggle with:
#   sudo apl-feed mlat private enable
#   sudo apl-feed mlat private disable
EOF
            ;;
        INPUT)
            cat <<'EOF'
# Non-default receiver decoder. Defaults are 127.0.0.1:30005 / dump1090.
EOF
            ;;
        REPORT_STATUS)
            cat <<'EOF'
# Diagnostics push toggle; see the header. Set via apl-feed diagnostics
# enable/disable, never by hand.
EOF
            ;;
        *)
            return 0
            ;;
    esac
}
