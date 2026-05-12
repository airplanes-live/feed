#!/usr/bin/env bash
# `apl-feed import legacy-config [--no-restart] <PATH>` — translate a legacy
# /boot/airplanes-config.txt-shaped file into the canonical feed.env
# schema and write it via apl_feed_apply. Always targets the canonical
# /etc/airplanes/feed.env path on the host (never the source path),
# so a bridged-legacy box ends up with a real feed.env the new daemons
# can source.
#
# Used by `airplanes-first-run` on the legacy-bridge image stack so a
# legacy webconfig save (which still writes to /boot/airplanes-config.txt)
# produces a canonical feed.env via the same writer webconfig uses on the
# new image. Legacy-key parsing lives here so feed/ remains the sole
# owner of the feed.env schema; airplanes-first-run becomes a thin shim
# that detects the boot file and shells in.
#
# `--no-restart` suppresses the post-write service restart. airplanes-
# first-run passes this because the legacy services have
# `After=airplanes-first-run.service`; restarting them from inside first-
# run would either race (Type=simple) or deadlock (Type=oneshot). The
# caller (the webconfig save path, or systemd at boot) restarts on its
# own schedule.
#
# Legacy → canonical mapping:
#   LATITUDE / LONGITUDE / ALTITUDE          preserved as-is
#   USER=<name>  / USER=""                    MLAT_USER=<name>, MLAT_ENABLED=true
#   USER=0 / USER=disable                     MLAT_USER="",     MLAT_ENABLED=false
#   MLAT_MARKER=no                            MLAT_PRIVATE=true   (inverted polarity)
#   MLAT_MARKER=<other>                       MLAT_PRIVATE=false
#   PRIVACY=yes|true|1                        MLAT_PRIVATE=true
#   PRIVACY=<other>                           MLAT_PRIVATE=false
#   GAIN                                      preserved as-is
#   UAT_INPUT / DUMP978_SDR_SERIAL / DUMP978_GAIN   preserved as-is
#
# Permissive by design: an unparseable legacy value is silently dropped
# rather than failing the import — the failure mode on a legacy box
# should never leave feed.env empty when a partial config was available.
# apl_feed_apply still applies the universal-reject scan, so unsafe
# values can't slip through.

# Safe single-key extraction from an env-style file. Mirrors
# update-migrations.sh:_extract_env_value (which we can't source from
# here because that lib pulls in update-time deps). Last occurrence
# wins. Strips trailing CR + comment-after-bare-value + outer quotes.
_apl_feed_import_extract() {
    local path="$1" key="$2" raw line value
    raw="$(grep -E "^${key}=" "$path" 2>/dev/null | tail -n 1)" || true
    [[ -z "$raw" ]] && return 0
    line="${raw#${key}=}"
    line="${line%$'\r'}"
    # Quote-aware: KEY="value" / KEY='value' / KEY=value-with-trailing-ws.
    if [[ "$line" =~ ^\"([^\"]*)\"[[:space:]]*$ ]]; then
        value="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^\'([^\']*)\'[[:space:]]*$ ]]; then
        value="${BASH_REMATCH[1]}"
    else
        # Bare value: strip trailing whitespace + ` # …` comment.
        value="${line%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
    fi
    printf '%s' "$value"
}

apl_feed_import_legacy_config() {
    local path=""
    local no_restart=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; return 0 ;;
            --no-restart)
                no_restart=1
                shift
                ;;
            --)
                shift
                if [[ -n "${1:-}" ]]; then
                    [[ -z "$path" ]] || die "import legacy-config takes exactly one path"
                    path="$1"
                    shift
                fi
                break
                ;;
            -*) die "unknown flag for import legacy-config: $1" ;;
            *)
                local opt_rc
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0)
                        if [[ -z "$path" ]]; then
                            path="$1"
                            shift
                        else
                            die "import legacy-config takes exactly one path"
                        fi
                        ;;
                esac
                ;;
        esac
    done

    [[ -n "$path" ]] || die "usage: apl-feed import legacy-config <path>"
    [[ -f "$path" ]] || die "$path not found"

    local -A payload=()
    local v

    # Geo + gain + 978 keys: passthrough.
    local k
    for k in LATITUDE LONGITUDE ALTITUDE GAIN UAT_INPUT DUMP978_SDR_SERIAL DUMP978_GAIN; do
        v="$(_apl_feed_import_extract "$path" "$k")"
        if [[ -n "$v" ]]; then
            payload[$k]="$v"
        fi
    done

    # USER → MLAT_USER + MLAT_ENABLED.
    if grep -qE '^USER=' "$path"; then
        local user_value
        user_value="$(_apl_feed_import_extract "$path" USER)"
        case "$user_value" in
            0|disable)
                payload[MLAT_USER]=""
                payload[MLAT_ENABLED]="false"
                ;;
            '')
                payload[MLAT_USER]=""
                payload[MLAT_ENABLED]="true"
                ;;
            *)
                # Strict regex — silently drop on shape mismatch so an
                # illegible legacy username doesn't fail the whole import.
                if [[ "$user_value" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
                    payload[MLAT_USER]="$user_value"
                    payload[MLAT_ENABLED]="true"
                fi
                ;;
        esac
    fi

    # MLAT_USER passthrough (already-canonical legacy file).
    if grep -qE '^MLAT_USER=' "$path"; then
        v="$(_apl_feed_import_extract "$path" MLAT_USER)"
        if [[ -z "$v" || "$v" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
            payload[MLAT_USER]="$v"
        fi
    fi
    if grep -qE '^MLAT_ENABLED=' "$path"; then
        v="$(_apl_feed_import_extract "$path" MLAT_ENABLED)"
        case "$v" in
            true|false) payload[MLAT_ENABLED]="$v" ;;
        esac
    fi

    # MLAT_MARKER → MLAT_PRIVATE (inverted polarity: "no" = privacy ON).
    if grep -qE '^MLAT_MARKER=' "$path"; then
        local marker
        marker="$(_apl_feed_import_extract "$path" MLAT_MARKER)"
        case "$marker" in
            no) payload[MLAT_PRIVATE]="true" ;;
            *)  payload[MLAT_PRIVATE]="false" ;;
        esac
    fi
    # PRIVACY → MLAT_PRIVATE. Wins over MLAT_MARKER when both are present.
    if grep -qE '^PRIVACY=' "$path"; then
        local privacy
        privacy="$(_apl_feed_import_extract "$path" PRIVACY)"
        case "$privacy" in
            yes|true|1) payload[MLAT_PRIVATE]="true" ;;
            *)          payload[MLAT_PRIVATE]="false" ;;
        esac
    fi
    # MLAT_PRIVATE passthrough wins over both.
    if grep -qE '^MLAT_PRIVATE=' "$path"; then
        v="$(_apl_feed_import_extract "$path" MLAT_PRIVATE)"
        case "$v" in
            true|false) payload[MLAT_PRIVATE]="$v" ;;
        esac
    fi

    # GEO_CONFIGURED inference: pulled from the merged lat/lon. The
    # library auto-derives this too, but the legacy import may carry
    # an explicit value (e.g. when called recursively on a feed.env that
    # was already migrated once).
    if grep -qE '^GEO_CONFIGURED=' "$path"; then
        v="$(_apl_feed_import_extract "$path" GEO_CONFIGURED)"
        case "$v" in
            true|false) payload[GEO_CONFIGURED]="$v" ;;
        esac
    fi

    # Import always writes to the canonical /etc/airplanes/feed.env, never
    # via the feed_env_path() reader fallback. That fallback is for status
    # readers on bridged-legacy boxes (airplanes-feeder binary present, no
    # feed.env yet) and resolves to /boot/airplanes-config.txt — which for
    # this writer would mean translating the source file into itself,
    # never creating the canonical feed.env the new daemons consume.
    local feed_env_file lock_file
    feed_env_file="$(root_path '/etc/airplanes/feed.env')"
    lock_file="$(feed_env_lock_path)"

    # No recognised keys in the source: nothing to write. Return BEFORE
    # creating any file on disk — leaving an empty canonical feed.env
    # behind would defeat the bridged-legacy fallback in feed_env_path()
    # (status readers would see empty canonical state instead of falling
    # back to the still-populated /boot/airplanes-config.txt).
    if (( ${#payload[@]} == 0 )); then
        echo "import legacy-config: no recognised keys in $path"
        return 0
    fi

    # apl_feed_apply rejects on missing feed.env. The legacy boot path
    # may be invoked before any feed.env exists at all (e.g. on the
    # first reboot after a bridge update) — pre-create an empty file so
    # the library has somewhere to merge into. Track whether we created
    # it so a rejected/filesystem_error apply can remove it instead of
    # leaving an empty file behind that would suppress the legacy
    # fallback for status readers.
    local pre_created=0
    if [[ ! -f "$feed_env_file" ]]; then
        mkdir -p "$(dirname "$feed_env_file")"
        : > "$feed_env_file"
        pre_created=1
    fi

    local -a args=()
    args+=(--feed-env "$feed_env_file" --lock-file "$lock_file")
    # Skip restarts in three cases: explicit --no-restart from the caller
    # (airplanes-first-run passes this so the same script doesn't try to
    # restart units that have After=airplanes-first-run.service), or when
    # ROOT != "/" (build-mode / tests).
    if (( no_restart )) || [[ "$ROOT" != "/" ]]; then
        args+=(--no-restart)
        if [[ "$ROOT" != "/" ]]; then
            echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
        fi
    fi
    for k in "${!payload[@]}"; do
        args+=("$k=${payload[$k]}")
    done

    IMPORT_APPLY_RC=0
    apl_feed_apply "${args[@]}" || IMPORT_APPLY_RC=$?

    # Clean up a pre-created empty feed.env on any non-success path so the
    # legacy fallback in feed_env_path() stays available. Only safe when
    # we created it AND it is still empty — a concurrent writer that
    # populated the file (under the apply lock) must not lose their
    # write here.
    local _import_cleanup_pre_created=0
    if (( pre_created )) \
        && [[ "$APL_APPLY_STATUS" != "applied" && "$APL_APPLY_STATUS" != "no_change" ]] \
        && [[ -f "$feed_env_file" && ! -s "$feed_env_file" ]]; then
        _import_cleanup_pre_created=1
    fi

    case "$APL_APPLY_STATUS" in
        applied)
            echo "import legacy-config: applied ${#APL_APPLY_CHANGED[@]} key(s)"
            return 0
            ;;
        no_change)
            echo "import legacy-config: no change"
            return 0
            ;;
        rejected)
            local rk
            for rk in "${!APL_APPLY_ERRORS[@]}"; do
                echo "import legacy-config: $rk: ${APL_APPLY_ERRORS[$rk]}" >&2
            done
            (( _import_cleanup_pre_created )) && rm -f "$feed_env_file"
            return 1
            ;;
        *)
            echo "import legacy-config: apply ${APL_APPLY_STATUS:-failed}: ${APL_APPLY_ERROR_MESSAGE:-}" >&2
            (( _import_cleanup_pre_created )) && rm -f "$feed_env_file"
            return 1
            ;;
    esac
}

dispatch_import() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || die "import requires a subcommand (legacy-config)"
    shift || true
    case "$sub" in
        legacy-config) apl_feed_import_legacy_config "$@" ;;
        -h|--help) usage ;;
        *) die "unknown import subcommand: $sub" ;;
    esac
}
