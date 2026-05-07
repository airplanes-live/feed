#!/usr/bin/env bats

# Drift guards for the historical-ship manifests in update.sh. The arrays
# `historical_top_level_scripts` and `historical_apl_feed_modules` drive the
# prune-on-update behavior that sweeps stale copies of removed scripts off
# upgraded feeders. CI must catch both directions of drift:
#   - a new script in scripts/ that wasn't registered in the manifest (would
#     leak forever once we delete it later), and
#   - a historical entry that gets accidentally removed from the manifest
#     (would re-leak the stale file on every still-upgrading feeder).

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    UPDATE="$REPO_ROOT/update.sh"
}

# Extracts the contents of a `name=( ... )` array from update.sh as one entry
# per line on stdout. Tolerates leading whitespace and trailing comments on
# array entries. Stops at the first closing `)` after the array opens.
extract_manifest() {
    local name="$1"
    awk -v name="$name" '
        $0 ~ "^"name"=\\(" { in_arr = 1; next }
        in_arr && /^\)/ { in_arr = 0; exit }
        in_arr {
            sub(/#.*$/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 != "") print
        }
    ' "$UPDATE"
}

@test "historical_top_level_scripts manifest covers every currently shipped top-level script" {
    local manifest
    manifest="$(extract_manifest historical_top_level_scripts)"
    [ -n "$manifest" ]
    for path in "$REPO_ROOT"/scripts/*.sh; do
        local name
        name="$(basename "$path")"
        if ! grep -Fxq "$name" <<<"$manifest"; then
            echo "scripts/$name is shipped but missing from historical_top_level_scripts in update.sh" >&2
            return 1
        fi
    done
}

@test "historical_apl_feed_modules manifest covers every currently shipped apl-feed module" {
    local manifest
    manifest="$(extract_manifest historical_apl_feed_modules)"
    [ -n "$manifest" ]
    for path in "$REPO_ROOT"/scripts/apl-feed/*.sh; do
        local name
        name="$(basename "$path")"
        if ! grep -Fxq "$name" <<<"$manifest"; then
            echo "scripts/apl-feed/$name is shipped but missing from historical_apl_feed_modules in update.sh" >&2
            return 1
        fi
    done
}

@test "historical_top_level_scripts retains second-mlat.sh (deleted in PR #30, must keep pruning forever)" {
    local manifest
    manifest="$(extract_manifest historical_top_level_scripts)"
    grep -Fxq "second-mlat.sh" <<<"$manifest"
}
