#!/usr/bin/env bats

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/scripts/lib/install-update-common.sh"
    INSTALL="$REPO_ROOT/install.sh"
    UPDATE="$REPO_ROOT/update.sh"
}

# Extract the inline fallback block from install.sh / update.sh — the content
# between the top-level `else` (column 0) and its matching `fi` (column 0).
# Internal `fi`s inside function bodies are indented and do not match.
extract_fallback() {
    local script="$1"
    awk '
        /^else$/ { in_block = 1; next }
        in_block && /^fi$/ { exit }
        in_block { print }
    ' "$script"
}

# Dump the body of a single function from a script via `declare -f` in a clean subshell.
function_body() {
    local source_text="$1"
    local fn="$2"
    bash -c '
        # Source the provided text with a guard so any imperative statements
        # at the bottom do not run (we only care about function defs).
        set +e
        eval "$1"
        declare -f "$2" 2>/dev/null
    ' _ "$source_text" "$fn"
}

@test "install.sh inline fallback shared helpers match lib byte-for-byte" {
    local stub
    stub="$(extract_fallback "$INSTALL")"
    [ -n "$stub" ]

    local lib
    lib="$(<"$LIB")"

    # install.sh's inline fallback intentionally omits airplanes_init_paths
    # (covered separately as a strict subset) and the rpm/legacy helpers.
    for fn in airplanes_path airplanes_is_build_mode airplanes_enable_build_mode_from_args airplanes_require_root airplanes_install_bootstrap_deps getGIT; do
        local install_body lib_body
        install_body="$(function_body "$stub" "$fn")"
        lib_body="$(function_body "$lib" "$fn")"
        [ -n "$install_body" ]
        [ -n "$lib_body" ]
        if [[ "$install_body" != "$lib_body" ]]; then
            echo "drift in $fn:" >&2
            diff <(echo "$install_body") <(echo "$lib_body") >&2 || true
            return 1
        fi
    done
}

@test "install.sh inline airplanes_init_paths is a strict subset of lib" {
    local stub
    stub="$(extract_fallback "$INSTALL")"

    local lib
    lib="$(<"$LIB")"

    local install_body lib_body
    install_body="$(function_body "$stub" airplanes_init_paths)"
    lib_body="$(function_body "$lib" airplanes_init_paths)"
    [ -n "$install_body" ]
    [ -n "$lib_body" ]

    # Strict subset: every non-trivial line in install.sh's body must also
    # appear verbatim in lib's body. Lib may have additional path globals.
    local line
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*airplanes_init_paths[[:space:]]*\(\) ]] && continue
        [[ "${line//[[:space:]]/}" == "{" || "${line//[[:space:]]/}" == "}" ]] && continue
        if [[ "$lib_body" != *"$line"* ]]; then
            echo "install.sh init_paths line not present in lib: $line" >&2
            return 1
        fi
    done <<< "$install_body"
}

@test "update.sh inline fallback shared helpers match lib byte-for-byte" {
    local stub
    stub="$(extract_fallback "$UPDATE")"
    [ -n "$stub" ]

    local lib
    lib="$(<"$LIB")"

    for fn in \
        airplanes_resolve_latest_stable_tag \
        airplanes_resolve_feed_branch \
        airplanes_path \
        airplanes_init_paths \
        airplanes_is_image_install \
        airplanes_image_feed_bin_default \
        airplanes_image_target_default \
        airplanes_is_build_mode \
        airplanes_enable_build_mode_from_args \
        airplanes_require_root \
        airplanes_apt_install \
        airplanes_is_legacy_os \
        airplanes_update_packages \
        airplanes_install_update_deps \
        revision \
        getGIT
    do
        local update_body lib_body
        update_body="$(function_body "$stub" "$fn")"
        lib_body="$(function_body "$lib" "$fn")"
        [ -n "$update_body" ]
        [ -n "$lib_body" ]
        if [[ "$update_body" != "$lib_body" ]]; then
            echo "drift in $fn:" >&2
            diff <(echo "$update_body") <(echo "$lib_body") >&2 || true
            return 1
        fi
    done
}
