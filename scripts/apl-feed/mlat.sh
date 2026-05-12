#!/usr/bin/env bash

# MLAT enable/disable + configuration. Operator-facing alternative to
# editing /etc/airplanes/feed.env by hand for users not on the new feeder
# image (image users have the same surface in webconfig).
#
# The on-disk schema treats MLAT_USER as a name (free text in
# [A-Za-z0-9_-]{1,64}; airplanes-mlat.sh falls back to
# Anonymous-<short-feeder-id> at startup when empty) and MLAT_ENABLED as
# the state flag. enable / disable flip MLAT_ENABLED while preserving
# MLAT_USER; user / geo target the corresponding keys atomically.
#
# MLAT requires geo: enable refuses unless GEO_CONFIGURED=true AND
# LATITUDE/LONGITUDE/ALTITUDE are all non-empty. The same gate is
# enforced server-side by webconfig's apply-config and runtime-side by
# airplanes-mlat.sh's classifier. The CLI gate exists so the operator
# sees the error before systemd takes the daemon through enable → exit 64.

# MLAT_USER strict shape — mirrors webconfig configspec.go's mlatUserRE.
# CLI rejects mismatched input rather than mangling it via sanitize_mlat_user
# (which silently rewrites disallowed characters to `_`).
_MLAT_USER_RE='^[A-Za-z0-9_-]{1,64}$'

# Skip the systemctl restart when running against a non-host filesystem
# (--root /mnt/...) or under AIRPLANES_BUILD_MODE=1 (image build-time
# invocation, no live systemd to talk to). File edits still happen.
_mlat_should_skip_restart() {
    if [[ "$ROOT" != "/" ]]; then
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
        return 0
    fi
    case "${AIRPLANES_BUILD_MODE:-}" in
        1|true|yes)
            echo "Skipping service restart (AIRPLANES_BUILD_MODE set)" >&2
            return 0
            ;;
    esac
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_mlat_restart_service() {
    if _mlat_should_skip_restart; then
        return 0
    fi
    if ! systemctl restart airplanes-mlat 2>&1; then
        echo "service restart failed; recent journal output:" >&2
        journalctl -u airplanes-mlat -n 10 --no-pager 2>/dev/null >&2 || true
        return 1
    fi
}

# Atomic rewrite of feed.env that updates MLAT_USER and MLAT_ENABLED while
# preserving every other key, line ordering of unrelated keys, and file
# mode/owner. Mirrors update-migrations.sh's migrate_user_to_mlat_split
# pattern (mktemp same-dir, drop existing keys via grep -v, append the
# canonical pair, chmod/chown --reference, mv -f).
_mlat_rewrite_feed_env() {
    local feed_env="$1"
    local new_user="$2"
    local new_enabled="$3"

    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"

    # Refuse to "fix" an unmigrated install — silently inserting MLAT_USER
    # / MLAT_ENABLED into a feed.env that still has the legacy USER= would
    # cross update-migrations.sh's responsibility and produce a confusing
    # mid-state.
    if ! grep -qE '^MLAT_USER=' "$feed_env"; then
        die "feed.env at $feed_env appears unmigrated (no MLAT_USER= line); run \`sudo /usr/local/share/airplanes/update.sh\` first"
    fi

    local tmp escaped
    tmp="$(mktemp "${feed_env}.XXXXXX")"
    grep -vE '^(MLAT_USER|MLAT_ENABLED)=' "$feed_env" > "$tmp" || true
    # Same escape rule as migrate_user_to_mlat_split — make sourcing the
    # written file produce the literal username, no expansion.
    escaped="${new_user//\\/\\\\}"
    escaped="${escaped//\$/\\\$}"
    escaped="${escaped//\`/\\\`}"
    escaped="${escaped//\"/\\\"}"
    printf 'MLAT_USER="%s"\n' "$escaped" >> "$tmp"
    printf 'MLAT_ENABLED=%s\n' "$new_enabled" >> "$tmp"
    chmod --reference="$feed_env" "$tmp" 2>/dev/null || true
    chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$feed_env"
}

apl_feed_mlat_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat disable: $1" ;;
        esac
    done

    local feed_env current_user
    feed_env="$(feed_env_path)"
    current_user="$(feed_env_get MLAT_USER 2>/dev/null || true)"

    _mlat_rewrite_feed_env "$feed_env" "$current_user" "false"
    echo "MLAT_ENABLED set to false in $feed_env"
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done (daemon will sleep while disabled)"
    else
        return 1
    fi
}

apl_feed_mlat_enable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat enable: $1" ;;
        esac
    done

    local feed_env
    feed_env="$(feed_env_path)"
    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"
    _mlat_require_geo "$feed_env"

    local user
    user="$(feed_env_get MLAT_USER 2>/dev/null || true)"
    # Empty MLAT_USER is legal: airplanes-mlat.sh substitutes
    # Anonymous-<short-feeder-id> at daemon startup. Preserve the empty
    # value rather than inlining a literal "Anonymous" here.

    _mlat_rewrite_feed_env "$feed_env" "$user" "true"
    echo "MLAT_ENABLED set to true in $feed_env"
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done"
    else
        return 1
    fi
}

# Atomic single-key rewrite for MLAT_PRIVATE. Targeted (not generalized
# to arbitrary keys) so the `grep -vE` pattern stays a fixed literal and
# the boolean serializer (no shell-escape rules needed for true|false)
# stays distinct from MLAT_USER's escape rules.
#
# Refuses to write into a feed.env that hasn't yet been touched by
# update.sh's migrate_privacy_to_mlat_private — silently inserting
# MLAT_PRIVATE alongside legacy PRIVACY would cross update-migrations.sh's
# responsibility and produce a confusing mid-state.
_mlat_rewrite_feed_env_private() {
    local feed_env="$1"
    local new_value="$2"

    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"

    if ! grep -qE '^MLAT_PRIVATE=' "$feed_env"; then
        die "feed.env at $feed_env appears unmigrated (no MLAT_PRIVATE= line); run \`sudo /usr/local/share/airplanes/update.sh\` first"
    fi

    local tmp
    tmp="$(mktemp "${feed_env}.XXXXXX")"
    grep -vE '^MLAT_PRIVATE=' "$feed_env" > "$tmp" || true
    printf 'MLAT_PRIVATE=%s\n' "$new_value" >> "$tmp"
    chmod --reference="$feed_env" "$tmp" 2>/dev/null || true
    chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$feed_env"
}

apl_feed_mlat_private_enable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat private enable: $1" ;;
        esac
    done

    local feed_env
    feed_env="$(feed_env_path)"
    _mlat_rewrite_feed_env_private "$feed_env" "true"
    echo "MLAT_PRIVATE set to true in $feed_env (feed name will be hidden on the public MLAT map)"
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done"
    else
        return 1
    fi
}

apl_feed_mlat_private_disable() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat private disable: $1" ;;
        esac
    done

    local feed_env
    feed_env="$(feed_env_path)"
    _mlat_rewrite_feed_env_private "$feed_env" "false"
    echo "MLAT_PRIVATE set to false in $feed_env (feed name will be shown on the public MLAT map)"
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done"
    else
        return 1
    fi
}

# Geo gate. MLAT requires real coordinates AND a non-empty altitude. The
# canonical source-of-truth is GEO_CONFIGURED=true (set by configure.sh's
# derive_geo_configured and by webconfig's apply-config auto-derive). The
# explicit per-axis non-empty check is belt-and-braces against a feed.env
# hand-edited into an inconsistent state (e.g. cleared LATITUDE while
# GEO_CONFIGURED stayed true). Same business rule as the webconfig's
# ValidateConsistency for MLAT_ENABLED=true.
_mlat_require_geo() {
    local feed_env="$1"
    local geo lat lon alt
    geo="$(feed_env_get GEO_CONFIGURED 2>/dev/null || true)"
    lat="$(feed_env_get LATITUDE 2>/dev/null || true)"
    lon="$(feed_env_get LONGITUDE 2>/dev/null || true)"
    alt="$(feed_env_get ALTITUDE 2>/dev/null || true)"
    if [[ "$geo" != "true" ]]; then
        die "location not configured (GEO_CONFIGURED=${geo:-<unset>}); run \`sudo apl-feed mlat setup\` or \`sudo apl-feed mlat geo <lat> <lon> <alt>\` first"
    fi
    [[ -n "$lat" ]] || die "LATITUDE is empty in $feed_env; run \`sudo apl-feed mlat geo <lat> <lon> <alt>\`"
    [[ -n "$lon" ]] || die "LONGITUDE is empty in $feed_env; run \`sudo apl-feed mlat geo <lat> <lon> <alt>\`"
    [[ -n "$alt" ]] || die "ALTITUDE is empty in $feed_env; run \`sudo apl-feed mlat geo <lat> <lon> <alt>\`"
}

# Mirror feed/configure.sh:derive_geo_configured — both axes numerically
# zero (or empty) → "false", anything else → "true". The Atlantic (0,0)
# point is uninhabited so the false-negative blast radius is empty.
_mlat_geo_axis_unset_or_zero() {
    [[ -z "$1" ]] && return 0
    [[ "$1" =~ ^[+-]?0+(\.0+)?$ ]] && return 0
    return 1
}
_mlat_derive_geo_configured() {
    local lat="$1" lon="$2"
    if _mlat_geo_axis_unset_or_zero "$lat" && _mlat_geo_axis_unset_or_zero "$lon"; then
        printf 'false'
    else
        printf 'true'
    fi
}

# Reject every byte in webconfig configspec.go's universalReject set so a
# CLI-written value can never reach disk in a form that would re-trip
# shell-source by airplanes-feed.sh / airplanes-mlat.sh.
_mlat_check_universal() {
    local key="$1" value="$2"
    if [[ "$value" =~ [\"\\\$\`\;\&\|\<\>\#\'$'\n'$'\r'] ]]; then
        die "$key contains a forbidden shell metacharacter"
    fi
}

# Atomic single-key rewrite for MLAT_USER. Mirrors _mlat_rewrite_feed_env's
# pattern but touches only the MLAT_USER line — leaves MLAT_ENABLED alone.
_mlat_rewrite_feed_env_user() {
    local feed_env="$1" new_user="$2"

    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"
    if ! grep -qE '^MLAT_USER=' "$feed_env"; then
        die "feed.env at $feed_env appears unmigrated (no MLAT_USER= line); run \`sudo /usr/local/share/airplanes/update.sh\` first"
    fi

    local tmp escaped
    tmp="$(mktemp "${feed_env}.XXXXXX")"
    grep -vE '^MLAT_USER=' "$feed_env" > "$tmp" || true
    # Same escape rule as _mlat_rewrite_feed_env / migrate_user_to_mlat_split.
    escaped="${new_user//\\/\\\\}"
    escaped="${escaped//\$/\\\$}"
    escaped="${escaped//\`/\\\`}"
    escaped="${escaped//\"/\\\"}"
    printf 'MLAT_USER="%s"\n' "$escaped" >> "$tmp"
    chmod --reference="$feed_env" "$tmp" 2>/dev/null || true
    chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$feed_env"
}

# Atomic four-key rewrite for LATITUDE / LONGITUDE / ALTITUDE /
# GEO_CONFIGURED. Same migration-marker guard as the MLAT helpers — refuses
# to write into an unmigrated feed.env.
_mlat_rewrite_feed_env_geo() {
    local feed_env="$1" new_lat="$2" new_lon="$3" new_alt="$4" new_geo="$5"

    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"
    if ! grep -qE '^GEO_CONFIGURED=' "$feed_env"; then
        die "feed.env at $feed_env appears unmigrated (no GEO_CONFIGURED= line); run \`sudo /usr/local/share/airplanes/update.sh\` first"
    fi

    local tmp
    tmp="$(mktemp "${feed_env}.XXXXXX")"
    grep -vE '^(LATITUDE|LONGITUDE|ALTITUDE|GEO_CONFIGURED)=' "$feed_env" > "$tmp" || true
    # lat/lon/alt are pre-validated numeric / regex-matching strings; no
    # shell-escape needed. GEO_CONFIGURED is a literal true|false.
    {
        printf 'LATITUDE="%s"\n'  "$new_lat"
        printf 'LONGITUDE="%s"\n' "$new_lon"
        printf 'ALTITUDE="%s"\n'  "$new_alt"
        printf 'GEO_CONFIGURED=%s\n' "$new_geo"
    } >> "$tmp"
    chmod --reference="$feed_env" "$tmp" 2>/dev/null || true
    chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$feed_env"
}

# Setup-only seven-key transaction. Writes
# LATITUDE/LONGITUDE/ALTITUDE/GEO_CONFIGURED/MLAT_USER/MLAT_ENABLED/MLAT_PRIVATE
# in a single rewrite so a wizard run either commits the full new state or
# fails before touching disk. Preflights every migration marker so we don't
# enter the rewrite and then die halfway.
_mlat_rewrite_feed_env_setup() {
    local feed_env="$1" new_lat="$2" new_lon="$3" new_alt="$4" new_geo="$5"
    local new_user="$6" new_enabled="$7" new_private="$8"

    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"
    local key
    for key in MLAT_USER MLAT_ENABLED MLAT_PRIVATE GEO_CONFIGURED; do
        if ! grep -qE "^${key}=" "$feed_env"; then
            die "feed.env at $feed_env appears unmigrated (no ${key}= line); run \`sudo /usr/local/share/airplanes/update.sh\` first"
        fi
    done

    local tmp escaped
    tmp="$(mktemp "${feed_env}.XXXXXX")"
    grep -vE '^(LATITUDE|LONGITUDE|ALTITUDE|GEO_CONFIGURED|MLAT_USER|MLAT_ENABLED|MLAT_PRIVATE)=' "$feed_env" > "$tmp" || true
    # MLAT_USER may contain operator-supplied characters even after our
    # regex check — escape the same way migrate_user_to_mlat_split does.
    escaped="${new_user//\\/\\\\}"
    escaped="${escaped//\$/\\\$}"
    escaped="${escaped//\`/\\\`}"
    escaped="${escaped//\"/\\\"}"
    {
        printf 'LATITUDE="%s"\n'  "$new_lat"
        printf 'LONGITUDE="%s"\n' "$new_lon"
        printf 'ALTITUDE="%s"\n'  "$new_alt"
        printf 'GEO_CONFIGURED=%s\n' "$new_geo"
        printf 'MLAT_USER="%s"\n'   "$escaped"
        printf 'MLAT_ENABLED=%s\n'  "$new_enabled"
        printf 'MLAT_PRIVATE=%s\n'  "$new_private"
    } >> "$tmp"
    chmod --reference="$feed_env" "$tmp" 2>/dev/null || true
    chown --reference="$feed_env" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$feed_env"
}

apl_feed_mlat_user() {
    local clear=0 name="" name_set=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clear)
                clear=1
                shift ;;
            *)
                local opt_rc
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0)
                        if (( name_set )); then
                            die "mlat user takes a single positional name; got extra arg: $1"
                        fi
                        name="$1"
                        name_set=1
                        shift ;;
                esac
                ;;
        esac
    done

    if (( clear )); then
        (( name_set )) && die "mlat user: --clear and a positional name are mutually exclusive"
    else
        (( name_set )) || die "mlat user: provide a name or use --clear"
        [[ "$name" =~ $_MLAT_USER_RE ]] || die "MLAT_USER must match [A-Za-z0-9_-]{1,64}; reject \"$name\""
        _mlat_check_universal MLAT_USER "$name"
    fi

    local feed_env
    feed_env="$(feed_env_path)"
    _mlat_rewrite_feed_env_user "$feed_env" "$name"
    if (( clear )); then
        echo "MLAT_USER cleared in $feed_env (daemon will use Anonymous-<short-feeder-id> when MLAT is enabled)"
    else
        echo "MLAT_USER set to \"$name\" in $feed_env"
    fi
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done"
    else
        return 1
    fi
}

apl_feed_mlat_geo() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        # Negative numbers like `-0`, `-12.34`, `-.5` are positional even
        # though they begin with `-`. Match before the flag dispatch so a
        # caller can pass them without quoting tricks or `--`.
        case "$1" in
            -[0-9]*|-.[0-9]*)
                positional+=("$1"); shift ;;
            --|-h|--help|--root|--server-url|--max-retry-time)
                local opt_rc
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for mlat geo: $1" ;;
                esac
                ;;
            -*)
                die "unknown flag for mlat geo: $1" ;;
            *)
                positional+=("$1")
                shift ;;
        esac
    done

    (( ${#positional[@]} == 3 )) || die "mlat geo requires exactly three positional args: <lat> <lon> <alt>"
    local lat="${positional[0]}" lon="${positional[1]}" alt="${positional[2]}"

    valid_latitude  "$lat"  || die "LATITUDE must be a decimal number in (-90, 90)"
    valid_longitude "$lon"  || die "LONGITUDE must be a decimal number in (-180, 180)"
    valid_altitude  "$alt"  || die "ALTITUDE must be an integer with optional ft or m suffix"
    _mlat_check_universal LATITUDE  "$lat"
    _mlat_check_universal LONGITUDE "$lon"
    _mlat_check_universal ALTITUDE  "$alt"

    local norm_alt geo
    norm_alt="$(normalize_altitude "$alt")"
    geo="$(_mlat_derive_geo_configured "$lat" "$lon")"

    local feed_env
    feed_env="$(feed_env_path)"
    _mlat_rewrite_feed_env_geo "$feed_env" "$lat" "$lon" "$norm_alt" "$geo"
    echo "LATITUDE=\"$lat\" LONGITUDE=\"$lon\" ALTITUDE=\"$norm_alt\" GEO_CONFIGURED=$geo in $feed_env"
    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done"
    else
        return 1
    fi
}

# Interactive setup. Collects every input first (cancel-aware via Ctrl-C
# at any prompt; no partial writes), validates each before any disk mutation,
# then commits the full new state in a single atomic seven-key rewrite, with
# one final service restart. The `read -r -p` pattern matches
# `apl-feed 978 setup` — no whiptail dependency on standalone-feed boxes.
apl_feed_mlat_setup() {
    local opt_rc
    while [[ $# -gt 0 ]]; do
        if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
        case "$opt_rc" in
            1) shift ;;
            2) shift 2 ;;
            0) die "unknown flag for mlat setup: $1" ;;
        esac
    done

    if [[ ! -t 0 ]]; then
        die "mlat setup is interactive; for non-interactive use, run \`apl-feed mlat geo <lat> <lon> <alt>\` then \`apl-feed mlat user <name>\` (optional) then \`apl-feed mlat enable\`"
    fi

    # Precheck that configure-validators.sh is actually present (not stubbed)
    # so we don't drop the operator into a forever-loop where every input is
    # "Invalid; try again" because the validator returned 2.
    if ! valid_latitude "0" >/dev/null 2>&1; then
        die "configure-validators.sh missing from \$APL_FEED_DAEMON_LIB_DIR; reinstall feed before running \`apl-feed mlat setup\`"
    fi

    local feed_env
    feed_env="$(feed_env_path)"
    [[ -f "$feed_env" ]] || die "feed.env not found at $feed_env; run setup first"

    echo
    echo "Configure MLAT (multilateration) reception."
    echo "  MLAT needs your antenna position. The values you enter are used as"
    echo "  mlat-client's --lat/--lon/--alt. Real coordinates are required;"
    echo "  the Atlantic (0,0) placeholder will not be accepted."
    echo

    local lat lon alt name reply
    local current_lat current_lon current_alt current_user current_private
    current_lat="$(feed_env_get LATITUDE 2>/dev/null || true)"
    current_lon="$(feed_env_get LONGITUDE 2>/dev/null || true)"
    current_alt="$(feed_env_get ALTITUDE 2>/dev/null || true)"
    current_user="$(feed_env_get MLAT_USER 2>/dev/null || true)"
    current_private="$(feed_env_get MLAT_PRIVATE 2>/dev/null || true)"

    while :; do
        read -r -p "Latitude  (decimal, -90..90)${current_lat:+ [$current_lat]}: " lat
        lat="${lat:-$current_lat}"
        valid_latitude "$lat" && break
        echo "  Invalid; try again (e.g. 52.51666)." >&2
    done
    while :; do
        read -r -p "Longitude (decimal, -180..180)${current_lon:+ [$current_lon]}: " lon
        lon="${lon:-$current_lon}"
        valid_longitude "$lon" && break
        echo "  Invalid; try again (e.g. 13.37777)." >&2
    done
    if [[ "$(_mlat_derive_geo_configured "$lat" "$lon")" != "true" ]]; then
        die "lat=$lat lon=$lon: refusing to enable MLAT at the Atlantic (0,0) placeholder"
    fi
    while :; do
        read -r -p "Altitude  (integer; m or ft suffix, e.g. 120m, 400ft)${current_alt:+ [$current_alt]}: " alt
        alt="${alt:-$current_alt}"
        valid_altitude "$alt" && break
        echo "  Invalid; try again (e.g. 120m or 400ft)." >&2
    done

    # MLAT name prompt. Blank input keeps the current value only when the
    # current value already passes the strict regex — otherwise the prompt
    # forces the operator to either supply a valid name or `-` to clear.
    # This prevents a legacy `sanitize_mlat_user`-mangled name (spaces,
    # brackets) from quietly round-tripping through setup.
    local current_user_valid=0
    if [[ -z "$current_user" || "$current_user" =~ $_MLAT_USER_RE ]]; then
        current_user_valid=1
    fi
    while :; do
        local default_user_display
        if (( current_user_valid )); then
            default_user_display="${current_user:-<empty — daemon picks Anonymous-<short-feeder-id>>}"
        else
            default_user_display="<current \"$current_user\" is invalid; supply a new name or '-' to clear>"
        fi
        read -r -p "MLAT name (1-64 chars in [A-Za-z0-9_-], blank to keep current, '-' to clear) [$default_user_display]: " name
        if [[ -z "$name" ]]; then
            if (( current_user_valid )); then
                name="$current_user"
                break
            else
                echo "  Current MLAT_USER is invalid; please type a new name or '-' to clear." >&2
                continue
            fi
        elif [[ "$name" == "-" ]]; then
            name=""
            break
        elif [[ "$name" =~ $_MLAT_USER_RE ]]; then
            _mlat_check_universal MLAT_USER "$name"
            break
        else
            echo "  Invalid; try again (or blank to keep current, or '-' to clear)." >&2
        fi
    done

    # Privacy prompt. Default matches the current on-disk value so pressing
    # Enter is idempotent — a feeder running MLAT_PRIVATE=true is not flipped
    # back to public just because the operator re-ran setup and didn't read
    # the prompt closely.
    local private="${current_private:-false}"
    case "$private" in
        true|false) ;;
        *) private="false" ;;
    esac
    local privacy_prompt_default privacy_prompt_yes_no
    if [[ "$private" == "true" ]]; then
        privacy_prompt_default="Y"
        privacy_prompt_yes_no="[Y/n]"
    else
        privacy_prompt_default="N"
        privacy_prompt_yes_no="[y/N]"
    fi
    read -r -p "Hide name on the public MLAT map? $privacy_prompt_yes_no " reply
    case "${reply,,}" in
        ""|"${privacy_prompt_default,,}") ;;  # keep current default
        y|yes) private="true" ;;
        n|no)  private="false" ;;
        *)
            echo "  Unrecognized answer; keeping MLAT_PRIVATE=$private." >&2
            ;;
    esac

    local norm_alt
    norm_alt="$(normalize_altitude "$alt")"

    echo
    echo "About to write:"
    echo "  LATITUDE=$lat"
    echo "  LONGITUDE=$lon"
    echo "  ALTITUDE=$norm_alt"
    echo "  GEO_CONFIGURED=true"
    echo "  MLAT_USER=\"$name\""
    echo "  MLAT_PRIVATE=$private"
    echo "  MLAT_ENABLED=true"
    read -r -p "Proceed? [Y/n] " reply
    case "${reply,,}" in
        ""|y|yes) ;;
        *) echo "Aborted — no changes written."; return 0 ;;
    esac

    # Single seven-key transaction: pre-flight every migration marker, then
    # one atomic rewrite. Avoids the half-configured state that a sequence
    # of single-key rewrites would leave if any intermediate write failed.
    _mlat_rewrite_feed_env_setup \
        "$feed_env" "$lat" "$lon" "$norm_alt" "true" "$name" "true" "$private"
    echo "feed.env updated; MLAT enabled."

    if _mlat_restart_service; then
        echo "Restarting airplanes-mlat.service ... done"
    else
        return 1
    fi
}

dispatch_mlat_private() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "mlat private requires a subcommand (enable|disable)"
    shift || true
    case "$sub" in
        enable)  apl_feed_mlat_private_enable  "$@" ;;
        disable) apl_feed_mlat_private_disable "$@" ;;
        -h|--help) usage ;;
        *) die "unknown mlat private subcommand: $sub" ;;
    esac
}

dispatch_mlat() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "mlat requires a subcommand (enable|disable|setup|user|geo|private)"
    shift || true
    case "$sub" in
        enable)  apl_feed_mlat_enable  "$@" ;;
        disable) apl_feed_mlat_disable "$@" ;;
        setup)   apl_feed_mlat_setup   "$@" ;;
        user)    apl_feed_mlat_user    "$@" ;;
        geo)     apl_feed_mlat_geo     "$@" ;;
        private) dispatch_mlat_private "$@" ;;
        -h|--help) usage ;;
        *) die "unknown mlat subcommand: $sub" ;;
    esac
}

# Status reporting lives in `apl-feed status`, which reads the daemon's
# runtime state file via scripts/lib/state-reader.sh. A focused
# `apl-feed mlat status` would either duplicate that logic or violate
# the "CLI side does not re-derive predicates from feed.env" rule —
# neither pays back vs. just running `apl-feed status`.
