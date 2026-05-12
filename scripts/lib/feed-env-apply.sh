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

# Reset the result globals to a clean slate.
_apl_feed_apply_reset_state() {
    APL_APPLY_STATUS=""
    APL_APPLY_CHANGED=()
    APL_APPLY_PENDING_RESTART=()
    APL_APPLY_ERROR_MESSAGE=""
    declare -gA APL_APPLY_ERRORS=()
}

# Public entry. See header comment for the contract.
#
# Usage:
#   apl_feed_apply [--no-restart] [--lock-timeout SECS]
#                  [--feed-env PATH] [--lock-file PATH]
#                  KEY=value [KEY=value ...]
apl_feed_apply() {
    _apl_feed_apply_reset_state

    local feed_env="$APL_FEED_APPLY_FEED_ENV_DEFAULT"
    local lock_path="$APL_FEED_APPLY_LOCK_DEFAULT"
    local lock_timeout="$APL_FEED_APPLY_LOCK_TIMEOUT_DEFAULT"
    local skip_restart=0
    local explicit_geo_in_payload=0
    local touched_lat=0 touched_lon=0
    local -A payload=()
    local -A merged=()
    local key value pair

    while (( $# > 0 )); do
        case "$1" in
            --no-restart)
                skip_restart=1
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
        APL_APPLY_STATUS=no_change
        return 0
    fi

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
    if [[ ! -f "$feed_env" ]]; then
        APL_APPLY_STATUS=filesystem_error
        APL_APPLY_ERROR_MESSAGE="feed.env not found at $feed_env"
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        return 3
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

    if (( ${#APL_APPLY_CHANGED[@]} == 0 )); then
        APL_APPLY_STATUS=no_change
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        return 0
    fi

    # Write atomically.
    if ! _apl_feed_apply_write "$feed_env" merged; then
        APL_APPLY_STATUS=filesystem_error
        APL_APPLY_ERROR_MESSAGE="atomic write to $feed_env failed"
        [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"
        return 3
    fi

    # Release lock before service restarts so a slow systemctl call cannot
    # block subsequent writers.
    [[ -n "$lock_fd" ]] && eval "exec ${lock_fd}>&-"

    if (( skip_restart == 1 )); then
        APL_APPLY_STATUS=applied
        return 0
    fi

    # Don't touch host services when writing to a non-host feed.env
    # (--feed-env pointing somewhere under a /mnt or /tmp scratch tree).
    # The canonical host path is /etc/airplanes/feed.env; anything else
    # is by definition not the live system. APL_FEED_APPLY_HOST_PATH
    # overrides the comparison for tests that want to exercise the
    # restart fan-out against a scratch feed.env.
    local host_path="${APL_FEED_APPLY_HOST_PATH:-/etc/airplanes/feed.env}"
    if [[ "$feed_env" != "$host_path" ]]; then
        APL_APPLY_STATUS=applied
        return 0
    fi

    local -a restart_set=()
    _apl_feed_apply_restart_set APL_APPLY_CHANGED restart_set
    _apl_feed_apply_restart_services "${restart_set[@]}" || true

    APL_APPLY_STATUS=applied
    return 0
}
