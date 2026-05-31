#!/usr/bin/env bash

# Feeder identity (UUID) management — sibling of claim.sh.
#
# Today only `set` is exposed; future subcommands (e.g. `id show`,
# `id rotate`) can land here without touching apl-feed.sh's dispatcher.

id_set() {
    # Save a feeder UUID supplied by the user (typically copied from the
    # website's Reinstall Feeder action) and restart both feeder daemons
    # so the new identity propagates to upstream services.
    #
    # Both `airplanes-feed` and `airplanes-mlat` read the UUID via
    # `--uuid-file=$FEEDER_ID_FILE` at startup, so a UUID change requires
    # a restart of both.
    #
    # Refuses to overwrite a different existing UUID without `--force`,
    # to defend against fat-fingered support entries that would
    # disconnect a live feeder from its history.
    local opt_rc force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_id_set; exit 0 ;;
            --force)
                # shellcheck disable=SC2034  # tracked locally; not exported
                force=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            *)
                if parse_common_option "$@"; then opt_rc=0; else opt_rc=$?; fi
                case "$opt_rc" in
                    1) shift ;;
                    2) shift 2 ;;
                    0) die "unknown flag for id set: $1" ;;
                esac
                ;;
        esac
    done

    local raw uuid existing existing_raw final
    final="$(feeder_id_path)"

    if [[ -t 0 ]]; then
        echo "Paste the Feeder ID from your account dashboard." >&2
        echo "Format: 8-4-4-4-12 lowercase hex (e.g. 11111111-2222-3333-4444-555555555555)" >&2
        printf 'Feeder ID: ' >&2
        IFS= read -r raw </dev/tty || true
    else
        raw="$(cat)"
    fi

    [[ -n "$raw" ]] || die "no input provided"

    uuid="$(canonicalize_uuid "$raw")" \
        || die "invalid Feeder ID format (expected 8-4-4-4-12 hex digits)"

    # Read any existing UUID without dying on malformed contents — `--force`
    # must be able to repair a corrupt file.
    existing=""
    if [[ -f "$final" ]] && IFS= read -r existing_raw < "$final" 2>/dev/null; then
        existing="$(canonicalize_uuid "$existing_raw" 2>/dev/null || true)"
    fi

    if [[ -f "$final" && -z "$existing" ]] && (( ! force )); then
        die "existing Feeder ID file is malformed or unreadable; re-run with --force to replace it"
    fi
    if [[ -n "$existing" && "$existing" != "$uuid" ]] && (( ! force )); then
        die "a different Feeder ID is already saved on this feeder; re-run with --force to replace it"
    fi

    if [[ -n "$existing" && "$existing" == "$uuid" ]]; then
        # Same canonical value already on disk. Re-write to normalize byte
        # contents (case / whitespace) and the file mode, but no service
        # restart — nothing observable changed.
        if (( DRY_RUN )); then
            echo "(dry-run; Feeder ID already matches — would normalize file in place)"
            return 0
        fi
        write_uuid "$uuid"
        echo "Feeder ID already matches — no change."
        return 0
    fi

    # Visible OLD -> NEW print so the user can catch a paste-error before
    # a service restart blows away their working feeder identity.
    if [[ -n "$existing" ]]; then
        echo "Feeder ID change:"
        echo "  Old: $existing"
        echo "  New: $uuid"
    else
        echo "Feeder ID: $uuid (no previous ID on this feeder)"
    fi

    if (( DRY_RUN )); then
        echo "(dry-run; would save Feeder ID + restart airplanes-feed and airplanes-mlat)"
        return 0
    fi

    write_uuid "$uuid"
    echo "Feeder ID saved."

    # Soft warning — local CLI is not responsible for cleaning up the
    # previous UUID's record on the website. That row stays visible as
    # an unclaimed feeder until it ages out or support removes it.
    if [[ -n "$existing" ]]; then
        echo "Note: the previous Feeder ID's record on airplanes.live is not removed by this command — it stays visible as an unclaimed feeder until it ages out or support removes it." >&2
    fi

    if ! restart_feeder_services; then
        echo "Saved, but service restart failed — the running daemons may still advertise the old Feeder ID until you restart them manually." >&2
        return 1
    fi
    echo "Done. The feeder will advertise the new Feeder ID upstream now."
}


usage_id() {
    cat <<'USAGE'
Usage: apl-feed id <subcommand> [options]

Subcommands:
  set    Save a Feeder ID (UUID) supplied by the website (reads stdin)

Run 'apl-feed id <subcommand> --help' for details.
USAGE
}

usage_id_set() {
    cat <<'USAGE'
Usage: apl-feed id set [--force]

Reads a Feeder ID (UUID) from stdin (or prompts on a TTY) and saves it
locally. Both airplanes-feed and airplanes-mlat consume the UUID, so this
command restarts both services after writing. --force overwrites a
different Feeder ID already saved on this feeder.
USAGE
}

dispatch_id() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || usage_error usage_id
    if [[ "$sub" == "-h" || "$sub" == "--help" ]]; then
        usage_id
        return 0
    fi
    shift || true
    case "$sub" in
        set) id_set "$@" ;;
        *) usage_error usage_id "unknown id subcommand: $sub" ;;
    esac
}
