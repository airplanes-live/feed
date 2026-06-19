#!/usr/bin/env bash
# airplanes-stats.sh — forward the feeder's raw readsb JSON (aircraft.json /
# stats.json / outline.json, written by airplanes-feed.sh's --write-json) to the
# airplanes.live backend, which extracts per-feeder reception metrics. Invoked
# every ~120s by airplanes-stats.timer, independent of the diagnostics push.
#
# The server owns metric extraction (see /api/feeders/stats), so the feeder
# forwards the documents verbatim and new statistics can be added without a fleet
# update. The body is the envelope {schema_version, ts, uuid, aircraft, stats,
# outline?}, gzip-encoded.
#
# Exit codes
#   0   success, REPORT_STATUS=disabled (deliberate skip), not-yet-claimed,
#       forwarder JSON absent/stale, oversize, or a transient HTTP/transport
#       failure (logged; no systemd backoff)
#   64  REPORT_STATUS has an unrecognized or unreadable value — systemd marks
#       the unit failed so the config error surfaces to the operator
#
# Best-effort by design: any failure short of a config error exits 0 so the
# timer keeps the unit green and simply retries on the next tick.

set -uo pipefail

SCRIPT_NAME="airplanes-stats"
EXIT_OK=0
EXIT_BAD_CONFIG=64

# Endpoint + structural limits. The size caps mirror the server's
# /api/feeders/stats decoder: a gzip body must be <= 512 KiB compressed AND
# expand to <= 4 MiB; exceeding either yields a 413, so the client checks both
# before sending. FRESHNESS_MAX_SKEW_SEC: aircraft.json is rewritten ~1s, so a
# `now` further than this from wall-clock means the forwarder is down — we don't
# ship its last gasp.
STATS_ENDPOINT='/api/feeders/stats'
# The AIRPLANES_STATS_TEST_* overrides are test-only knobs (the bats suite sets a
# tiny cap to exercise the outline-drop fallback + oversize-skip deterministically
# without generating multi-MB payloads). The TEST prefix is deliberate so a stray
# export in a production shell is obvious; production never sets them.
MAX_RAW_BYTES="${AIRPLANES_STATS_TEST_MAX_RAW_BYTES:-$((4 * 1024 * 1024))}"
MAX_GZIP_BYTES="${AIRPLANES_STATS_TEST_MAX_GZIP_BYTES:-$((512 * 1024))}"
FRESHNESS_MAX_SKEW_SEC=120

INSTALL_DIR="${AIRPLANES_STATS_INSTALL_DIR:-}"

_resolve_install_dir() {
    if [[ -n "$INSTALL_DIR" ]]; then
        printf '%s' "$INSTALL_DIR"
        return
    fi
    local self_dir
    self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s' "$self_dir"
}

_INSTALL_DIR="$(_resolve_install_dir)"

# Source helpers from apl-feed/ (production /usr/local/share/airplanes/apl-feed/,
# source tree feed/scripts/apl-feed/). feed-env-apply.sh sits in the sibling lib/
# dir and is required: common.sh's feed_env_get delegates to its strict reader.
# Mirrors airplanes-diagnostics.sh's bootstrap.
for _candidate in \
    "$_INSTALL_DIR/apl-feed/common.sh" \
    "$_INSTALL_DIR/../scripts/apl-feed/common.sh"; do
    if [[ -r "$_candidate" ]]; then
        _COMMON_SH="$_candidate"
        _HTTP_SH="$(dirname "$_candidate")/http.sh"
        _FEED_ENV_APPLY_SH="$(dirname "$_candidate")/../lib/feed-env-apply.sh"
        break
    fi
done

if [[ -z "${_COMMON_SH:-}" ]] || [[ ! -r "${_HTTP_SH:-}" ]] \
    || [[ ! -r "${_FEED_ENV_APPLY_SH:-}" ]]; then
    printf '%s level=error status=fatal reason=helpers_missing install_dir=%s\n' \
        "$SCRIPT_NAME" "$_INSTALL_DIR" >&2
    exit "$EXIT_BAD_CONFIG"
fi

# shellcheck source=lib/feed-env-apply.sh
source "$_FEED_ENV_APPLY_SH"
# shellcheck source=apl-feed/common.sh
source "$_COMMON_SH"
# shellcheck source=apl-feed/http.sh
source "$_HTTP_SH"

# common.sh unconditionally sets ROOT='/' on source. Reapply the override after
# sourcing so tests / chroot smokes can re-root the script's filesystem reads.
ROOT="${AIRPLANES_STATS_ROOT:-/}"

log() {
    local level="$1"; shift
    printf '%s level=%s %s host=%s\n' "$SCRIPT_NAME" "$level" "$*" "$WEBSITE_HOST" >&2
}

# validate_doc SRC DEST
#   Write SRC compacted to DEST iff SRC parses to a JSON object; return 0 on
#   success, 1 if SRC is missing/unreadable/non-object/parse-fail (e.g. caught
#   mid-write by the forwarder). Each document is validated independently so one
#   bad file (typically a truncated outline.json) doesn't sink the others.
#   `timeout` bounds a pathological file so it can't hang the run.
validate_doc() {
    local src="$1" dest="$2"
    [[ -r "$src" ]] || return 1
    # Slurp the whole file and accept ONLY a single JSON object. A multi-document
    # stream (a corrupt/half-rewritten readsb file can concatenate two objects)
    # or a non-object is rejected, so the run skips rather than uploading the
    # first fragment. `timeout` bounds a pathological file.
    timeout 3s jq -sce \
        'if length == 1 and (.[0] | type == "object") then .[0] else error("not one object") end' \
        "$src" > "$dest" 2>/dev/null
}

# build_envelope WITH_OUTLINE OUT_FILE
#   Assemble the stats envelope from the validated compact tmpfiles into OUT_FILE.
#   Reads the caller's locals (ts, uuid, aircraft_tmp, stats_tmp, outline_tmp) via
#   bash dynamic scope. WITH_OUTLINE=1 includes the outline doc (only if
#   outline_tmp is set); 0 omits it (the size-fallback path). schema_version is
#   the integer 1 the server requires. Returns jq's exit code.
build_envelope() {
    local with_outline="$1" out_file="$2"
    local -a args=(
        --arg ts "$ts"
        --arg uuid "$uuid"
        --slurpfile aircraft "$aircraft_tmp"
        --slurpfile stats "$stats_tmp"
    )
    local filter='{schema_version: 1, ts: $ts, uuid: $uuid, aircraft: $aircraft[0], stats: $stats[0]}'
    if [[ "$with_outline" == "1" && -n "$outline_tmp" ]]; then
        args+=(--slurpfile outline "$outline_tmp")
        filter='{schema_version: 1, ts: $ts, uuid: $uuid, aircraft: $aircraft[0], stats: $stats[0], outline: $outline[0]}'
    fi
    timeout 3s jq -nc "${args[@]}" "$filter" > "$out_file" 2>/dev/null
}

main() {
    # 1. Consent. report_status_consent (common.sh) fails CLOSED: an unreadable
    # REPORT_STATUS line is "invalid", same bad-config exit as a bad value.
    local report_status_raw toggle
    report_status_raw="$(feed_env_get REPORT_STATUS 2>/dev/null || true)"
    toggle="$(report_status_consent)"
    case "$toggle" in
        invalid)
            log error "status=bad_config key=REPORT_STATUS value=${report_status_raw:-unreadable}"
            exit "$EXIT_BAD_CONFIG"
            ;;
        disabled)
            log info "status=disabled"
            exit "$EXIT_OK"
            ;;
    esac

    # 2. Identity. Either piece missing/invalid means the feeder isn't claimed
    # yet; the timer fires again in ~120s once claim has run. read_uuid /
    # read_secret_file die() on a malformed file, caught by the `||` here
    # (the script runs without set -e).
    local uuid secret
    uuid="$(read_uuid 2>/dev/null)" || {
        log info "status=not_configured reason=no_uuid"
        exit "$EXIT_OK"
    }
    if ! uuid="$(canonicalize_uuid "$uuid" 2>/dev/null)" || [[ -z "$uuid" ]]; then
        log info "status=not_configured reason=bad_uuid"
        exit "$EXIT_OK"
    fi
    secret="$(read_secret_file "$(secret_final_path)" 2>/dev/null)" || {
        log info "status=not_configured reason=no_secret"
        exit "$EXIT_OK"
    }
    if ! validate_secret "$secret"; then
        log info "status=not_configured reason=bad_secret"
        exit "$EXIT_OK"
    fi

    # 3. jq is required to validate + assemble the envelope. Absent → skip.
    command -v jq >/dev/null 2>&1 || {
        log info "status=skip reason=no_jq"
        exit "$EXIT_OK"
    }

    # 4. Locate + validate the forwarder's documents. aircraft + stats are core
    # (skip the whole run if either is missing/invalid — never POST a partial
    # envelope); outline is optional (omitted if absent/invalid, e.g. a quiet
    # receiver with no range ring).
    local json_dir aircraft_file stats_file outline_file
    json_dir="$(root_path /run/airplanes-feed)"
    aircraft_file="$json_dir/aircraft.json"
    stats_file="$json_dir/stats.json"
    outline_file="$json_dir/outline.json"

    local aircraft_tmp stats_tmp outline_tmp outline_candidate
    aircraft_tmp="$(new_tmp_file)"
    stats_tmp="$(new_tmp_file)"
    if ! validate_doc "$aircraft_file" "$aircraft_tmp"; then
        log info "status=skip reason=aircraft_unavailable"
        exit "$EXIT_OK"
    fi
    if ! validate_doc "$stats_file" "$stats_tmp"; then
        log info "status=skip reason=stats_unavailable"
        exit "$EXIT_OK"
    fi
    outline_tmp=''
    outline_candidate="$(new_tmp_file)"
    if validate_doc "$outline_file" "$outline_candidate"; then
        outline_tmp="$outline_candidate"
    fi

    # 5. Freshness. A stale/missing `now` in aircraft.json means the forwarder is
    # down — don't ship its last gasp.
    local now_val epoch
    # Only a JSON *number* now is trusted — a string "now" is a malformed doc.
    now_val="$(jq -r 'if (.now | type) == "number" then .now else empty end' "$aircraft_tmp" 2>/dev/null)"
    if [[ -z "$now_val" || ! "$now_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log info "status=skip reason=no_now"
        exit "$EXIT_OK"
    fi
    epoch="$(date +%s 2>/dev/null)"
    if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
        log info "status=skip reason=no_epoch"
        exit "$EXIT_OK"
    fi
    if awk -v a="$now_val" -v b="$epoch" -v m="$FRESHNESS_MAX_SKEW_SEC" \
        'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d > m) }'; then
        log info "status=skip reason=stale now=$now_val epoch=$epoch"
        exit "$EXIT_OK"
    fi

    # 6. Assemble + size-check against BOTH server caps. On a dense receiver the
    # full snapshot can exceed the gzip/raw caps; drop the (largest) outline doc
    # and retry, then skip if still over — keeps core stats flowing rather than
    # 413ing every tick.
    local ts envelope_file gzip_file raw_size gz_size with_outline
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    envelope_file="$(new_tmp_file)"
    gzip_file="$(new_tmp_file)"
    with_outline=0
    [[ -n "$outline_tmp" ]] && with_outline=1

    if ! build_envelope "$with_outline" "$envelope_file" \
        || ! gzip -c "$envelope_file" > "$gzip_file" 2>/dev/null; then
        log warn "status=build_failed"
        exit "$EXIT_OK"
    fi
    raw_size="$(wc -c < "$envelope_file" 2>/dev/null || echo 0)"
    gz_size="$(wc -c < "$gzip_file" 2>/dev/null || echo 0)"

    if (( raw_size > MAX_RAW_BYTES || gz_size > MAX_GZIP_BYTES )); then
        if (( with_outline == 1 )); then
            with_outline=0
            if ! build_envelope 0 "$envelope_file" \
                || ! gzip -c "$envelope_file" > "$gzip_file" 2>/dev/null; then
                log warn "status=build_failed"
                exit "$EXIT_OK"
            fi
            raw_size="$(wc -c < "$envelope_file" 2>/dev/null || echo 0)"
            gz_size="$(wc -c < "$gzip_file" 2>/dev/null || echo 0)"
        fi
        if (( raw_size > MAX_RAW_BYTES || gz_size > MAX_GZIP_BYTES )); then
            log warn "status=oversize raw=$raw_size gz=$gz_size"
            exit "$EXIT_OK"
        fi
    fi

    # 7. Re-check consent right before the POST so a near-simultaneous opt-out
    # is honored on this tick rather than after the upload.
    local late_toggle
    late_toggle="$(report_status_consent)"
    if [[ "$late_toggle" != "enabled" ]]; then
        log info "status=consent_changed toggle=$late_toggle"
        exit "$EXIT_OK"
    fi

    # 8. POST. Bearer = alv1.<uuid>.<secret>, carried in a 0600 curl --config
    # file (not argv). Best-effort: a non-2xx / transport error is logged and the
    # next tick retries; the exit stays 0 so the unit doesn't flap to failed.
    local token response_file status curl_rc
    token="$(apl_auth_token "$uuid" "$secret")" || {
        log warn "status=token_failed"
        exit "$EXIT_OK"
    }
    response_file="$(new_tmp_file)"
    status="$(post_gzip_bearer "$token" "$STATS_ENDPOINT" "$gzip_file" "$response_file")"
    curl_rc=$?
    token=''

    if (( curl_rc != 0 )); then
        log warn "status=transport_error curl_rc=$curl_rc"
        exit "$EXIT_OK"
    fi
    case "$status" in
        2*) log info "status=stats_ok http=$status outline=$with_outline" ;;
        *)  log warn "status=stats_failed http=${status:-none}" ;;
    esac
    exit "$EXIT_OK"
}

main "$@"
