#!/usr/bin/env bash
# Pure-function translators for legacy MLAT keys → canonical MLAT_PRIVATE.
# Single source of truth; sourced from:
#   - scripts/apl-feed/import.sh         (apl-feed import legacy-config)
#   - scripts/lib/update-migrations.sh   (migrate_privacy_to_mlat_private)
#   - scripts/airplanes-mlat.sh          (daemon runtime read fallback)
#
# Same input → same output, every site. Pinned by test/test_legacy_mlat_translation.bats.
#
# No globals read or written, no side effects. Safe to source anywhere.

# PRIVACY → MLAT_PRIVATE.
#
# Canonical legacy form is `--privacy` (cargo-culted from old mlat-client
# docs). Empty / no / false / 0 map to "false" explicitly. Anything else
# is unrecognised — return non-zero so the caller can decide whether to
# leave MLAT_PRIVATE at its existing on-disk value (preferred) or default
# to a safe value (only when no existing value is available).
#
# Whitespace around the value is trimmed first; hand-edits like
# `PRIVACY=" --privacy "` are tolerated.
#
# Stdout: "true" or "false" on recognised input. No output on unrecognised.
# Returns: 0 recognised, 1 unrecognised.
derive_mlat_private_from_privacy() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
        --privacy)        printf 'true' ;;
        ''|no|false|0)    printf 'false' ;;
        *) return 1 ;;
    esac
}

# MLAT_MARKER → MLAT_PRIVATE.
#
# Inverted polarity: PHP webconfig's "no" means privacy ON. Yes / true /
# 1 mean privacy OFF (marker shown). Anything else is unrecognised.
#
# Stdout: "true" or "false" on recognised input. No output on unrecognised.
# Returns: 0 recognised, 1 unrecognised.
derive_mlat_private_from_marker() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
        no)               printf 'true' ;;
        yes|true|1)       printf 'false' ;;
        *) return 1 ;;
    esac
}
