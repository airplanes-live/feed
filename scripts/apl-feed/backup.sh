#!/usr/bin/env bash

usage_backup() {
    cat <<'USAGE'
Usage: apl-feed backup <file>|-

Writes a JSON backup of the feeder's claim secret and Feeder ID to <file>
(mode 0600), or to stdout when the path is '-'. Refuses to overwrite an
existing file.
USAGE
}

usage_restore() {
    cat <<'USAGE'
Usage:
  apl-feed restore <file>
  apl-feed restore --check <file>
  apl-feed restore --uuid <uuid> [--check]

Restores the claim secret and Feeder ID from a backup <file>, or with
--uuid takes the Feeder ID from the flag and reads a fresh secret from
stdin (the website-restore path) in one atomic two-file commit, then
restarts both daemons. --check validates the source without writing;
--force overwrites differing local state.
USAGE
}

read_backup_file() {
    local infile="$1"
    BACKUP_SCHEMA="$(jq -r '.schema_version // empty' < "$infile")"
    [[ "$BACKUP_SCHEMA" == "1" ]] || die "unsupported backup schema_version: ${BACKUP_SCHEMA:-<missing>}"
    BACKUP_CREATED_AT="$(jq -r '.created_at // empty' < "$infile")"
    BACKUP_UUID_RAW="$(jq -r '.feeder_uuid // empty' < "$infile")"
    BACKUP_UUID="$(printf '%s' "$BACKUP_UUID_RAW" | tr -d '{}[:space:]' | tr 'A-F' 'a-f')"
    [[ "$BACKUP_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || die "invalid feeder_uuid in restore file"
    BACKUP_SECRET_RAW="$(jq -r '.claim.secret // empty' < "$infile")"
    BACKUP_SECRET="$(canonicalize_secret "$BACKUP_SECRET_RAW")"
    validate_secret "$BACKUP_SECRET" || die "invalid claim.secret in restore file"
    BACKUP_VERSION="$(jq -r '.claim.version // empty' < "$infile")"
    if [[ -n "$BACKUP_VERSION" && ! "$BACKUP_VERSION" =~ ^[0-9]+$ ]]; then
        die "invalid claim.version in restore file"
    fi
}

config_backup() {
    local outfile=''
    local opt_rc version_read
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                die "unknown flag for backup: --force"
                ;;
            -h|--help)
                usage_backup; exit 0 ;;
            --root|--website-url|--max-retry-time)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for backup: $1" ;;
                esac
                ;;
            --*)
                die "unknown flag for backup: $1"
                ;;
            *)
                if [[ -n "$outfile" ]]; then
                    die "backup accepts exactly one file"
                fi
                outfile="$1"
                shift
                ;;
        esac
    done
    [[ -n "$outfile" ]] || usage_error usage_backup "backup requires a file (use '-' for stdout)"
    local stdout_mode=0
    if [[ "$outfile" == "-" ]]; then
        stdout_mode=1
    else
        [[ ! -e "$outfile" ]] || die "$outfile already exists"
    fi
    require_jq

    local uuid secret version tmp created_at
    uuid="$(read_uuid)"
    secret="$(read_secret_file "$(secret_final_path)")"
    version='null'
    created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if version_read="$(read_version_file 2>/dev/null)"; then
        version="$version_read"
    fi

    if (( stdout_mode )); then
        # Pipe-friendly mode for callers that consume the JSON directly
        # (e.g. the on-device webconfig's export wrapper). No tempfile,
        # no permissions to manage, no trailing confirmation message —
        # stdout is reserved for the JSON payload.
        if [[ "$version" == "null" ]]; then
            jq -n \
                --arg created_at "$created_at" \
                --arg feeder_uuid "$uuid" \
                --arg secret "$secret" \
                '{schema_version:1, created_at:$created_at, feeder_uuid:$feeder_uuid, claim:{secret:$secret, version:null}}'
        else
            jq -n \
                --arg created_at "$created_at" \
                --arg feeder_uuid "$uuid" \
                --arg secret "$secret" \
                --argjson version "$version" \
                '{schema_version:1, created_at:$created_at, feeder_uuid:$feeder_uuid, claim:{secret:$secret, version:$version}}'
        fi
        return 0
    fi

    tmp="${outfile}.$$"
    umask 077
    if [[ "$version" == "null" ]]; then
        jq -n \
            --arg created_at "$created_at" \
            --arg feeder_uuid "$uuid" \
            --arg secret "$secret" \
            '{schema_version:1, created_at:$created_at, feeder_uuid:$feeder_uuid, claim:{secret:$secret, version:null}}' \
            > "$tmp"
    else
        jq -n \
            --arg created_at "$created_at" \
            --arg feeder_uuid "$uuid" \
            --arg secret "$secret" \
            --argjson version "$version" \
            '{schema_version:1, created_at:$created_at, feeder_uuid:$feeder_uuid, claim:{secret:$secret, version:$version}}' \
            > "$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$outfile"
    echo "Backed up feeder config to $outfile"
}

config_restore() {
    # Two source forms, mutually exclusive:
    #   apl-feed restore <backup-file>       - read UUID + secret from a
    #                                          JSON file produced by `backup`
    #   apl-feed restore --uuid <UUID>       - take UUID from the flag,
    #                                          read secret from stdin
    #                                          (TTY prompt or pipe). The
    #                                          website-restore-without-backup
    #                                          flow.
    #
    # Both forms support `--check` (validate without writing) and
    # `--force` (overwrite differing local UUID / secret).
    #
    # Atomicity: writes the UUID first, then the secret. If the secret
    # write fails after the UUID write succeeded, rolls the UUID back
    # to its prior bytes (or removes it if there was none) so the
    # feeder doesn't end up advertising a UUID without a working secret.
    #
    # Restart: when the UUID actually changes, restarts both
    # airplanes-feed and airplanes-mlat (both consume the UUID).
    # Restart failure is reported separately from write failure.
    local infile='' uuid_arg=''
    local opt_rc check_only=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                check_only=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --uuid)
                [[ $# -ge 2 ]] || die "--uuid requires VALUE"
                uuid_arg="$2"
                shift 2
                ;;
            -h|--help)
                usage_restore; exit 0 ;;
            --root|--website-url|--max-retry-time)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for restore: $1" ;;
                esac
                ;;
            --*)
                die "unknown flag for restore: $1"
                ;;
            *)
                if [[ -n "$infile" ]]; then
                    die "restore accepts exactly one file"
                fi
                infile="$1"
                shift
                ;;
        esac
    done

    if [[ -n "$uuid_arg" && -n "$infile" ]]; then
        die "restore: --uuid and a backup file are mutually exclusive"
    fi
    if [[ -z "$uuid_arg" && -z "$infile" ]]; then
        usage_error usage_restore "restore requires --uuid <UUID> or a backup file"
    fi

    if [[ -n "$infile" ]]; then
        [[ -f "$infile" ]] || die "$infile does not exist"
        require_jq
        read_backup_file "$infile"
    else
        BACKUP_UUID="$(canonicalize_uuid "$uuid_arg")" \
            || die "invalid --uuid value (expected 8-4-4-4-12 hex)"
        local raw
        if [[ -t 0 ]]; then
            echo "Paste the claim secret from your account dashboard." >&2
            echo "Format: ABCD-EFGH-IJKL-MNOP (hyphens and case are ignored)" >&2
            printf 'Secret: ' >&2
            IFS= read -r raw </dev/tty || true
        else
            raw="$(cat)"
        fi
        [[ -n "$raw" ]] || die "no secret provided on stdin"
        BACKUP_SECRET="$(canonicalize_secret "$raw")"
        validate_secret "$BACKUP_SECRET" \
            || die "invalid claim secret format (expected 16 chars A-Z 0-9 after canonicalization)"
        BACKUP_VERSION=''
        BACKUP_CREATED_AT=''
    fi

    if (( check_only )); then
        if [[ -n "$infile" ]]; then
            echo "Backup is valid."
        else
            echo "Inputs are valid."
        fi
        echo "Feeder ID: $BACKUP_UUID"
        if [[ -n "$BACKUP_CREATED_AT" ]]; then
            echo "Created: $BACKUP_CREATED_AT"
        fi
        if [[ -n "$BACKUP_VERSION" ]]; then
            echo "Secret version: $BACKUP_VERSION"
        fi
        echo "Claim secret: present"
        return 0
    fi

    local existing_uuid='' existing_secret=''
    if existing_uuid="$(read_uuid 2>/dev/null)"; then
        if [[ "$existing_uuid" != "$BACKUP_UUID" && "$FORCE" -ne 1 ]]; then
            die "local Feeder ID differs; rerun with --force to overwrite"
        fi
    else
        existing_uuid=''
    fi
    if [[ -f "$(secret_final_path)" ]]; then
        existing_secret="$(read_secret_file "$(secret_final_path)")"
        if [[ "$existing_secret" != "$BACKUP_SECRET" && "$FORCE" -ne 1 ]]; then
            die "local claim secret differs; rerun with --force to overwrite"
        fi
    fi

    # Snapshot the previous UUID file bytes so we can roll back if the
    # secret write fails after the UUID write succeeded. write_uuid only
    # ever writes the canonical 8-4-4-4-12 + newline form, so capturing
    # the canonical value via read_uuid (above) is sufficient.
    write_uuid "$BACKUP_UUID"
    if ! write_secret_file "$(secret_final_path)" "$BACKUP_SECRET"; then
        echo "Secret write failed — rolling back Feeder ID change." >&2
        if [[ -n "$existing_uuid" ]]; then
            write_uuid "$existing_uuid"
        else
            rm -f "$(feeder_id_path)"
        fi
        die "restore aborted; local state restored to its previous values"
    fi

    if [[ -n "$BACKUP_VERSION" ]]; then
        write_version_file "$BACKUP_VERSION"
    else
        rm -f "$(secret_version_path)"
    fi
    rm -f "$(secret_pending_path)"
    echo "Restored feeder config for Feeder ID $BACKUP_UUID"

    # Claim secret is on disk — nudge config-sync so a remote-config-enabled
    # feeder picks up its server-side configuration within seconds instead of
    # the unit's ~60s timer tick. Nudge-only (restore doesn't manage the claim
    # retry timer); the service self-gates on the opt-in.
    nudge_config_sync_if_present

    if [[ "$existing_uuid" != "$BACKUP_UUID" ]]; then
        if ! restart_feeder_services; then
            echo "Saved, but service restart failed — daemons may still advertise the old Feeder ID until you restart them manually." >&2
            return 1
        fi
    fi
}
