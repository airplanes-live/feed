#!/usr/bin/env bash

# `apl-feed config sync` — push the local feed.env snapshot to
# airplanes.live and apply the server's merged response. Invoked every
# ~60s by airplanes-config-sync.timer (with 30s jitter). Operators can
# trigger a one-shot run manually.
#
# Wire shape, gates, and merge semantics in
# https://github.com/airplanes-live/infrastructure/blob/main/contracts/docs/feeder-config-sync.md.
# Authentication is the standard Authorization: Bearer alv1.<uuid>.<secret> token. The
# library's metadata-LWW gate (APL_APPLY_INCOMING_META_*) protects this
# call site against a concurrent operator/webconfig write that lands
# between the snapshot read and the apply step.
#
# Exit codes (intentional minimal surface — mirrors
# airplanes-diagnostics.sh):
#   0   applied / no_change / unowned heartbeat / any transient or
#       recoverable failure (401, 423, 426, 429, 4xx body, 5xx,
#       network error). The structured log line carries the reason;
#       the operator reads journalctl -u airplanes-config-sync.
#   64  hard local config error — missing Feeder ID or claim secret,
#       broken installation. systemctl marks the unit failed so the
#       failure surfaces in `apl-feed status` and `systemctl status`.

# State writer/reader. config-sync publishes its own runtime state file (the
# same daemon-state pattern feed/mlat/diagnostics use) to record the server's
# ownership verdict and detect the unowned→owned claim edge. Defensive source:
# a missing lib (mid-update transient) degrades to no-op stubs rather than
# breaking the sync. BASH_SOURCE-relative so it resolves in both the source
# tree (scripts/apl-feed/.. -> scripts/lib) and the install layout.
_config_sync_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib"
if [[ -r "$_config_sync_lib_dir/state-writer.sh" ]]; then
    # shellcheck source=../lib/state-writer.sh
    source "$_config_sync_lib_dir/state-writer.sh"
else
    airplanes_write_state() { return 1; }
fi
if [[ -r "$_config_sync_lib_dir/state-reader.sh" ]]; then
    # shellcheck source=../lib/state-reader.sh
    source "$_config_sync_lib_dir/state-reader.sh"
else
    airplanes_read_state() { return 1; }
fi
unset _config_sync_lib_dir

# Legacy fallback tuple matches the migration in
# scripts/lib/update-migrations.sh:migrate_seed_feed_meta_json so a
# feeder whose sidecar is missing or corrupt converges to the server's
# state rather than forging fresh feeder-stamped tuples.
CONFIG_SYNC_LEGACY_EDITED_AT="2020-01-01T00:00:00Z"
CONFIG_SYNC_LEGACY_EDITED_BY="legacy"

CONFIG_SYNC_EXIT_OK=0
CONFIG_SYNC_EXIT_BAD_CONFIG=64

# parse_opt_in RAW
#   echoes one of: enabled, disabled, invalid, empty
#   Mirrors parse_report_status in airplanes-diagnostics.sh.
#   Callers map "empty" to disabled — REMOTE_CONFIG_ENABLED is opt-in,
#   so absence means "not consented" rather than "default on".
_config_sync_parse_opt_in() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        printf '%s' 'empty'
        return
    fi
    local lower
    lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    lower="${lower#"${lower%%[![:space:]]*}"}"
    lower="${lower%"${lower##*[![:space:]]}"}"
    case "$lower" in
        true|yes|1|on) printf '%s' 'enabled' ;;
        false|no|0|off) printf '%s' 'disabled' ;;
        *) printf '%s' 'invalid' ;;
    esac
}

# Sentinel mtime path. Overridable for tests + chroot smokes. Defaults to the
# unit's own StateDirectory (airplanes-config-sync.service:StateDirectory=),
# which systemd exports as $STATE_DIRECTORY at runtime so the path tracks the
# unit without drift; the literal fallback covers manual / chroot invocations
# where the unit env isn't present.
CONFIG_SYNC_LAST_SUCCESS_FILE="${AIRPLANES_CONFIG_SYNC_LAST_SUCCESS:-${STATE_DIRECTORY:-/var/lib/airplanes/config-sync}/config-sync-last-success}"

# Owned-state file (same StateDirectory, same override discipline as the
# sentinel). Holds the server's last ownership verdict so the unowned→owned
# claim edge can be detected across ticks. Persistent (not /run) so the edge
# fires only on an actual claim, not on every reboot.
CONFIG_SYNC_STATE_FILE="${AIRPLANES_CONFIG_SYNC_STATE:-${STATE_DIRECTORY:-/var/lib/airplanes/config-sync}/state}"

# Structured logger. Mirrors airplanes-diagnostics.sh's `log` so the two
# timers produce a uniform journal stream.
_config_sync_log() {
    local level="$1"
    shift
    printf 'apl-feed-config-sync level=%s %s host=%s\n' "$level" "$*" "$WEBSITE_HOST" >&2
}

# True if feed.env has a (non-comment) line matching `^[[:space:]]*KEY=`.
# Distinguishes "absent" (omit field from payload) from "present-empty"
# (emit tombstone where the schema accepts null).
_config_sync_has_key() {
    local feed_env="$1" key="$2"
    [[ -f "$feed_env" ]] || return 1
    grep -qE "^[[:space:]]*${key}=" "$feed_env" 2>/dev/null
}

# Normalize a feed.env bool ("true"/"yes"/"1"/"on" or "false"/"no"/"0"/
# "off") to the canonical "true"/"false" the API expects as a JSON bool.
# Returns 1 (and emits nothing) on unparseable / empty.
_config_sync_read_bool() {
    local raw="${1:-}"
    case "${raw,,}" in
        true|yes|1|on)
            printf 'true'
            return 0
            ;;
        false|no|0|off)
            printf 'false'
            return 0
            ;;
    esac
    return 1
}

# Load /etc/airplanes/feed.meta.json into per-key (edited_at, edited_by)
# associative arrays via nameref. Missing / corrupt / non-v1 schema all
# leave the maps empty without erroring — callers fall back to the
# legacy tuple per-key.
#
# Per-entry shape is filtered to enforce:
#   - edited_at matches the RFC 3339 UTC regex (mirrors the apply lib's
#     APL_FEED_APPLY_EDITED_AT_RE)
#   - edited_by ∈ {feeder, website, legacy}
# Invalid entries are dropped silently. The next call to apl_feed_apply
# overwrites the sidecar from clean state, so a one-off corrupt entry
# heals itself; meanwhile we never propagate the bad metadata to the
# server and stay out of a 400 validation_failed loop.
_config_sync_load_meta() {
    local meta_path="$1"
    local -n at_out="$2"
    local -n by_out="$3"
    at_out=()
    by_out=()
    [[ -f "$meta_path" ]] || return 0
    local entries
    if ! entries="$(jq -r '
        if (type == "object") and (.schema_version == 1) and (.fields | type == "object") then
            .fields | to_entries[] |
            select(.value | type == "object") |
            select(.value.edited_at | type == "string") |
            select(.value.edited_by | type == "string") |
            select(.value.edited_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$")) |
            select(.value.edited_by | IN("feeder", "website", "legacy")) |
            "\(.key)\t\(.value.edited_at)\t\(.value.edited_by)"
        else empty end
    ' "$meta_path" 2>/dev/null)"; then
        return 0
    fi
    local key at by
    while IFS=$'\t' read -r key at by; do
        [[ -z "$key" ]] && continue
        at_out[$key]="$at"
        by_out[$key]="$by"
    done <<< "$entries"
}

# Resolve per-field outgoing (edited_at, edited_by). Sets the
# top-level _PAY_AT_<key> / _PAY_BY_<key> locals in the caller's scope.
# Default falls back to the legacy tuple when the sidecar has no entry.
_config_sync_resolve_field_meta() {
    local key="$1"
    local fallback_by="${4:-$CONFIG_SYNC_LEGACY_EDITED_BY}"
    local -n at_map="$2"
    local -n by_map="$3"
    if [[ -n "${at_map[$key]+set}" ]]; then
        printf '%s\t%s' "${at_map[$key]}" "${by_map[$key]:-$fallback_by}"
    else
        printf '%s\t%s' "$CONFIG_SYNC_LEGACY_EDITED_AT" "$CONFIG_SYNC_LEGACY_EDITED_BY"
    fi
}

# Build the outgoing payload JSON. Reads feed.env + feed.meta.json and
# emits the body the API expects on stdout. Returns 0 on success, 1 on
# unrecoverable build error.
_config_sync_build_payload() {
    local feed_env="$1" meta_path="$2" feeder_time="$3"
    local -A meta_at=() meta_by=()
    _config_sync_load_meta "$meta_path" meta_at meta_by

    local lat lon alt mlat_user mlat_enabled mlat_private geo_configured
    lat="$(feed_env_get LATITUDE 2>/dev/null || true)"
    lon="$(feed_env_get LONGITUDE 2>/dev/null || true)"
    alt="$(feed_env_get ALTITUDE 2>/dev/null || true)"
    mlat_user="$(feed_env_get MLAT_USER 2>/dev/null || true)"
    mlat_enabled="$(feed_env_get MLAT_ENABLED 2>/dev/null || true)"
    mlat_private="$(feed_env_get MLAT_PRIVATE 2>/dev/null || true)"
    geo_configured="$(feed_env_get GEO_CONFIGURED 2>/dev/null || true)"

    # Position: tombstone unless GEO_CONFIGURED=true AND both axes
    # parse as numbers. Atomic-pair edited_at = min(lat.at, lon.at)
    # so a freshly-stamped axis doesn't promote a stale other-axis to
    # "newer than server."
    local position_value='null'
    local position_at="$CONFIG_SYNC_LEGACY_EDITED_AT"
    local position_by="$CONFIG_SYNC_LEGACY_EDITED_BY"
    local geo_lower="${geo_configured,,}"
    if [[ "$geo_lower" == "true" && -n "$lat" && -n "$lon" ]]; then
        local pos_candidate
        if pos_candidate="$(jq -nc \
            --arg lat "$lat" --arg lon "$lon" \
            '{lat: ($lat | tonumber), lon: ($lon | tonumber)}' 2>/dev/null)"; then
            position_value="$pos_candidate"
        fi
    fi
    local lat_at="${meta_at[LATITUDE]:-}"
    local lon_at="${meta_at[LONGITUDE]:-}"
    if [[ -n "$lat_at" && -n "$lon_at" ]]; then
        # Atomic-group edited_at = MAX of the two axes' stamps. apl_feed_apply
        # writes both axes in a single locked transaction with the same
        # stamp, so MIN and MAX are equal in the normal case. In the
        # divergent-stamps edge case (legacy seed + a partial hand-edit
        # that touched only one axis), MAX reflects when the position
        # *state* was last changed, not the older lagging stamp. The
        # symmetric LWW gate in _config_sync_apply_response uses MAX too.
        if [[ "$lat_at" > "$lon_at" ]]; then
            position_at="$lat_at"
        else
            position_at="$lon_at"
        fi
        # On-disk position is feeder-originated by definition (the only
        # path that mutates LAT/LON is operator-driven writes through
        # apl_feed_apply, all of which stamp edited_by=feeder when not
        # told otherwise). Force the wire value rather than echoing one
        # axis' stamp arbitrarily.
        position_by="feeder"
    elif [[ -n "$lat_at" ]]; then
        position_at="$lat_at"
        position_by="${meta_by[LATITUDE]:-feeder}"
    elif [[ -n "$lon_at" ]]; then
        position_at="$lon_at"
        position_by="${meta_by[LONGITUDE]:-feeder}"
    fi

    # Build via jq with per-field --arg streams so values pass through
    # JSON-safely. `--argjson position_value` lets us emit either the
    # object `{lat,lon}` or the literal `null` based on the variable.
    local filter='{schema_version: 1, feeder_time: $feeder_time, fields: {}}'
    local -a jq_args=(
        --arg feeder_time "$feeder_time"
        --argjson pos_value "$position_value"
        --arg pos_at "$position_at"
        --arg pos_by "$position_by"
    )
    filter+=' | .fields.position = {value: $pos_value, edited_at: $pos_at, edited_by: $pos_by}'

    # alt — nullable number (float metres). Operator/legacy disks may
    # carry either bare metres (post-migration) or a suffixed string
    # (pre-migration, or a hand-edit); altitude_to_bare_metres
    # canonicalizes both shapes to a clean numeric on the wire. An
    # unparseable on-disk value omits .fields.alt entirely and emits a
    # journal warning — emitting `null` would be a tombstone, and combined
    # with a fresh feeder-side edited_at could wipe a valid website value.
    if _config_sync_has_key "$feed_env" ALTITUDE; then
        local alt_at alt_by alt_meta
        alt_meta="$(_config_sync_resolve_field_meta ALTITUDE meta_at meta_by)"
        alt_at="${alt_meta%%$'\t'*}"
        alt_by="${alt_meta##*$'\t'}"
        if [[ -z "$alt" ]]; then
            jq_args+=(--arg alt_at "$alt_at" --arg alt_by "$alt_by")
            filter+=' | .fields.alt = {value: null, edited_at: $alt_at, edited_by: $alt_by}'
        else
            local alt_metres alt_rc=0
            alt_metres="$(altitude_to_bare_metres "$alt")" || alt_rc=$?
            if (( alt_rc != 0 )); then
                local _alt_truncated="${alt:0:32}"
                _alt_truncated="${_alt_truncated//\"/\\\"}"
                _config_sync_log warn "reason=alt_unparseable value=\"$_alt_truncated\""
            else
                jq_args+=(--arg alt_at "$alt_at" --arg alt_by "$alt_by" --arg alt_v "$alt_metres")
                filter+=' | .fields.alt = {value: ($alt_v | tonumber), edited_at: $alt_at, edited_by: $alt_by}'
            fi
        fi
    fi

    # mlat_user — nullable string.
    if _config_sync_has_key "$feed_env" MLAT_USER; then
        local mu_at mu_by mu_meta
        mu_meta="$(_config_sync_resolve_field_meta MLAT_USER meta_at meta_by)"
        mu_at="${mu_meta%%$'\t'*}"
        mu_by="${mu_meta##*$'\t'}"
        jq_args+=(--arg mu_at "$mu_at" --arg mu_by "$mu_by")
        if [[ -z "$mlat_user" ]]; then
            filter+=' | .fields.mlat_user = {value: null, edited_at: $mu_at, edited_by: $mu_by}'
        else
            jq_args+=(--arg mu_v "$mlat_user")
            filter+=' | .fields.mlat_user = {value: $mu_v, edited_at: $mu_at, edited_by: $mu_by}'
        fi
    fi

    # mlat_enabled — non-nullable bool. Omit the field entirely when
    # the key is absent or unparseable (the API rejects null booleans).
    if _config_sync_has_key "$feed_env" MLAT_ENABLED; then
        local me_norm
        if me_norm="$(_config_sync_read_bool "$mlat_enabled")"; then
            local me_at me_by me_meta
            me_meta="$(_config_sync_resolve_field_meta MLAT_ENABLED meta_at meta_by)"
            me_at="${me_meta%%$'\t'*}"
            me_by="${me_meta##*$'\t'}"
            jq_args+=(
                --argjson me_v "$me_norm"
                --arg me_at "$me_at"
                --arg me_by "$me_by"
            )
            filter+=' | .fields.mlat_enabled = {value: $me_v, edited_at: $me_at, edited_by: $me_by}'
        fi
    fi

    # mlat_private — non-nullable bool. Same omission rules as
    # mlat_enabled.
    if _config_sync_has_key "$feed_env" MLAT_PRIVATE; then
        local mp_norm
        if mp_norm="$(_config_sync_read_bool "$mlat_private")"; then
            local mp_at mp_by mp_meta
            mp_meta="$(_config_sync_resolve_field_meta MLAT_PRIVATE meta_at meta_by)"
            mp_at="${mp_meta%%$'\t'*}"
            mp_by="${mp_meta##*$'\t'}"
            jq_args+=(
                --argjson mp_v "$mp_norm"
                --arg mp_at "$mp_at"
                --arg mp_by "$mp_by"
            )
            filter+=' | .fields.mlat_private = {value: $mp_v, edited_at: $mp_at, edited_by: $mp_by}'
        fi
    fi

    jq -nc "${jq_args[@]}" "$filter"
}

# Update the success-mtime sentinel. Failure to touch is non-fatal —
# the next successful sync will retry. Path is taken straight from the
# AIRPLANES_CONFIG_SYNC_LAST_SUCCESS env var (or the production default);
# chroot / test callers override the env var rather than relying on
# --root translation so the sentinel lands exactly where they expect.
_config_sync_touch_sentinel() {
    local file="$CONFIG_SYNC_LAST_SUCCESS_FILE"
    local dir
    dir="$(dirname "$file")"
    mkdir -p "$dir" 2>/dev/null || true
    : > "$file" 2>/dev/null || true
}

# Nudge one diagnostics push (best-effort, non-blocking) so a just-claimed
# feeder's dashboard shows data within ~60s instead of waiting for the next
# 10-min diagnostics tick. Guards mirror the apply-side service-action skips:
# no host systemctl during chroot/--root or test runs, and respect the
# operator's --no-restart. The diagnostics oneshot self-gates on REPORT_STATUS,
# so a muted feeder makes this a harmless no-op.
_config_sync_trigger_diagnostics_push() {
    local skip_restart="$1"
    if (( skip_restart )) || [[ "${ROOT:-/}" != "/" ]]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    systemctl start --no-block airplanes-diagnostics.service 2>/dev/null \
        || _config_sync_log warn "reason=diagnostics_trigger_failed"
    return 0
}

# Record the server's ownership verdict to the config-sync state file and, on
# the unowned→owned edge (a fresh account claim), nudge a diagnostics push.
# Reads the prior verdict BEFORE writing the new one. Best-effort: a missing /
# unreadable prior reads as "not owned", so at worst one extra (rate-limited)
# push fires; a state-write failure is logged, not fatal.
_config_sync_record_owned() {
    local now_owned="$1" skip_restart="$2"
    local prior_owned='' write_ok=1
    prior_owned="$(airplanes_read_state "$CONFIG_SYNC_STATE_FILE" owned 2>/dev/null || true)"
    mkdir -p "$(dirname "$CONFIG_SYNC_STATE_FILE")" 2>/dev/null || true
    if ! airplanes_write_state "$CONFIG_SYNC_STATE_FILE" \
        service=airplanes-config-sync \
        owned="$now_owned" \
        decided_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
        write_ok=0
        _config_sync_log warn "reason=state_write_failed"
    fi
    # Only fire the edge if the new verdict actually persisted. If the write
    # failed we can't record that we fired, so firing would re-trigger on every
    # tick — leave it to the regular diagnostics timer instead.
    if (( write_ok )) && [[ "$now_owned" == "true" && "$prior_owned" != "true" ]]; then
        _config_sync_trigger_diagnostics_push "$skip_restart"
    fi
    return 0
}

# Translate the server's `fields` response into per-key arguments for
# apl_feed_apply. Populates the caller-passed arrays:
#   APL_APPLY_INCOMING_META_EDITED_AT, _EDITED_BY (global, by contract
#   with the lib) and the local arg-list array `out_args` (nameref).
#
# Tombstones (value: null) emit empty-string values for nullable feed.env
# keys (LATITUDE, LONGITUDE, ALTITUDE, MLAT_USER); the bool keys never
# receive a tombstone (the API serializer rejects null booleans).
#
# The rejected_fields response array is processed by adopting the
# server's tuple for each rejected key — that heals a bogus on-disk
# edited_at and ends the rejection loop on the next tick.
_config_sync_translate_response() {
    local response_file="$1"
    local -n out_args="$2"
    out_args=()
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()

    # jq extracts one US-separated line per API field with: name,
    # is_tombstone, value, edited_at, edited_by. Position's value is
    # rendered as `lat|lon` so a single line carries both axes; bool
    # values come out as `true`/`false`; null values render as empty
    # string in the `value` column with `is_tombstone=1`.
    #
    # The separator is ASCII US (\x1F), not TAB, because bash `read`
    # treats TAB as whitespace and collapses adjacent tabs (so a null
    # value column would silently merge with the next field). US is a
    # non-whitespace control character that never appears in valid feed
    # data and that `read -r` treats as a single field boundary.
    local entries
    if ! entries="$(jq -j --arg sep $'\x1f' '
        .fields | to_entries[] |
        ([.key,
          (if .value.value == null then "1" else "0" end),
          (if .value.value == null then ""
           elif .key == "position" then "\(.value.value.lat)|\(.value.value.lon)"
           elif (.value.value | type) == "boolean" then (.value.value | tostring)
           else (.value.value | tostring) end),
          .value.edited_at,
          .value.edited_by] | join($sep)) + "\n"
    ' "$response_file" 2>/dev/null)"; then
        return 1
    fi

    local api_field is_null value edited_at edited_by
    while IFS=$'\x1f' read -r api_field is_null value edited_at edited_by; do
        [[ -z "$api_field" ]] && continue
        # The server-side serializer enforces this allowlist on inbound
        # writes; mirror it on the response so a misbehaving server cannot
        # smuggle an unknown actor label into feed.meta.json. Drop the
        # field entirely (no out_args entry, no incoming-meta entry) and
        # continue — other fields in the same response still apply.
        case "$edited_by" in
            feeder|website|legacy) ;;
            *)
                # Quote the value so an attacker-controlled string can't
                # forge extra key=value pairs in the structured log line.
                # jq @tsv already escapes tabs/newlines; this guards
                # against spaces and embedded `=`.
                local _bad_value="${edited_by:0:64}"
                _bad_value="${_bad_value//\"/\\\"}"
                _config_sync_log warn "reason=bad_edited_by field=$api_field value=\"$_bad_value\""
                continue
                ;;
        esac
        case "$api_field" in
            position)
                if [[ "$is_null" == "1" ]]; then
                    out_args+=("LATITUDE=" "LONGITUDE=")
                else
                    local pos_lat="${value%|*}" pos_lon="${value#*|}"
                    out_args+=("LATITUDE=$pos_lat" "LONGITUDE=$pos_lon")
                fi
                APL_APPLY_INCOMING_META_EDITED_AT[LATITUDE]="$edited_at"
                APL_APPLY_INCOMING_META_EDITED_AT[LONGITUDE]="$edited_at"
                APL_APPLY_INCOMING_META_EDITED_BY[LATITUDE]="$edited_by"
                APL_APPLY_INCOMING_META_EDITED_BY[LONGITUDE]="$edited_by"
                ;;
            alt)
                if [[ "$is_null" == "1" ]]; then
                    out_args+=("ALTITUDE=")
                else
                    out_args+=("ALTITUDE=$value")
                fi
                APL_APPLY_INCOMING_META_EDITED_AT[ALTITUDE]="$edited_at"
                APL_APPLY_INCOMING_META_EDITED_BY[ALTITUDE]="$edited_by"
                ;;
            mlat_user)
                if [[ "$is_null" == "1" ]]; then
                    out_args+=("MLAT_USER=")
                else
                    out_args+=("MLAT_USER=$value")
                fi
                APL_APPLY_INCOMING_META_EDITED_AT[MLAT_USER]="$edited_at"
                APL_APPLY_INCOMING_META_EDITED_BY[MLAT_USER]="$edited_by"
                ;;
            mlat_enabled)
                out_args+=("MLAT_ENABLED=$value")
                APL_APPLY_INCOMING_META_EDITED_AT[MLAT_ENABLED]="$edited_at"
                APL_APPLY_INCOMING_META_EDITED_BY[MLAT_ENABLED]="$edited_by"
                ;;
            mlat_private)
                out_args+=("MLAT_PRIVATE=$value")
                APL_APPLY_INCOMING_META_EDITED_AT[MLAT_PRIVATE]="$edited_at"
                APL_APPLY_INCOMING_META_EDITED_BY[MLAT_PRIVATE]="$edited_by"
                ;;
            *)
                # Unknown server field — ignore. A schema_version=1
                # server should never emit one; future versions are
                # caught by the 426 path before we ever reach this.
                ;;
        esac
    done <<< "$entries"

    return 0
}

# Drive the apply step for a 200 APPLIED response. Returns 0 on success
# (applied / no_change), 1 on any apply-side failure (logged + treated
# as transient by the caller).
_config_sync_apply_response() {
    local response_file="$1"
    local skip_restart="$2"
    local -a apply_args=()
    if ! _config_sync_translate_response "$response_file" apply_args; then
        _config_sync_log error "reason=apply_translate body=$(body_preview "$response_file")"
        APL_APPLY_INCOMING_META_EDITED_AT=()
        APL_APPLY_INCOMING_META_EDITED_BY=()
        APL_APPLY_INCOMING_SERVER_TIME=""
        return 1
    fi
    if (( ${#apply_args[@]} == 0 )); then
        # Server returned `fields: {}` — nothing to apply. Treat as
        # success but log so an unexpected empty response is visible.
        _config_sync_log info "reason=empty_fields_payload"
        APL_APPLY_INCOMING_META_EDITED_AT=()
        APL_APPLY_INCOMING_META_EDITED_BY=()
        APL_APPLY_INCOMING_SERVER_TIME=""
        return 0
    fi

    # Pass the server's authoritative `server_time` to the apply lib so
    # its bogus-future-heal threshold is computed against trusted time
    # rather than a possibly-fast local clock.
    APL_APPLY_INCOMING_SERVER_TIME="$(parse_field_from "$response_file" '.server_time')"

    # Atomic position-group LWW decision. The server treats position as
    # a single field, but the apply lib gates per feed.env key. Without
    # this pre-check, a feeder whose on-disk LATITUDE/LONGITUDE stamps
    # have somehow diverged could apply one axis from the server tuple
    # and skip the other — producing a hybrid position. Compute the
    # group decision against the OLDER of the two on-disk stamps so a
    # stale half can't masquerade as the whole.
    local _have_lat_arg=0 _have_lon_arg=0
    local _arg
    for _arg in "${apply_args[@]}"; do
        case "$_arg" in
            LATITUDE=*) _have_lat_arg=1 ;;
            LONGITUDE=*) _have_lon_arg=1 ;;
        esac
    done
    if (( _have_lat_arg == 1 && _have_lon_arg == 1 )); then
        local _meta_path
        _meta_path="$(feed_env_write_path)"
        _meta_path="${_meta_path%/feed.env}/feed.meta.json"
        local -A _on_at=() _on_by=()
        _config_sync_load_meta "$_meta_path" _on_at _on_by
        local _lat_at="${_on_at[LATITUDE]:-}"
        local _lon_at="${_on_at[LONGITUDE]:-}"
        local _pos_group_at=""
        if [[ -n "$_lat_at" && -n "$_lon_at" ]]; then
            # MAX-of-pair: see comment in _config_sync_build_payload.
            # If LAT was edited fresh but LON's stamp is stale, the
            # position state was effectively newly edited at the LAT
            # time — incoming must beat MAX to apply atomically.
            if [[ "$_lat_at" > "$_lon_at" ]]; then
                _pos_group_at="$_lat_at"
            else
                _pos_group_at="$_lon_at"
            fi
        elif [[ -n "$_lat_at" ]]; then
            _pos_group_at="$_lat_at"
        elif [[ -n "$_lon_at" ]]; then
            _pos_group_at="$_lon_at"
        fi
        local _incoming_pos_at="${APL_APPLY_INCOMING_META_EDITED_AT[LATITUDE]:-}"
        if [[ -n "$_pos_group_at" && -n "$_incoming_pos_at" ]]; then
            # Use the same bogus-future-heal carve-out the lib applies.
            # If on-disk is wildly in server-future, the heal path must
            # run — keep both axes in the payload.
            local _heal_threshold
            if [[ -n "$APL_APPLY_INCOMING_SERVER_TIME" \
                && "$APL_APPLY_INCOMING_SERVER_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$ ]]; then
                _heal_threshold="$(date -u -d "$APL_APPLY_INCOMING_SERVER_TIME +300 seconds" \
                    +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
            fi
            local _is_bogus_future=0
            if [[ -n "$_heal_threshold" && "$_pos_group_at" > "$_heal_threshold" ]]; then
                _is_bogus_future=1
            fi
            if (( _is_bogus_future == 0 )) && [[ ! "$_incoming_pos_at" > "$_pos_group_at" ]]; then
                # Drop both LATITUDE and LONGITUDE from apply_args and
                # the incoming-meta arrays so the lib's gate has nothing
                # to decide for position. Other fields apply as usual.
                local -a _filtered=()
                for _arg in "${apply_args[@]}"; do
                    case "$_arg" in
                        LATITUDE=*|LONGITUDE=*) ;;
                        *) _filtered+=("$_arg") ;;
                    esac
                done
                apply_args=("${_filtered[@]}")
                unset 'APL_APPLY_INCOMING_META_EDITED_AT[LATITUDE]'
                unset 'APL_APPLY_INCOMING_META_EDITED_AT[LONGITUDE]'
                unset 'APL_APPLY_INCOMING_META_EDITED_BY[LATITUDE]'
                unset 'APL_APPLY_INCOMING_META_EDITED_BY[LONGITUDE]'
                _config_sync_log info "reason=position_group_skipped_by_lww"
            fi
        fi
        if (( ${#apply_args[@]} == 0 )); then
            _config_sync_log info "reason=all_keys_skipped_after_pos_group"
            APL_APPLY_INCOMING_META_EDITED_AT=()
            APL_APPLY_INCOMING_META_EDITED_BY=()
            APL_APPLY_INCOMING_SERVER_TIME=""
            return 0
        fi
    fi

    feed_env_ensure_canonical_for_write
    local -a lib_args=(--feed-env "$(feed_env_write_path)"
                       --lock-file "$(feed_env_lock_path)")
    if (( skip_restart )); then
        lib_args+=(--no-restart)
    fi
    if [[ "$ROOT" != "/" ]]; then
        lib_args+=(--no-restart --no-audit)
    fi

    local rc=0
    apl_feed_apply "${lib_args[@]}" "${apply_args[@]}" || rc=$?
    # Always clear the globals so a subsequent call (e.g. retry from
    # the timer's next tick) starts from a clean slate.
    APL_APPLY_INCOMING_META_EDITED_AT=()
    APL_APPLY_INCOMING_META_EDITED_BY=()
    APL_APPLY_INCOMING_SERVER_TIME=""

    case "$APL_APPLY_STATUS" in
        applied|no_change)
            local skipped="${APL_APPLY_SKIPPED_BY_LWW[*]:-}"
            local changed="${APL_APPLY_CHANGED[*]:-}"
            _config_sync_log info \
                "reason=applied status=$APL_APPLY_STATUS changed=[${changed}] lww_skipped=[${skipped}]"
            return 0
            ;;
        rejected)
            local k errs=""
            for k in "${!APL_APPLY_ERRORS[@]}"; do
                errs+="${k}=\"${APL_APPLY_ERRORS[$k]}\" "
            done
            _config_sync_log error "reason=apply_rejected errors=[${errs% }]"
            return 1
            ;;
        lock_timeout|filesystem_error|usage_error)
            _config_sync_log warn \
                "reason=apply_${APL_APPLY_STATUS} message=\"${APL_APPLY_ERROR_MESSAGE}\""
            return 1
            ;;
        *)
            _config_sync_log warn "reason=apply_unknown status=${APL_APPLY_STATUS:-empty} rc=$rc"
            return 1
            ;;
    esac
}

# Print the outgoing payload to stdout (for --dry-run). Returns 0 on
# success, 1 on local read error.
_config_sync_dry_run() {
    local feed_env feeder_time payload
    feed_env="$(root_path '/etc/airplanes/feed.env')"
    local meta_path="${feed_env%/feed.env}/feed.meta.json"
    feeder_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$feed_env" ]]; then
        _config_sync_log error "reason=feed_env_missing path=$feed_env"
        return 1
    fi
    if ! payload="$(_config_sync_build_payload "$feed_env" "$meta_path" "$feeder_time")"; then
        _config_sync_log error "reason=payload_build_failed"
        return 1
    fi
    printf '%s\n' "$payload"
    return 0
}

apl_feed_config_sync() {
    local dry_run=0
    local skip_restart=0

    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --no-restart)
                skip_restart=1
                shift
                ;;
            -h|--help)
                usage_config_sync
                exit 0
                ;;
            *)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for config sync: $1" ;;
                esac
                ;;
        esac
    done

    # Opt-in gate. REMOTE_CONFIG_ENABLED must be explicitly true before
    # this CLI contacts the website. Absent / empty / false all short-
    # circuit silently with exit 0 — the timer keeps ticking, the
    # collector exits silently each tick, no payload leaves the feeder.
    # An unparseable value surfaces as a hard config error (exit 64) so
    # operators see it in `apl-feed status` / `systemctl status`.
    local opt_in opt_in_state
    opt_in="$(feed_env_get REMOTE_CONFIG_ENABLED 2>/dev/null || true)"
    opt_in_state="$(_config_sync_parse_opt_in "$opt_in")"
    case "$opt_in_state" in
        disabled|empty)
            _config_sync_log info "status=disabled reason=opt_in_required"
            return "$CONFIG_SYNC_EXIT_OK"
            ;;
        invalid)
            _config_sync_log error "status=bad_config key=REMOTE_CONFIG_ENABLED value=${opt_in}"
            return "$CONFIG_SYNC_EXIT_BAD_CONFIG"
            ;;
        enabled) ;;
    esac

    require_jq

    if (( dry_run )); then
        if _config_sync_dry_run; then
            return "$CONFIG_SYNC_EXIT_OK"
        fi
        return 1
    fi

    # Identity prerequisites. Failure here is a hard config error —
    # exit 64 so systemd marks the unit failed.
    local uuid secret_path secret
    if ! uuid="$(read_uuid 2>/dev/null)"; then
        _config_sync_log error "reason=missing_uuid"
        return "$CONFIG_SYNC_EXIT_BAD_CONFIG"
    fi
    secret_path="$(secret_final_path)"
    if [[ ! -f "$secret_path" ]]; then
        _config_sync_log error "reason=missing_claim_secret path=$secret_path"
        return "$CONFIG_SYNC_EXIT_BAD_CONFIG"
    fi
    if [[ ! -r "$secret_path" ]]; then
        _config_sync_log error "reason=unreadable_claim_secret path=$secret_path"
        return "$CONFIG_SYNC_EXIT_BAD_CONFIG"
    fi
    # read_secret_file calls `die` (exit 1) on a malformed secret.
    # Without the `||` capture, set -e would propagate that exit 1 out
    # of this function — masking it as a generic transient failure
    # instead of the hard-config error it actually is.
    local _secret_rc=0
    secret="$(read_secret_file "$secret_path" 2>/dev/null)" || _secret_rc=$?
    if (( _secret_rc != 0 )) || [[ -z "$secret" ]]; then
        _config_sync_log error "reason=invalid_claim_secret path=$secret_path"
        return "$CONFIG_SYNC_EXIT_BAD_CONFIG"
    fi

    local feed_env meta_path feeder_time payload response_file
    feed_env="$(root_path '/etc/airplanes/feed.env')"
    meta_path="${feed_env%/feed.env}/feed.meta.json"
    feeder_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [[ ! -f "$feed_env" ]]; then
        _config_sync_log error "reason=feed_env_missing path=$feed_env"
        return "$CONFIG_SYNC_EXIT_BAD_CONFIG"
    fi

    if ! payload="$(_config_sync_build_payload "$feed_env" "$meta_path" "$feeder_time")"; then
        _config_sync_log error "reason=payload_build_failed"
        return "$CONFIG_SYNC_EXIT_OK"
    fi

    response_file="$(new_tmp_file)"
    local status curl_rc token
    token="$(apl_auth_token "$uuid" "$secret")"
    set +e
    status="$(post_json_bearer "$token" '/api/feeders/config/sync' "$payload" "$response_file")"
    curl_rc=$?
    set -e

    if [[ "$curl_rc" -ne 0 ]]; then
        _config_sync_log warn "reason=transport curl_rc=$curl_rc"
        return "$CONFIG_SYNC_EXIT_OK"
    fi

    local error_field body_preview owned
    error_field="$(parse_field_from "$response_file" '.error')"
    body_preview="$(body_preview "$response_file")"

    case "$status" in
        200)
            owned="$(parse_field_from "$response_file" '.owned')"
            case "$owned" in
                true)
                    local rejected
                    rejected="$(jq -r '.rejected_fields // [] | join(",")' "$response_file" 2>/dev/null || true)"
                    if [[ -n "$rejected" ]]; then
                        _config_sync_log warn "reason=rejected_fields fields=[$rejected]"
                    fi
                    if _config_sync_apply_response "$response_file" "$skip_restart"; then
                        _config_sync_touch_sentinel
                    fi
                    _config_sync_record_owned true "$skip_restart"
                    ;;
                false)
                    _config_sync_log info "reason=unowned"
                    _config_sync_touch_sentinel
                    _config_sync_record_owned false "$skip_restart"
                    ;;
                *)
                    _config_sync_log warn "reason=malformed_response body=$body_preview"
                    ;;
            esac
            ;;
        400)
            _config_sync_log error "reason=validation_failed body=$body_preview"
            ;;
        401)
            _config_sync_log error "reason=unauthorized body=$body_preview"
            ;;
        423)
            local block_reason
            block_reason="$(parse_field_from "$response_file" '.reason')"
            _config_sync_log warn "reason=blocked block_reason=${block_reason:-unknown}"
            ;;
        426)
            local supported
            supported="$(jq -r '.supported // [] | tostring' "$response_file" 2>/dev/null || true)"
            _config_sync_log error "reason=schema_version_unsupported server_supported=${supported:-[]}"
            ;;
        429)
            _config_sync_log warn "reason=rate_limited body=$body_preview"
            ;;
        5*)
            _config_sync_log warn "reason=server_${status} body=$body_preview"
            ;;
        *)
            _config_sync_log warn "reason=unexpected_status status=$status error=${error_field:-} body=$body_preview"
            ;;
    esac

    return "$CONFIG_SYNC_EXIT_OK"
}

# Operator-facing toggle for the REMOTE_CONFIG_ENABLED opt-in. Mirrors
# _diagnostics_apply / _diagnostics_emit_result in apl-feed/diagnostics.sh:
# routes the sparse update through apl_feed_apply so the canonical
# privileged writer handles locking, validation, and atomic rewrite.
# REMOTE_CONFIG_ENABLED is registered as a no-restart key in
# feed-env-keys.sh — the next sync tick (within ~60s) reads the new
# value at the top-of-function gate.
_config_toggle_apply() {
    feed_env_ensure_canonical_for_write
    local -a args=()
    args+=(--feed-env "$(feed_env_write_path)")
    args+=(--lock-file "$(feed_env_lock_path)")
    if [[ "$ROOT" != "/" ]]; then
        args+=(--no-restart --no-audit)
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
    fi
    CONFIG_TOGGLE_APPLY_RC=0
    apl_feed_apply "${args[@]}" "$@" || CONFIG_TOGGLE_APPLY_RC=$?
}

_config_toggle_emit_result() {
    local success_msg="$1"
    case "$APL_APPLY_STATUS" in
        applied)
            echo "$success_msg"
            if (( ${#APL_APPLY_PENDING_RESTART[@]} > 0 )); then
                echo "Warning: failed to restart ${APL_APPLY_PENDING_RESTART[*]} — re-run: sudo systemctl restart ${APL_APPLY_PENDING_RESTART[*]}" >&2
            fi
            apl_feed_apply_emit_meta_warning
            return 0
            ;;
        no_change)
            return 0
            ;;
        rejected)
            local k
            for k in "${!APL_APPLY_ERRORS[@]}"; do
                echo "ERROR: $k: ${APL_APPLY_ERRORS[$k]}" >&2
            done
            return 1
            ;;
        lock_timeout)
            echo "ERROR: could not acquire feed.env lock: $APL_APPLY_ERROR_MESSAGE" >&2
            return 1
            ;;
        filesystem_error)
            echo "ERROR: $APL_APPLY_ERROR_MESSAGE" >&2
            return 1
            ;;
        *)
            echo "ERROR: ${APL_APPLY_ERROR_MESSAGE:-apply failed with status ${APL_APPLY_STATUS:-<unset>}}" >&2
            return 1
            ;;
    esac
}

apl_feed_config_enable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in -h|--help) usage_config_enable; exit 0 ;; esac
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for config enable: $1" ;;
        esac
    done

    _config_toggle_apply REMOTE_CONFIG_ENABLED=true
    _config_toggle_emit_result "REMOTE_CONFIG_ENABLED set to true (remote config sync enabled; next tick within ~60s will contact the website)"
}

apl_feed_config_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in -h|--help) usage_config_disable; exit 0 ;; esac
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for config disable: $1" ;;
        esac
    done

    _config_toggle_apply REMOTE_CONFIG_ENABLED=false
    _config_toggle_emit_result "REMOTE_CONFIG_ENABLED set to false (remote config sync disabled; the timer stays armed but the sync CLI exits silently each tick)"
}

usage_config() {
    cat <<'USAGE'
Usage: apl-feed config <subcommand> [options]

Subcommands:
  show [--json]                     Print the effective feeder configuration
  sync [--dry-run] [--no-restart]   Run a one-shot remote config sync
  enable                            Enable remote config sync (opt-in)
  disable                           Disable remote config sync

Run 'apl-feed config <subcommand> --help' for details.
USAGE
}

usage_config_show() {
    cat <<'USAGE'
Usage: apl-feed config show [--json]

Prints the effective feeder configuration: the readable feed.env keys
with the values the daemons resolve, read from the same files the
daemons read (a not-yet-migrated legacy image falls back to its boot
config). Values are parsed with the same strict reader 'apl-feed apply'
uses — this command is the supported way for other software to read the
feeder configuration instead of parsing feed.env itself.

Default output is one KEY=value line per present key. --json emits
{"schema_version":1,"values":{...}} with one entry per readable key:
a string when the key is present (empty string for an explicitly empty
value), null when absent.
USAGE
}

apl_feed_config_show() {
    local as_json=0 opt_rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_config_show; exit 0 ;;
            --json) as_json=1; shift; continue ;;
        esac
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for config show: $1" ;;
        esac
    done

    # The strict reader lives in feed-env-apply.sh, sourced defensively by
    # the CLI entrypoint; a partial install only stubs apl_feed_apply.
    declare -F _apl_feed_apply_read >/dev/null 2>&1 \
        || die "feed-env-apply.sh missing; reinstall feed"

    # Effective values: every file the daemons read, in feed_env_paths
    # order with later files overriding earlier ones, parsed with the
    # strict reader so this command and `apply` share one parser.
    local -A _show_values=()
    local _show_path _show_k
    while IFS= read -r _show_path; do
        [[ -n "$_show_path" && -f "$_show_path" ]] || continue
        local -A _show_file=()
        _apl_feed_apply_read "$_show_path" _show_file
        for _show_k in "${!_show_file[@]}"; do
            _show_values[$_show_k]="${_show_file[$_show_k]}"
        done
    done < <(feed_env_paths)

    local key
    if (( as_json )); then
        require_jq
        local jq_args=() filter='{schema_version: 1, values: {}}' i=0
        for key in "${APL_FEED_READABLE_KEYS[@]}"; do
            if [[ -n "${_show_values[$key]+set}" ]]; then
                jq_args+=(--arg "k${i}" "$key" --arg "v${i}" "${_show_values[$key]}")
                filter+=" | .values[\$k${i}] = \$v${i}"
            else
                jq_args+=(--arg "k${i}" "$key")
                filter+=" | .values[\$k${i}] = null"
            fi
            i=$((i + 1))
        done
        jq -nc "${jq_args[@]}" "$filter"
    else
        for key in "${APL_FEED_READABLE_KEYS[@]}"; do
            [[ -n "${_show_values[$key]+set}" ]] || continue
            printf '%s=%s\n' "$key" "${_show_values[$key]}"
        done
    fi
}

usage_config_sync() {
    cat <<'USAGE'
Usage: apl-feed config sync [--dry-run] [--no-restart]

Pushes the local feed.env snapshot to airplanes.live and applies the
server's merged response. Requires REMOTE_CONFIG_ENABLED=true (see
'apl-feed config enable'). --dry-run prints the outgoing payload without
contacting the server; --no-restart suppresses the post-apply restart.
USAGE
}

usage_config_enable() {
    cat <<'USAGE'
Usage: apl-feed config enable

Opts this feeder into remote config sync (sets REMOTE_CONFIG_ENABLED=true).
The next sync tick within ~60s contacts the website.
USAGE
}

usage_config_disable() {
    cat <<'USAGE'
Usage: apl-feed config disable

Opts this feeder out of remote config sync (sets REMOTE_CONFIG_ENABLED=
false). The timer stays armed but the sync exits silently each tick.
USAGE
}

dispatch_config() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || usage_error usage_config
    if [[ "$sub" == "-h" || "$sub" == "--help" ]]; then
        usage_config
        return 0
    fi
    shift || true
    case "$sub" in
        show)    apl_feed_config_show    "$@" ;;
        enable)  apl_feed_config_enable  "$@" ;;
        disable) apl_feed_config_disable "$@" ;;
        sync)    apl_feed_config_sync    "$@" ;;
        *) usage_error usage_config "unknown config subcommand: $sub" ;;
    esac
}
