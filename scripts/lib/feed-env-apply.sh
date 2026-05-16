#!/usr/bin/env bash
# Privileged feed.env writer library.
#
# Public entry point: apl_feed_apply
#
# Helper deps the caller must source first:
#   - configure-validators.sh (valid_*, sanitize_mlat_user, normalize_altitude)
#   - feed-env-keys.sh        (APL_FEED_WRITABLE_KEYS, APL_FEED_KEY_TYPE, etc.)
#
# Optional helper deps (consulted defensively):
#   - install-update-common.sh (airplanes_is_build_mode) — call falls through
#     to a static check on AIRPLANES_BUILD_MODE when the helper is absent.
#
# Effects:
#   * Reads the configured feed.env path.
#   * Merges caller-supplied KEY=value pairs onto the parsed state.
#   * Auto-derives GEO_CONFIGURED when LAT/LON were touched without an
#     explicit override (matches Go configspec.ApplyGeoDeriveOnUpdate).
#   * Validates each touched key per its type tag and the merged state's
#     cross-key consistency rules. On any validation failure, nothing is
#     written.
#   * Atomically rewrites the file under flock so concurrent writers
#     serialize. The lock is released *before* any systemctl restart so a
#     slow restart cannot block subsequent saves.
#   * Restarts services matched by APL_FEED_KEY_RESTART for keys whose
#     value actually changed. Failed restarts are reported via
#     APL_APPLY_PENDING_RESTART without rolling back the on-disk change.
#
# The library never prints to stdout — callers (apply.sh JSON adapter or
# subcommand facades) format output themselves from the result globals.

# Default paths. Caller may override via env before invoking.
APL_FEED_APPLY_FEED_ENV_DEFAULT="${APL_FEED_APPLY_FEED_ENV_DEFAULT:-/etc/airplanes/feed.env}"
APL_FEED_APPLY_LOCK_DEFAULT="${APL_FEED_APPLY_LOCK_DEFAULT:-/run/airplanes/feed-env.lock}"
APL_FEED_APPLY_LOCK_TIMEOUT_DEFAULT="${APL_FEED_APPLY_LOCK_TIMEOUT_DEFAULT:-30}"

# Sidecar metadata file ("feed.meta.json") lives next to feed.env by default.
# Only the *basename* is fixed here; the actual path is derived at call time
# from dirname(feed_env) so a `--feed-env /alt/path/feed.env` invocation
# automatically writes /alt/path/feed.meta.json and never touches the host.
APL_FEED_APPLY_META_BASENAME="feed.meta.json"

# The subset of feed.env keys whose per-write metadata is tracked in
# feed.meta.json. GEO_CONFIGURED is derived from LATITUDE/LONGITUDE and is
# intentionally not tracked; GAIN/UAT_INPUT/DUMP978_* are not part of
# remote configuration.
APL_FEED_APPLY_META_TRACKED_KEYS=(
    LATITUDE LONGITUDE ALTITUDE MLAT_USER MLAT_ENABLED MLAT_PRIVATE
)

# Allowed values for the `edited_by` field, both on read and on write.
APL_FEED_APPLY_EDITED_BY_ENUM="feeder website legacy"

# RFC 3339 UTC shape required for `edited_at`. Strict — the server side
# stamps with this exact format; webconfig writes do too.
APL_FEED_APPLY_EDITED_AT_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'

# Caller-input arrays. Parallel maps keyed by feed.env key. apl_feed_apply
# snapshots these into locals at entry; the caller MAY free them after the
# call. NOT reset by _apl_feed_apply_reset_state — they are inputs, not
# result state.
declare -gA APL_APPLY_INCOMING_META_EDITED_AT=()
declare -gA APL_APPLY_INCOMING_META_EDITED_BY=()

# Caller-input scalar: server-supplied "now" timestamp (RFC 3339 UTC)
# used as the reference for the LWW gate's bogus-future-heal check.
# Set by callers like `apl-feed config sync` to the server_time field of
# the response so a feeder with a fast local clock cannot self-mask its
# own corrupt on-disk metadata. Empty string => fall back to local now()
# (acceptable for callers that don't have a trusted external clock).
APL_APPLY_INCOMING_SERVER_TIME="${APL_APPLY_INCOMING_SERVER_TIME:-}"

# Result global: indexed array of payload keys whose write was skipped
# because the incoming metadata's edited_at was older-or-equal to the
# on-disk edited_at recorded in feed.meta.json. The skip is per-key —
# other payload keys in the same call apply normally. Skipped keys do
# NOT appear in APL_APPLY_CHANGED and do NOT trigger service restarts.
#
# Symmetric with the server-side merge: equal-edited_at favors the
# existing tuple on both sides, so a tie does not produce churn and the
# data converges via whichever side has the strictly-newer edit.
declare -ga APL_APPLY_SKIPPED_BY_LWW=()

# Universal-reject character set. Mirrors Go configspec.universalReject.
# Defense-in-depth: a regex-passing value containing a shell metachar
# cannot reach feed.env (which gets `source`d by airplanes-feed.sh and
# -mlat.sh). Bash strings cannot carry an embedded NUL, so NUL is
# rejected by checking the byte count of the value matches a NUL-free
# `tr -d` of itself. The other rejected bytes are kept in a single
# string and scanned by `[[ == *X* ]]`.
#   "  double quote     \   backslash
#   $  dollar           `   backtick
#   ;  statement sep    &   background
#   |  pipe             <   redirect-in
#   >  redirect-out     #   comment
#   LF / CR             '   single quote
_APL_FEED_APPLY_UNIVERSAL_REJECT_CHARS=$'\"\\$\x60;&|<>#\n\r\047'

_apl_feed_apply_universal_reject() {
    local value="$1" i ch
    # Reject embedded NUL up front. Bash variable assignment via $(...) /
    # read silently strips NUL bytes, so by the time a value reaches this
    # function it should be NUL-free. The byte-count check below is the
    # belt-and-braces guard for the case where it isn't.
    local stripped
    stripped="$(printf '%s' "$value" | tr -d '\0')"
    if [[ "$stripped" != "$value" ]]; then
        return 1
    fi
    for (( i = 0; i < ${#_APL_FEED_APPLY_UNIVERSAL_REJECT_CHARS}; i++ )); do
        ch="${_APL_FEED_APPLY_UNIVERSAL_REJECT_CHARS:$i:1}"
        if [[ "$value" == *"$ch"* ]]; then
            return 1
        fi
    done
    return 0
}

# Detect build mode without forcing a hard dep on install-update-common.sh.
_apl_feed_apply_is_build_mode() {
    if declare -F airplanes_is_build_mode >/dev/null 2>&1; then
        airplanes_is_build_mode
        return $?
    fi
    case "${AIRPLANES_BUILD_MODE:-}" in
        1|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Per-key validator dispatch by type tag. Sets APL_APPLY_ERRORS[$key] with
# a human-readable reason on rejection. Returns 0 on accept, 1 on reject.
_apl_feed_apply_validate_one() {
    local key="$1" value="$2" type
    type="${APL_FEED_KEY_TYPE[$key]:-}"

    if ! _apl_feed_apply_universal_reject "$value"; then
        APL_APPLY_ERRORS[$key]="contains forbidden character"
        return 1
    fi

    case "$type" in
        latitude)
            if ! valid_latitude "$value"; then
                APL_APPLY_ERRORS[$key]="must be a number in [-90, 90]"
                return 1
            fi
            ;;
        longitude)
            if ! valid_longitude "$value"; then
                APL_APPLY_ERRORS[$key]="must be a number in [-180, 180]"
                return 1
            fi
            ;;
        altitude)
            if ! valid_altitude "$value"; then
                APL_APPLY_ERRORS[$key]='must match -?\d+(\.\d+)?(m|ft)? in [-1000, 10000]'
                return 1
            fi
            ;;
        bool)
            if ! valid_bool "$value"; then
                APL_APPLY_ERRORS[$key]='must be "true" or "false"'
                return 1
            fi
            ;;
        mlat_user)
            # Empty is allowed (daemon Anonymous-<short-id> fallback). Any
            # other value must match the strict canonical pattern.
            if [[ -n "$value" ]] && ! valid_mlat_user_strict "$value"; then
                APL_APPLY_ERRORS[$key]='must match [A-Za-z0-9_-]{1,64} or be empty'
                return 1
            fi
            ;;
        gain)
            if ! valid_gain "$value"; then
                APL_APPLY_ERRORS[$key]='must be in [0, 60] or one of auto/min/max'
                return 1
            fi
            ;;
        uat_input)
            if ! valid_uat_input "$value"; then
                APL_APPLY_ERRORS[$key]='must be "" or "127.0.0.1:30978"'
                return 1
            fi
            ;;
        dump978_serial)
            if ! valid_dump978_serial "$value"; then
                APL_APPLY_ERRORS[$key]='must match [0-9A-Za-z_-]{1,32} or be empty'
                return 1
            fi
            ;;
        dump978_gain)
            if ! valid_dump978_gain "$value"; then
                APL_APPLY_ERRORS[$key]='must be a number in [0, 60]'
                return 1
            fi
            ;;
        *)
            APL_APPLY_ERRORS[$key]="no validator for type ${type:-<unknown>}"
            return 1
            ;;
    esac
    return 0
}

# Post-merge cross-key validation. Mirrors Go configspec.ValidateConsistency.
# Populates APL_APPLY_ERRORS on rejection.
_apl_feed_apply_validate_consistency() {
    local -n merged_ref="$1"
    local geo mlat lat lon alt

    geo="${merged_ref[GEO_CONFIGURED]:-}"
    mlat="${merged_ref[MLAT_ENABLED]:-}"
    lat="${merged_ref[LATITUDE]:-}"
    lon="${merged_ref[LONGITUDE]:-}"
    alt="${merged_ref[ALTITUDE]:-}"

    if [[ "$geo" == "true" ]]; then
        if [[ -z "$lat" ]]; then
            APL_APPLY_ERRORS[LATITUDE]="must be non-empty when GEO_CONFIGURED=true"
            return 1
        fi
        if [[ -z "$lon" ]]; then
            APL_APPLY_ERRORS[LONGITUDE]="must be non-empty when GEO_CONFIGURED=true"
            return 1
        fi
    fi

    if [[ "$mlat" == "true" ]]; then
        if [[ "$geo" != "true" ]]; then
            APL_APPLY_ERRORS[GEO_CONFIGURED]='must be "true" when MLAT_ENABLED=true (set LATITUDE/LONGITUDE first)'
            return 1
        fi
        if [[ -z "$lat" ]]; then
            APL_APPLY_ERRORS[LATITUDE]="must be non-empty when MLAT_ENABLED=true"
            return 1
        fi
        if [[ -z "$lon" ]]; then
            APL_APPLY_ERRORS[LONGITUDE]="must be non-empty when MLAT_ENABLED=true"
            return 1
        fi
        if [[ -z "$alt" ]]; then
            APL_APPLY_ERRORS[ALTITUDE]="must be non-empty when MLAT_ENABLED=true"
            return 1
        fi
    fi
    return 0
}

# Derive GEO_CONFIGURED from a merged LATITUDE/LONGITUDE pair. Both axes
# numerically zero (or empty) → false; anything else → true. Matches
# configure.sh's writer-side heuristic so a real equator/prime-meridian
# operator does not get false-classified as unconfigured.
_apl_feed_apply_derive_geo() {
    local lat="${1:-}" lon="${2:-}" lat_zero=1 lon_zero=1
    if [[ -z "$lat" ]] || awk -v V="$lat" 'BEGIN { exit !(V + 0 == 0) }'; then
        :
    else
        lat_zero=0
    fi
    if [[ -z "$lon" ]] || awk -v V="$lon" 'BEGIN { exit !(V + 0 == 0) }'; then
        :
    else
        lon_zero=0
    fi
    if (( lat_zero == 1 && lon_zero == 1 )); then
        printf 'false'
    else
        printf 'true'
    fi
}

# Read feed.env into an associative array. Tolerates KEY=value,
# KEY="value", KEY='value'. Skips comments + blank lines. The order of
# first-occurrence is captured into APL_APPLY_KEY_ORDER for stable writes
# when the same key reappears.
_apl_feed_apply_read() {
    local feed_env="$1"
    local -n out_ref="$2"

    APL_APPLY_KEY_ORDER=()
    out_ref=()

    [[ -f "$feed_env" ]] || return 0

    # Strict line shapes accepted (mirrors Go apply-config's keyLine):
    #   KEY=value                  (bare value runs to end of line; no `#` comment splitting)
    #   KEY="value"                (double-quoted; trailing whitespace tolerated)
    #   KEY='value'                (single-quoted; trailing whitespace tolerated)
    # Anything else (mid-line `#`, unterminated quote, malformed key) is
    # silently dropped so the merged map cannot inherit a corrupt state.
    local line raw_key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            raw_key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        else
            continue
        fi
        # Quote handling: only accept genuinely-terminated quoted forms.
        # An unterminated `"foo` or `'foo` is dropped rather than treated
        # as a bare value (which would silently swallow the wrong byte).
        if [[ "${value:0:1}" == '"' ]]; then
            if [[ "$value" =~ ^\"(([^\"\\\\]|\\\\.)*)\"[[:space:]]*$ ]]; then
                value="${BASH_REMATCH[1]}"
                value="${value//\\\\/$'\x01'}"
                value="${value//\\\"/\"}"
                value="${value//\\\$/\$}"
                value="${value//\\\`/\`}"
                value="${value//$'\x01'/\\}"
            else
                continue
            fi
        elif [[ "${value:0:1}" == "'" ]]; then
            if [[ "$value" =~ ^\'([^\']*)\'[[:space:]]*$ ]]; then
                value="${BASH_REMATCH[1]}"
            else
                continue
            fi
        else
            # Bare value: trim trailing whitespace; refuse a mid-line `#`
            # (Go also treats `KEY=auto # note` as a malformed line, not
            # `auto`).
            value="${value%"${value##*[![:space:]]}"}"
            [[ "$value" == *' #'* || "$value" == *$'\t#'* ]] && continue
        fi

        if [[ -z "${out_ref[$raw_key]+set}" ]]; then
            APL_APPLY_KEY_ORDER+=("$raw_key")
        fi
        out_ref[$raw_key]="$value"
    done < "$feed_env"
}

# Write the merged map back to feed.env. Preserves first-occurrence order
# for keys present in the source file; appends new keys in registry order.
_apl_feed_apply_write() {
    local feed_env="$1"
    local -n merged_ref="$2"

    local dir tmp
    dir="$(dirname "$feed_env")"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "${feed_env}.XXXXXX")" || return 1

    {
        local key escaped
        # Emit in source order first.
        local -A emitted=()
        for key in "${APL_APPLY_KEY_ORDER[@]}"; do
            if [[ -n "${merged_ref[$key]+set}" ]]; then
                escaped="${merged_ref[$key]//\\/\\\\}"
                escaped="${escaped//\$/\\\$}"
                escaped="${escaped//\`/\\\`}"
                escaped="${escaped//\"/\\\"}"
                printf '%s="%s"\n' "$key" "$escaped"
                emitted[$key]=1
            fi
        done
        # Emit any newly-introduced writable keys in registry order.
        for key in "${APL_FEED_WRITABLE_KEYS[@]}"; do
            [[ -n "${emitted[$key]+x}" ]] && continue
            [[ -z "${merged_ref[$key]+set}" ]] && continue
            escaped="${merged_ref[$key]//\\/\\\\}"
            escaped="${escaped//\$/\\\$}"
            escaped="${escaped//\`/\\\`}"
            escaped="${escaped//\"/\\\"}"
            printf '%s="%s"\n' "$key" "$escaped"
        done
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    if [[ -f "$feed_env" ]]; then
        chmod --reference="$feed_env" "$tmp" 2>/dev/null || chmod 0644 "$tmp" || true
        chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    else
        chmod 0644 "$tmp" 2>/dev/null || true
    fi

    mv -f "$tmp" "$feed_env" || { rm -f "$tmp"; return 1; }
    return 0
}

# Compute the dirty-key set and the union of services that must restart.
_apl_feed_apply_restart_set() {
    local -n changed_ref="$1"
    # shellcheck disable=SC2178  # out_ref is an array nameref; shellcheck does not always understand `-n` on arrays
    local -n out_ref="$2"

    local -A seen=()
    local key svc
    for key in "${changed_ref[@]}"; do
        for svc in ${APL_FEED_KEY_RESTART[$key]:-}; do
            [[ -z "$svc" ]] && continue
            if [[ -z "${seen[$svc]+x}" ]]; then
                seen[$svc]=1
                out_ref+=("$svc")
            fi
        done
    done
}

# systemctl restart with build-mode / non-root skip. Sets
# APL_APPLY_PENDING_RESTART to the services that failed.
#
# A unit that doesn't exist (image-only daemons like dump978-fa on a
# standalone-feed install) is silently skipped — that matches the
# pre-refactor _uat_unit_exists gate. The library does not consider
# absent-unit cases a failure.
_apl_feed_apply_restart_services() {
    local services=("$@")
    APL_APPLY_PENDING_RESTART=()
    (( ${#services[@]} == 0 )) && return 0

    if _apl_feed_apply_is_build_mode; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    local svc
    for svc in "${services[@]}"; do
        # Skip units that aren't installed. `systemctl cat` returns 0 iff
        # the unit (or a generator-emitted instance) is known to systemd.
        if ! systemctl cat "$svc" >/dev/null 2>&1; then
            continue
        fi
        if ! systemctl restart "$svc" 2>/dev/null; then
            APL_APPLY_PENDING_RESTART+=("$svc")
        fi
    done
    (( ${#APL_APPLY_PENDING_RESTART[@]} == 0 ))
}

# ALTITUDE canonicalization: ensure an explicit `m`/`ft` suffix on disk.
# Mirrors Go configspec.Canonicalize. Validate must succeed first.
_apl_feed_apply_canonicalize_altitude() {
    local v="$1"
    case "$v" in
        *m) printf '%s' "$v" ;;
        *ft) printf '%s' "$v" ;;
        *) printf '%sm' "$v" ;;
    esac
}

# Predicate: returns 0 if the given key is one of the sidecar-tracked keys.
_apl_feed_apply_is_tracked_key() {
    local needle="$1" k
    for k in "${APL_FEED_APPLY_META_TRACKED_KEYS[@]}"; do
        [[ "$k" == "$needle" ]] && return 0
    done
    return 1
}

# Emit current time in the RFC 3339 UTC shape the sidecar requires.
# Microsecond precision so two writes within the same wall-clock-second
# produce distinct stamps that the LWW gate can order. The feeder runs
# on Linux Pi (GNU date, %N supported); on BSD date (macOS dev machines)
# %N is not interpreted and the fallback emits .000000Z so the strict
# fractional regex in the JSON adapter still matches.
_apl_feed_apply_iso_now() {
    local s
    s="$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)"
    if [[ ! "$s" =~ \.[0-9]{1,9}Z$ ]]; then
        s="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
    fi
    printf '%s' "$s"
}

# Normalize an RFC 3339 UTC timestamp into a fixed-width form so byte-wise
# (lexicographic) comparison matches semantic ordering. Accepted on-wire
# shapes are YYYY-MM-DDTHH:MM:SSZ (zero fractional) and
# YYYY-MM-DDTHH:MM:SS.<frac>Z (any fractional precision). The normalized
# form is always YYYY-MM-DDTHH:MM:SS.<6 digits>Z (microsecond precision,
# zero-padded if absent, truncated if longer) so callers can compare
# returned strings with `[[ A > B ]]` and get the right answer for
# sub-second differences.
#
# Microsecond precision matches the server-side merge in
# accounts/services/feeder_config.py (Python's datetime.now() emits
# microseconds via isoformat()) so the same-second tie semantics behave
# symmetrically across the round trip.
_apl_feed_apply_normalize_iso_for_compare() {
    local s="$1"
    s="${s%Z}"
    local base="$s" frac=""
    if [[ "$s" == *.* ]]; then
        base="${s%.*}"
        frac="${s##*.}"
    fi
    # Pad to 6 digits (microsecond); truncate longer (e.g. nanosecond) input.
    frac="${frac}000000"
    frac="${frac:0:6}"
    printf '%s.%sZ' "$base" "$frac"
}

# Maximum acceptable lead an on-disk `edited_at` can have over server-now
# before the LWW gate treats the on-disk stamp as bogus and lets the
# incoming server tuple heal it. Mirrors the server-side CLOCK_SKEW_MAX
# (accounts/services/feeder_config.py) so a feeder whose clock was set
# wildly forward can recover via the next sync cycle once NTP corrects.
APL_FEED_APPLY_LWW_FUTURE_SKEW_SECONDS="${APL_FEED_APPLY_LWW_FUTURE_SKEW_SECONDS:-300}"

# Emit `now + N seconds` in the same RFC 3339 UTC shape as
# _apl_feed_apply_iso_now. Falls back to plain `now()` when the host's
# `date` does not support GNU's `-d` flag (e.g. BSD date on a macOS dev
# box). The fallback effectively disables the bogus-future heal path on
# that host — acceptable; production runs on Linux where -d works.
_apl_feed_apply_iso_plus_seconds() {
    local secs="$1"
    date -u -d "+${secs} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || _apl_feed_apply_iso_now
}

# Read feed.meta.json into two parallel assoc arrays passed by nameref.
# Missing file → empty maps, no warning. Wrong schema_version or malformed
# JSON → empty maps + APL_APPLY_PENDING_META_WARNING set (the next write
# will overwrite the file fresh). Per-entry validation drops entries whose
# shape doesn't match the canonical (object with edited_at/edited_by,
# edited_by in enum, edited_at matching RFC 3339 regex).
_apl_feed_apply_read_meta() {
    local meta_path="$1"
    local -n at_ref="$2"
    local -n by_ref="$3"
    at_ref=()
    by_ref=()
    [[ -f "$meta_path" ]] || return 0
    local schema_ok
    if ! schema_ok="$(jq -r '
        if (type == "object") and (.schema_version == 1) and (.fields | type == "object")
        then "ok" else "schema_mismatch" end' "$meta_path" 2>/dev/null)"; then
        APL_APPLY_PENDING_META_WARNING="existing feed.meta.json is unreadable; rewriting fresh"
        return 0
    fi
    if [[ "$schema_ok" != "ok" ]]; then
        APL_APPLY_PENDING_META_WARNING="existing feed.meta.json has unexpected schema; rewriting fresh"
        return 0
    fi
    local entries
    if ! entries="$(jq -r '
        .fields | to_entries[] |
        select(.value | type == "object") |
        select(.value.edited_at | type == "string") |
        select(.value.edited_by | type == "string") |
        "\(.key)\t\(.value.edited_at)\t\(.value.edited_by)"' "$meta_path" 2>/dev/null)"; then
        APL_APPLY_PENDING_META_WARNING="existing feed.meta.json fields unreadable; rewriting fresh"
        return 0
    fi
    local key at by
    while IFS=$'\t' read -r key at by; do
        [[ -z "$key" ]] && continue
        _apl_feed_apply_is_tracked_key "$key" || continue
        case " $APL_FEED_APPLY_EDITED_BY_ENUM " in
            *" $by "*) ;;
            *) continue ;;
        esac
        [[ "$at" =~ $APL_FEED_APPLY_EDITED_AT_RE ]] || continue
        at_ref[$key]="$at"
        by_ref[$key]="$by"
    done <<< "$entries"
}

# Atomic write of feed.meta.json from two parallel assoc arrays passed by
# nameref. Mode 0664 so the airplanes-feed group can update metadata
# without sudo (the sync CLI in a future story relies on this). Owner is
# inherited from feed.env via chown --reference.
_apl_feed_apply_write_meta() {
    local meta_path="$1"
    local feed_env_for_owner="$2"
    # shellcheck disable=SC2178  # at_ref/by_ref are array namerefs; shellcheck doesn't always recognise `-n` on arrays
    local -n at_ref="$3"
    # shellcheck disable=SC2178
    local -n by_ref="$4"

    local dir tmp
    dir="$(dirname "$meta_path")"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "${meta_path}.XXXXXX")" || return 1

    # Build via two parallel --arg streams so the bash values pass through
    # jq's string escaping without any extra-quote hazards.
    local jq_args=() key i=0
    for key in "${APL_FEED_APPLY_META_TRACKED_KEYS[@]}"; do
        [[ -z "${at_ref[$key]+set}" ]] && continue
        jq_args+=(--arg "k${i}" "$key" --arg "a${i}" "${at_ref[$key]}" --arg "b${i}" "${by_ref[$key]}")
        i=$((i + 1))
    done
    local filter='{schema_version: 1, fields: {}}'
    local j
    for (( j = 0; j < i; j++ )); do
        filter+=" | .fields[\$k${j}] = {edited_at: \$a${j}, edited_by: \$b${j}}"
    done
    if ! jq -nc "${jq_args[@]}" "$filter" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if [[ -f "$feed_env_for_owner" ]]; then
        chown --reference="$feed_env_for_owner" "$tmp" 2>/dev/null || true
    fi
    chmod 0664 "$tmp" 2>/dev/null || true
    # Refuse if the target somehow exists as a directory — `mv -f tmp dir`
    # would silently move tmp INTO dir on GNU coreutils, leaving the
    # expected file path absent and the directory accumulating tmp.XXXXXX
    # entries. Caller treats this as a sidecar-write failure.
    if [[ -d "$meta_path" ]]; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$meta_path" || { rm -f "$tmp"; return 1; }
    return 0
}

# Emit the sidecar-write warning (if any) to stderr. Non-JSON CLI callers
# call this after their normal result line so operators see when a save
# updated feed.env but not feed.meta.json.
apl_feed_apply_emit_meta_warning() {
    [[ -n "${APL_APPLY_PENDING_META_WARNING:-}" ]] || return 0
    printf 'warning: %s\n' "$APL_APPLY_PENDING_META_WARNING" >&2
}

# Reset the result globals to a clean slate. Inputs (APL_APPLY_INCOMING_META_*)
# are NOT cleared here — they are owned by the caller.
_apl_feed_apply_reset_state() {
    APL_APPLY_STATUS=""
    APL_APPLY_CHANGED=()
    APL_APPLY_PENDING_RESTART=()
    APL_APPLY_SKIPPED_BY_LWW=()
    APL_APPLY_PENDING_META_WARNING=""
    APL_APPLY_ERROR_MESSAGE=""
    declare -gA APL_APPLY_ERRORS=()
}

# Public entry. See header comment for the contract.
#
# Usage:
#   apl_feed_apply [--no-restart] [--create-if-missing]
#                  [--lock-timeout SECS]
#                  [--feed-env PATH] [--lock-file PATH]
#                  [--meta-file PATH]
#                  KEY=value [KEY=value ...]
#
# --create-if-missing: create feed.env inside the apply lock when it
# doesn't yet exist. Without this flag, a missing file returns
# filesystem_error. Used by apl_feed_import_legacy_config to make the
# bootstrap atomic (no read-then-create race between two concurrent
# writers).
#
# --meta-file: override the sidecar path (default: dirname(feed_env) +
# /feed.meta.json). Sidecar tracks per-write (edited_at, edited_by) for
# the keys in APL_FEED_APPLY_META_TRACKED_KEYS. To stamp metadata on a
# write, the caller pre-populates APL_APPLY_INCOMING_META_EDITED_AT[$key]
# and APL_APPLY_INCOMING_META_EDITED_BY[$key] before invoking; bare-string
# writes default to edited_by=feeder, edited_at=now() for tracked keys.
apl_feed_apply() {
    _apl_feed_apply_reset_state

    local feed_env="$APL_FEED_APPLY_FEED_ENV_DEFAULT"
    local lock_path="$APL_FEED_APPLY_LOCK_DEFAULT"
    local lock_timeout="$APL_FEED_APPLY_LOCK_TIMEOUT_DEFAULT"
    local meta_path=""
    local skip_restart=0
    local skip_audit=0
    local create_if_missing=0
    local explicit_geo_in_payload=0
    local touched_lat=0 touched_lon=0
    local -A payload=()
    local -A merged=()
    local key value pair

    # Snapshot caller-supplied metadata into locals so result-state resets
    # at function entry cannot lose them, and so a caller mid-flight (in
    # the same shell) cannot mutate them between validation and write.
    local -A _meta_in_at=()
    local -A _meta_in_by=()
    local _meta_in_key
    for _meta_in_key in "${!APL_APPLY_INCOMING_META_EDITED_AT[@]}"; do
        _meta_in_at[$_meta_in_key]="${APL_APPLY_INCOMING_META_EDITED_AT[$_meta_in_key]}"
    done
    for _meta_in_key in "${!APL_APPLY_INCOMING_META_EDITED_BY[@]}"; do
        _meta_in_by[$_meta_in_key]="${APL_APPLY_INCOMING_META_EDITED_BY[$_meta_in_key]}"
    done

    while (( $# > 0 )); do
        case "$1" in
            --no-restart)
                skip_restart=1
                shift
                ;;
            --no-audit)
                skip_audit=1
                shift
                ;;
            --create-if-missing)
                create_if_missing=1
                shift
                ;;
            --lock-timeout)
                [[ $# -ge 2 ]] || {
                    APL_APPLY_STATUS=usage_error
                    APL_APPLY_ERROR_MESSAGE="--lock-timeout requires SECS"
                    return 5
                }
                lock_timeout="$2"
                shift 2
                ;;
            --feed-env)
                [[ $# -ge 2 ]] || {
                    APL_APPLY_STATUS=usage_error
                    APL_APPLY_ERROR_MESSAGE="--feed-env requires PATH"
                    return 5
                }
                feed_env="$2"
                shift 2
                ;;
            --lock-file)
                [[ $# -ge 2 ]] || {
                    APL_APPLY_STATUS=usage_error
                    APL_APPLY_ERROR_MESSAGE="--lock-file requires PATH"
                    return 5
                }
                lock_path="$2"
                shift 2
                ;;
            --meta-file)
                [[ $# -ge 2 ]] || {
                    APL_APPLY_STATUS=usage_error
                    APL_APPLY_ERROR_MESSAGE="--meta-file requires PATH"
                    return 5
                }
                meta_path="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                APL_APPLY_STATUS=usage_error
                APL_APPLY_ERROR_MESSAGE="unknown flag: $1"
                return 5
                ;;
            *)
                break
                ;;
        esac
    done

    # Auto-derive meta_path from feed_env's directory if --meta-file wasn't
    # passed. Keeps `apl-feed apply --root /alt/path/ ...` from accidentally
    # touching the host's /etc/airplanes/feed.meta.json.
    if [[ -z "$meta_path" ]]; then
        meta_path="$(dirname "$feed_env")/$APL_FEED_APPLY_META_BASENAME"
    fi

    # Validate caller-supplied metadata against the tracked-keys list, the
    # edited_by enum, and the RFC 3339 edited_at shape. Fail fast — before
    # any lock or filesystem work.
    local _meta_check_key
    for _meta_check_key in "${!_meta_in_by[@]}"; do
        if ! _apl_feed_apply_is_tracked_key "$_meta_check_key"; then
            APL_APPLY_ERRORS[$_meta_check_key]="metadata not supported for this key"
            APL_APPLY_STATUS=rejected
            return 2
        fi
        case " $APL_FEED_APPLY_EDITED_BY_ENUM " in
            *" ${_meta_in_by[$_meta_check_key]} "*) ;;
            *)
                APL_APPLY_ERRORS[$_meta_check_key]="edited_by must be one of: $APL_FEED_APPLY_EDITED_BY_ENUM"
                APL_APPLY_STATUS=rejected
                return 2
                ;;
        esac
        if ! [[ "${_meta_in_at[$_meta_check_key]:-}" =~ $APL_FEED_APPLY_EDITED_AT_RE ]]; then
            APL_APPLY_ERRORS[$_meta_check_key]="edited_at must be RFC 3339 UTC (YYYY-MM-DDTHH:MM:SS[.fff]Z)"
            APL_APPLY_STATUS=rejected
            return 2
        fi
    done

    # Parse KEY=value pairs.
    while (( $# > 0 )); do
        pair="$1"
        if [[ "$pair" != *=* ]]; then
            APL_APPLY_STATUS=usage_error
            APL_APPLY_ERROR_MESSAGE="not a KEY=value pair: $pair"
            return 5
        fi
        key="${pair%%=*}"
        value="${pair#*=}"

        if ! apl_feed_is_writable_key "$key"; then
            APL_APPLY_ERRORS[$key]="not a writable key"
            APL_APPLY_STATUS=rejected
            return 2
        fi
        payload[$key]="$value"
        case "$key" in
            LATITUDE) touched_lat=1 ;;
            LONGITUDE) touched_lon=1 ;;
            GEO_CONFIGURED) explicit_geo_in_payload=1 ;;
        esac
        shift
    done

    if (( ${#payload[@]} == 0 )); then
        # An empty payload with stale incoming metadata is suspicious — a
        # caller using the lib directly may have forgotten to clear the
        # globals between calls. Refuse rather than silently apply.
        if (( ${#_meta_in_by[@]} > 0 )); then
            local _stray
            for _stray in "${!_meta_in_by[@]}"; do
                APL_APPLY_ERRORS[$_stray]="incoming metadata refers to a key not in this payload"
                break
            done
            APL_APPLY_STATUS=rejected
            return 2
        fi
        APL_APPLY_STATUS=no_change
        return 0
    fi

    # Every key with explicit incoming metadata must also appear in the
    # payload — otherwise a stale global from a previous call could rewrite
    # the sidecar tuple for a key the caller never intended to touch.
    local _meta_payload_key
    for _meta_payload_key in "${!_meta_in_by[@]}"; do
        if [[ -z "${payload[$_meta_payload_key]+set}" ]]; then
            APL_APPLY_ERRORS[$_meta_payload_key]="incoming metadata refers to a key not in this payload"
            APL_APPLY_STATUS=rejected
            return 2
        fi
    done

    # Per-key validation on the payload values themselves.
    for key in "${!payload[@]}"; do
        if ! _apl_feed_apply_validate_one "$key" "${payload[$key]}"; then
            APL_APPLY_STATUS=rejected
            return 2
        fi
        # Canonicalize: ALTITUDE always carries an explicit `m`/`ft`
        # suffix on disk. Mirrors Go configspec.Canonicalize so a
        # webconfig-validated `120` and a CLI-validated `120` produce
        # the same on-disk byte sequence.
        if [[ "$key" == "ALTITUDE" ]]; then
            payload[$key]="$(_apl_feed_apply_canonicalize_altitude "${payload[$key]}")"
        fi
    done

    # Acquire lock (skipped in build mode where /run/airplanes/ may not exist).
    local lock_fd=""
    if ! _apl_feed_apply_is_build_mode; then
        mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true
        if ! command -v flock >/dev/null 2>&1; then
            APL_APPLY_STATUS=filesystem_error
            APL_APPLY_ERROR_MESSAGE="flock not installed"
            return 3
        fi
        exec {lock_fd}>"$lock_path" || {
            APL_APPLY_STATUS=filesystem_error
            APL_APPLY_ERROR_MESSAGE="cannot open lock file $lock_path"
            return 3
        }
        if ! flock -w "$lock_timeout" "$lock_fd"; then
            APL_APPLY_STATUS=lock_timeout
            APL_APPLY_ERROR_MESSAGE="could not acquire lock after ${lock_timeout}s"
            eval "exec ${lock_fd}>&-"
            return 4
        fi
    fi

    # feed.env must exist. apl-feed apply does not bootstrap a fresh
    # config from a single-key POST — that would silently produce a
    # half-formed file. Matches Go apply-config's behavior of treating
    # a missing file as an internal error.
    #
    # The --create-if-missing flag opens a narrow exception for callers
    # that legitimately produce a fresh feed.env in a single locked
    # transaction (apl_feed_import_legacy_config). Creation happens HERE,
    # under the lock, so a concurrent writer that checks file existence
    # cannot see a half-formed canonical file as the bootstrap signal.
    if [[ ! -f "$feed_env" ]]; then
        if (( create_if_missing )); then
            mkdir -p "$(dirname "$feed_env")" 2>/dev/null || true
            if ! : > "$feed_env" 2>/dev/null; then
                APL_APPLY_STATUS=filesystem_error
                APL_APPLY_ERROR_MESSAGE="cannot create feed.env at $feed_env"
                [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
                return 3
            fi
        else
            APL_APPLY_STATUS=filesystem_error
            APL_APPLY_ERROR_MESSAGE="feed.env not found at $feed_env; run setup first"
            [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
            return 3
        fi
    fi

    # Read current feed.env into merged, then overlay payload.
    if ! _apl_feed_apply_read "$feed_env" merged; then
        APL_APPLY_STATUS=filesystem_error
        APL_APPLY_ERROR_MESSAGE="cannot read feed.env at $feed_env"
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        return 3
    fi

    # Re-scan every preserved value through universal-reject. If a
    # hand-edited feed.env contains a forbidden byte, the per-key payload
    # validation would have left it untouched; without this check, the
    # rewriter would re-emit it verbatim and bake it into the new file.
    local pk
    for pk in "${!merged[@]}"; do
        if ! _apl_feed_apply_universal_reject "${merged[$pk]}"; then
            APL_APPLY_ERRORS[$pk]="existing on-disk value contains a forbidden character; edit feed.env by hand"
            APL_APPLY_STATUS=rejected
            [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
            return 2
        fi
    done

    # Read the sidecar once under the lock. Used by both the LWW gate
    # below AND the sidecar-write block at the bottom of this function.
    # Reading inside the lock avoids racing a concurrent writer between
    # snapshot and apply. Missing/corrupt file -> empty maps (lib helper
    # already sets APL_APPLY_PENDING_META_WARNING when relevant).
    local -A existing_at=() existing_by=()
    _apl_feed_apply_read_meta "$meta_path" existing_at existing_by

    # Per-key LWW gate. Any payload entry whose incoming `edited_at` is
    # NOT strictly newer than the on-disk `edited_at` is dropped from
    # this write. The skip is per-key: other entries in the same call
    # apply normally. Bare-string payloads (no incoming metadata) bypass
    # the gate so the existing operator-facing CLIs (mlat user, 978, etc.)
    # are unaffected — those callers don't pass metadata, the lib stamps
    # `now()` on their behalf, and `now()` always wins by definition.
    #
    # Symmetric with the server-side LWW (accounts/services/feeder_config.py):
    # both sides favor the existing tuple on exact-edited_at equality. The
    # data converges via whichever side has the strictly-newer edit.
    #
    # Bogus-future-heal: an on-disk `edited_at` more than
    # APL_FEED_APPLY_LWW_FUTURE_SKEW_SECONDS ahead of server-now is
    # treated as invalid — the gate is bypassed for that key so the
    # incoming server tuple can heal it. Mirrors the server-side
    # clock-skew rejection that produced the heal payload in the first
    # place (rejected_fields response from /api/feeders/config/sync).
    local _lww_key _on_disk _incoming _on_disk_n _incoming_n _now_skew_n
    # Bogus-future-heal reference: prefer the caller-supplied server time
    # over the local clock so a feeder with a fast NTP offset cannot mark
    # its own already-corrupt metadata as legitimately newer than the
    # server response and re-skip the heal indefinitely. Empty
    # APL_APPLY_INCOMING_SERVER_TIME (most callers) falls back to local
    # now() — matches the previous behavior for non-sync writers.
    local _now_ref
    if [[ -n "$APL_APPLY_INCOMING_SERVER_TIME" \
        && "$APL_APPLY_INCOMING_SERVER_TIME" =~ $APL_FEED_APPLY_EDITED_AT_RE ]]; then
        _now_ref="$APL_APPLY_INCOMING_SERVER_TIME"
    else
        _now_ref="$(_apl_feed_apply_iso_plus_seconds 0)"
    fi
    # Compute "_now_ref + CLOCK_SKEW_MAX" by re-using iso_plus_seconds for
    # the local-now path and accepting the trade-off that a server-time
    # path adds the skew by string-extension (we'd need a date -d that
    # parses ISO 8601 reliably). For server-time, normalize then bolt on
    # the skew by re-rendering through GNU date.
    if [[ -n "$APL_APPLY_INCOMING_SERVER_TIME" \
        && "$APL_APPLY_INCOMING_SERVER_TIME" =~ $APL_FEED_APPLY_EDITED_AT_RE ]]; then
        _now_skew_n="$(date -u -d "$_now_ref +${APL_FEED_APPLY_LWW_FUTURE_SKEW_SECONDS} seconds" \
            +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || _apl_feed_apply_iso_plus_seconds "$APL_FEED_APPLY_LWW_FUTURE_SKEW_SECONDS")"
        _now_skew_n="$(_apl_feed_apply_normalize_iso_for_compare "$_now_skew_n")"
    else
        _now_skew_n="$(_apl_feed_apply_normalize_iso_for_compare \
            "$(_apl_feed_apply_iso_plus_seconds \
                "$APL_FEED_APPLY_LWW_FUTURE_SKEW_SECONDS")")"
    fi
    for _lww_key in "${!_meta_in_at[@]}"; do
        # Only gate keys actually in the payload — `_meta_in_at` may
        # contain stray entries already rejected by the payload-coverage
        # check above (defensive; that path returns early).
        [[ -n "${payload[$_lww_key]+set}" ]] || continue
        _on_disk="${existing_at[$_lww_key]:-}"
        # No on-disk metadata for this key => bootstrap case. Incoming
        # tuple wins unconditionally.
        [[ -n "$_on_disk" ]] || continue
        _incoming="${_meta_in_at[$_lww_key]}"
        _on_disk_n="$(_apl_feed_apply_normalize_iso_for_compare "$_on_disk")"
        _incoming_n="$(_apl_feed_apply_normalize_iso_for_compare "$_incoming")"
        # On-disk stamp wildly in the future -> bogus. Bypass the gate
        # and let the incoming tuple heal the bad metadata.
        if [[ "$_on_disk_n" > "$_now_skew_n" ]]; then
            continue
        fi
        # `[[ A > B ]]` is a string compare under shopt -o noglob default.
        # The normalized form is fixed-width lexicographically sortable.
        if [[ ! "$_incoming_n" > "$_on_disk_n" ]]; then
            APL_APPLY_SKIPPED_BY_LWW+=("$_lww_key")
            unset 'payload[$_lww_key]'
            unset '_meta_in_at[$_lww_key]'
            unset '_meta_in_by[$_lww_key]'
        fi
    done

    # If every incoming key was LWW-skipped the call resolves to no_change.
    # Mirrors the pre-lock empty-payload check, but runs after the gate
    # has had a chance to drop entries.
    if (( ${#payload[@]} == 0 )); then
        APL_APPLY_STATUS=no_change
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        return 0
    fi

    APL_APPLY_CHANGED=()
    for key in "${!payload[@]}"; do
        value="${payload[$key]}"
        if [[ -z "${merged[$key]+set}" || "${merged[$key]}" != "$value" ]]; then
            APL_APPLY_CHANGED+=("$key")
            merged[$key]="$value"
        fi
    done

    # Auto-derive GEO_CONFIGURED when the caller touched a coordinate axis
    # but did not set the flag explicitly. Matches Go
    # configspec.ApplyGeoDeriveOnUpdate. ALTITUDE is intentionally not a
    # trigger — altitude-only edits must not flip explicit geo intent.
    if (( explicit_geo_in_payload == 0 )) && (( touched_lat == 1 || touched_lon == 1 )); then
        if [[ -n "${merged[LATITUDE]+set}" && -n "${merged[LONGITUDE]+set}" ]]; then
            local derived
            derived="$(_apl_feed_apply_derive_geo "${merged[LATITUDE]}" "${merged[LONGITUDE]}")"
            if [[ "${merged[GEO_CONFIGURED]:-}" != "$derived" ]]; then
                merged[GEO_CONFIGURED]="$derived"
                # Mark as changed if not already in the list.
                local already_changed=0 ck
                for ck in "${APL_APPLY_CHANGED[@]}"; do
                    [[ "$ck" == "GEO_CONFIGURED" ]] && already_changed=1
                done
                (( already_changed == 0 )) && APL_APPLY_CHANGED+=("GEO_CONFIGURED")
            fi
        fi
    fi

    # Cross-key consistency on the merged state.
    if ! _apl_feed_apply_validate_consistency merged; then
        APL_APPLY_STATUS=rejected
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        return 2
    fi

    # Build the set of tracked keys that need a sidecar refresh:
    #   (a) tracked keys whose canonical value just changed, OR
    #   (b) tracked keys with explicit incoming metadata (object-form
    #       payloads always reconcile, even when the canonical value
    #       matched on-disk — this is how a feeder with a corrupt-future
    #       edited_at gets its metadata replaced by the server's tuple).
    local -a sidecar_keys=()
    local sk_check
    for sk_check in "${APL_APPLY_CHANGED[@]}"; do
        _apl_feed_apply_is_tracked_key "$sk_check" && sidecar_keys+=("$sk_check")
    done
    for sk_check in "${!_meta_in_by[@]}"; do
        local _already=0 _sk
        for _sk in "${sidecar_keys[@]}"; do [[ "$_sk" == "$sk_check" ]] && _already=1; done
        (( _already == 0 )) && sidecar_keys+=("$sk_check")
    done

    if (( ${#APL_APPLY_CHANGED[@]} == 0 && ${#sidecar_keys[@]} == 0 )); then
        APL_APPLY_STATUS=no_change
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        return 0
    fi

    # Write feed.env atomically only when canonical values actually changed.
    # An object-form payload whose value matched on-disk reaches this point
    # with APL_APPLY_CHANGED empty but sidecar_keys non-empty — the sidecar
    # block below still runs.
    if (( ${#APL_APPLY_CHANGED[@]} > 0 )); then
        if ! _apl_feed_apply_write "$feed_env" merged; then
            APL_APPLY_STATUS=filesystem_error
            APL_APPLY_ERROR_MESSAGE="atomic write to $feed_env failed"
            [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
            return 3
        fi
    fi

    # Sidecar write — same lock as feed.env. Skipped in build mode (where
    # lock_fd is empty because /run/airplanes/ may not exist). feed.env was
    # already renamed by this point; on sidecar failure we log a warning
    # but do NOT roll back feed.env — the daemon source of truth must not
    # be held hostage by an informational sidecar. The next metadata-bearing
    # write reconciles.
    if (( ${#sidecar_keys[@]} > 0 )) && [[ -n "$lock_fd" ]]; then
        # `existing_at` / `existing_by` were already populated under the
        # same lock above (used for the LWW gate). Reuse them here rather
        # than re-reading the sidecar.
        local -A merged_at=() merged_by=()
        local mk
        for mk in "${!existing_at[@]}"; do
            merged_at[$mk]="${existing_at[$mk]}"
            merged_by[$mk]="${existing_by[$mk]}"
        done

        local now_iso
        now_iso="$(_apl_feed_apply_iso_now)"
        local ck
        for ck in "${sidecar_keys[@]}"; do
            if [[ -n "${_meta_in_by[$ck]+set}" ]]; then
                merged_at[$ck]="${_meta_in_at[$ck]}"
                merged_by[$ck]="${_meta_in_by[$ck]}"
            else
                merged_at[$ck]="$now_iso"
                merged_by[$ck]="feeder"
            fi
        done

        if ! _apl_feed_apply_write_meta "$meta_path" "$feed_env" merged_at merged_by; then
            if (( ${#APL_APPLY_CHANGED[@]} > 0 )); then
                APL_APPLY_PENDING_META_WARNING="sidecar write failed; feed.env updated, feed.meta.json stale"
            else
                # Metadata-only reconciliation path: feed.env was not touched,
                # so the warning should not claim otherwise.
                APL_APPLY_PENDING_META_WARNING="sidecar write failed; feed.meta.json could not be updated"
            fi
        fi
    fi

    # Release lock before service restarts so a slow systemctl call cannot
    # block subsequent writers. The audit log fires after release for the
    # same reason — a stuck logger(1) must not hold up other writers.
    [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"

    # Best-effort journald audit. The feeder owner is the only journalctl
    # reader on a normal Pi install; values are already in feed.env on disk.
    # Skipped in build mode (image chroot has no journald), when logger(1)
    # is missing, and when the caller passed --no-audit (e.g., scratch
    # rootfs invocations from tests; apply.sh sets this when ROOT != "/").
    # The redirect-or-true guard prevents a transient logger failure from
    # aborting the apply — the write already succeeded.
    if (( skip_audit == 0 )) \
        && ! _apl_feed_apply_is_build_mode \
        && command -v logger >/dev/null 2>&1 \
        && (( ${#APL_APPLY_CHANGED[@]} > 0 )); then
        local -a _audit_kvs=()
        local _audit_k
        for _audit_k in "${APL_APPLY_CHANGED[@]}"; do
            _audit_kvs+=("${_audit_k}=\"${merged[$_audit_k]}\"")
        done
        # Pin IFS for the array expansion: this lib is sourced and a
        # caller-mutated IFS could otherwise produce multi-line or
        # no-separator output. `local` scopes the override to the
        # function; the caller's IFS is restored on return.
        local IFS=' '
        logger -t apl-feed-apply -p user.info -- "applied: ${_audit_kvs[*]}" 2>/dev/null || true
    fi

    if (( skip_restart == 1 )); then
        APL_APPLY_STATUS=applied
        return 0
    fi

    local -a restart_set=()
    _apl_feed_apply_restart_set APL_APPLY_CHANGED restart_set
    _apl_feed_apply_restart_services "${restart_set[@]}" || true

    APL_APPLY_STATUS=applied
    return 0
}
