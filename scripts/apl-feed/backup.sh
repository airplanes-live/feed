#!/usr/bin/env bash

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
            --root|--server-url|--max-retry-time|-h|--help)
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
    [[ -n "$outfile" ]] || die "backup requires a file"
    [[ ! -e "$outfile" ]] || die "$outfile already exists"
    require_jq

    local uuid secret version tmp created_at
    uuid="$(read_uuid)"
    secret="$(read_secret_file "$(secret_final_path)")"
    version='null'
    created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if version_read="$(read_version_file 2>/dev/null)"; then
        version="$version_read"
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
    local infile=''
    local opt_rc check_only
    check_only=0
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
            --root|--server-url|--max-retry-time|-h|--help)
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
    [[ -n "$infile" ]] || die "restore requires a file"
    [[ -f "$infile" ]] || die "$infile does not exist"
    require_jq

    local existing_uuid existing_secret
    read_backup_file "$infile"

    if (( check_only )); then
        echo "Backup is valid."
        echo "Feeder ID: $BACKUP_UUID"
        if [[ -n "$BACKUP_CREATED_AT" ]]; then
            echo "Created: $BACKUP_CREATED_AT"
        fi
        if [[ -n "$BACKUP_VERSION" ]]; then
            echo "Version: $BACKUP_VERSION"
        fi
        echo "Claim secret: present"
        return 0
    fi

    if existing_uuid="$(read_uuid 2>/dev/null)"; then
        if [[ "$existing_uuid" != "$BACKUP_UUID" && "$FORCE" -ne 1 ]]; then
            die "local Feeder ID differs; rerun with --force to overwrite"
        fi
    fi
    if [[ -f "$(secret_final_path)" ]]; then
        existing_secret="$(read_secret_file "$(secret_final_path)")"
        if [[ "$existing_secret" != "$BACKUP_SECRET" && "$FORCE" -ne 1 ]]; then
            die "local claim secret differs; rerun with --force to overwrite"
        fi
    fi

    write_uuid "$BACKUP_UUID"
    write_secret_file "$(secret_final_path)" "$BACKUP_SECRET"
    if [[ -n "$BACKUP_VERSION" ]]; then
        write_version_file "$BACKUP_VERSION"
    else
        rm -f "$(secret_version_path)"
    fi
    rm -f "$(secret_pending_path)"
    echo "Restored feeder config for Feeder ID $BACKUP_UUID"
}
