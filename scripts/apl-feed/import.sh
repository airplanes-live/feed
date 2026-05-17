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
# Legacy → canonical mapping. PRIVACY / MLAT_MARKER recognition lives in
# scripts/lib/legacy-mlat-translation.sh (single source of truth, shared
# with the update-time migration and the daemon read fallback); the
# MLAT_ENABLED gating happens in this file. Unrecognised PRIVACY /
# MLAT_MARKER values leave MLAT_PRIVATE untouched rather than coercing
# to false — never silently flip a previously-private feeder.
#
#   LATITUDE / LONGITUDE / ALTITUDE          preserved as-is
#   USER=<name> + geo complete                MLAT_USER=<name>, MLAT_ENABLED=true
#   USER=<name> + geo missing/(0,0)           MLAT_USER=<name>  (MLAT_ENABLED dropped)
#   USER="" + geo complete                    MLAT_USER="",     MLAT_ENABLED=true
#   USER=0 / USER=disable                     MLAT_USER="",     MLAT_ENABLED=false
#   PRIVACY=--privacy                         MLAT_PRIVATE=true
#   PRIVACY="" / no / false / 0               MLAT_PRIVATE=false
#   PRIVACY=<other>                           MLAT_PRIVATE unchanged
#   MLAT_MARKER=no                            MLAT_PRIVATE=true   (inverted polarity)
#   MLAT_MARKER=yes / true / 1                MLAT_PRIVATE=false
#   MLAT_MARKER=<other>                       MLAT_PRIVATE unchanged
#   GAIN                                      preserved as-is (validated)
#   UAT_INPUT / DUMP978_SDR_SERIAL / DUMP978_GAIN   preserved as-is (validated)
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
            -*)
                # parse_common_option owns --root, --website-url, etc.
                # Check it BEFORE rejecting as unknown so chroot / build /
                # test callers can pass `--root /mnt` to redirect paths.
                local opt_rc
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for import legacy-config: $1" ;;
                esac
                ;;
            *)
                if [[ -z "$path" ]]; then
                    path="$1"
                    shift
                else
                    die "import legacy-config takes exactly one path"
                fi
                ;;
        esac
    done

    [[ -n "$path" ]] || die "usage: apl-feed import legacy-config <path>"
    [[ -f "$path" ]] || die "$path not found"

    local -A payload=()
    local v

    # Geo + gain + 978 keys: passthrough through the matching validator
    # so a legacy file with a stray bad value (e.g. GAIN=bad) doesn't
    # fail the entire import. The library would have rejected the whole
    # payload — costing the operator every other valid setting that was
    # otherwise importable. configure-validators.sh is sourced upstream
    # by apl-feed.sh; the fallback messaging there fires if the lib was
    # not installed.
    declare -A _import_validators=(
        [LATITUDE]=valid_latitude
        [LONGITUDE]=valid_longitude
        [ALTITUDE]=valid_altitude
        [GAIN]=valid_gain
        [UAT_INPUT]=valid_uat_input
        [DUMP978_SDR_SERIAL]=valid_dump978_serial
        [DUMP978_GAIN]=valid_dump978_gain
    )
    local k validator
    for k in LATITUDE LONGITUDE ALTITUDE GAIN UAT_INPUT DUMP978_SDR_SERIAL DUMP978_GAIN; do
        # Gate on key PRESENCE, not value non-emptiness. valid_uat_input,
        # valid_dump978_serial, and valid_mlat_user accept empty as a
        # meaningful payload (clear the key). A legacy file containing
        # `UAT_INPUT=` should propagate that as MLAT_INPUT="" so 978-
        # disable saves on the legacy webconfig actually clear the daemon
        # state — a value-non-empty gate would silently drop those.
        grep -qE "^${k}=" "$path" || continue
        v="$(_apl_feed_import_extract "$path" "$k")"
        validator="${_import_validators[$k]}"
        if "$validator" "$v" >/dev/null 2>&1; then
            payload[$k]="$v"
        else
            echo "import legacy-config: skipping $k=$v (invalid per $validator)" >&2
        fi
    done

    # USER → MLAT_USER + MLAT_ENABLED.
    #
    # MLAT_ENABLED=true is only set when the legacy file carries a complete,
    # validatable geo state: LATITUDE / LONGITUDE / ALTITUDE all in the
    # payload (i.e. all passed per-key validation above) and the (lat, lon)
    # pair is not the (0, 0) placeholder. Without this gate, a legacy box
    # whose geo is missing, invalid, or still at default-zero would be
    # force-imported with MLAT_ENABLED=true, hit apl_feed_apply's MLAT-vs-
    # geo consistency check, and reject the entire bootstrap — meaning
    # the operator couldn't even `apl-feed mlat disable` to recover (the
    # auto-bootstrap fails before their explicit intent applies). When
    # geo is incomplete, USER still maps to MLAT_USER; MLAT_ENABLED is
    # omitted from the payload, so disk stays at its default.
    #
    # USER=0 / USER=disable still maps to MLAT_ENABLED=false unconditionally
    # — explicit disable doesn't need geo to apply.
    local geo_complete=0
    if [[ -n "${payload[LATITUDE]+set}" \
       && -n "${payload[LONGITUDE]+set}" \
       && -n "${payload[ALTITUDE]+set}" ]] \
       && ! { [[ "${payload[LATITUDE]}" =~ ^[+-]?0+(\.0+)?$ ]] \
           && [[ "${payload[LONGITUDE]}" =~ ^[+-]?0+(\.0+)?$ ]]; }; then
        geo_complete=1
    fi
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
                (( geo_complete )) && payload[MLAT_ENABLED]="true"
                ;;
            *)
                # Strict regex — silently drop on shape mismatch so an
                # illegible legacy username doesn't fail the whole import.
                if [[ "$user_value" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
                    payload[MLAT_USER]="$user_value"
                    (( geo_complete )) && payload[MLAT_ENABLED]="true"
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
            true)
                # Same geo-complete gate as the USER block above —
                # MLAT_ENABLED=true requires geo per apply's
                # consistency check, so a legacy file with stale
                # MLAT_ENABLED=true plus missing/invalid geo would
                # block the bootstrap. false is always safe.
                (( geo_complete )) && payload[MLAT_ENABLED]="true"
                ;;
            false) payload[MLAT_ENABLED]="false" ;;
        esac
    fi

    # MLAT_MARKER → MLAT_PRIVATE (inverted polarity: "no" = privacy ON).
    # Translation lives in scripts/lib/legacy-mlat-translation.sh, shared
    # with the update-time migration and the daemon runtime fallback.
    # Unrecognised values are dropped (MLAT_PRIVATE not added to payload)
    # rather than silently flipping to false — that would lose the
    # operator's stored preference on migration.
    if grep -qE '^MLAT_MARKER=' "$path"; then
        local marker derived
        marker="$(_apl_feed_import_extract "$path" MLAT_MARKER)"
        if derived="$(derive_mlat_private_from_marker "$marker")"; then
            payload[MLAT_PRIVATE]="$derived"
        else
            echo "import legacy-config: unrecognised MLAT_MARKER '$marker'; leaving MLAT_PRIVATE unchanged" >&2
        fi
    fi
    # PRIVACY → MLAT_PRIVATE. Wins over MLAT_MARKER when both are present
    # (PHP webconfig is still the active writer of marker, but PRIVACY is
    # the more deliberate hand-edit signal).
    if grep -qE '^PRIVACY=' "$path"; then
        local privacy derived
        privacy="$(_apl_feed_import_extract "$path" PRIVACY)"
        if derived="$(derive_mlat_private_from_privacy "$privacy")"; then
            payload[MLAT_PRIVATE]="$derived"
        else
            echo "import legacy-config: unrecognised PRIVACY value '$privacy'; leaving MLAT_PRIVATE unchanged" >&2
        fi
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

    # feed_env_write_path() is canonical-only; never resolves to the
    # bridged-legacy fallback /boot/airplanes-config.txt (which would
    # mean translating the source file into itself).
    local feed_env_file lock_file
    feed_env_file="$(feed_env_write_path)"
    lock_file="$(feed_env_lock_path)"

    # No recognised keys in the source: nothing to write. Return BEFORE
    # invoking apply so we don't create a canonical feed.env via
    # --create-if-missing for no useful reason. The legacy fallback in
    # feed_env_path() stays available for status readers.
    if (( ${#payload[@]} == 0 )); then
        echo "import legacy-config: no recognised keys in $path"
        return 0
    fi

    # --create-if-missing makes the bootstrap atomic. The library creates
    # the file inside its own lock before reading, so there is no
    # check-then-create race with a concurrent writer. On rejection /
    # filesystem_error the library never writes, so no empty canonical
    # file is left behind — no import-side cleanup needed.
    local -a args=()
    args+=(--feed-env "$feed_env_file" --lock-file "$lock_file" --create-if-missing)
    # Skip restarts in two cases: explicit --no-restart from the caller
    # (airplanes-first-run passes this so the same script doesn't try to
    # restart units that have After=airplanes-first-run.service), or when
    # ROOT != "/" (build-mode / tests).
    if (( no_restart )) || [[ "$ROOT" != "/" ]]; then
        args+=(--no-restart)
        if [[ "$ROOT" != "/" ]]; then
            echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
        fi
    fi
    # Audit gating is orthogonal to restart gating — a host-rootfs
    # --no-restart (airplanes-first-run) still audits; only scratch
    # rootfs invocations skip audit.
    if [[ "$ROOT" != "/" ]]; then
        args+=(--no-audit)
    fi
    for k in "${!payload[@]}"; do
        args+=("$k=${payload[$k]}")
    done

    IMPORT_APPLY_RC=0
    apl_feed_apply "${args[@]}" || IMPORT_APPLY_RC=$?

    case "$APL_APPLY_STATUS" in
        applied)
            echo "import legacy-config: applied ${#APL_APPLY_CHANGED[@]} key(s)"
            apl_feed_apply_emit_meta_warning
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
            return 1
            ;;
        *)
            echo "import legacy-config: apply ${APL_APPLY_STATUS:-failed}: ${APL_APPLY_ERROR_MESSAGE:-}" >&2
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
