#!/usr/bin/env bash
# image-source.sh — tier-based image asset resolution and download
#
# Sourceable library. No top-level execution.
#
# Public entrypoint:
#
#   image_source_resolve REPO CONTRACT CHANNEL ARCH TIER_LIST OUTPUT_DIR [REGEX]
#
# Output:
#   stdout — exactly one absolute path to the downloaded archive (one line)
#   stderr — status lines (selected-tier=..., skipped-tier=..., selected-release=...)
#
# Exit codes:
#   0   — success; archive path on stdout
#   64  — tier exhaustion (no tier produced an asset, no hard auth/transport failure)
#   1   — internal error: missing tools, network/JSON failure, hard error from a tier
#
# Token plumbing: library reads GH_TOKEN (gh CLI convention). Caller workflow
# exports GH_TOKEN. For the public image repos targeted today, github.token
# (cross-repo, public-readable) is sufficient.
#
# 401/403/404 returned by gh api are treated as "this tier has nothing for us;
# move on" rather than hard failure. This matches the public-repo expectation:
# an authenticated-but-broken token shouldn't block a public release lookup,
# and tier-empty signals naturally degrade via the caller's skip-with-notice.

# ---- requirements ----

_image_source_require_tools() {
    local cmd
    for cmd in gh jq curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "image-source: missing required tool: $cmd" >&2
            return 1
        fi
    done
}

# ---- defaults ----

_image_source_default_regex() {
    # Args: contract channel arch
    # Echoes: PCRE-style regex matching the expected asset(s) for the contract.
    local contract="$1" channel="$2" arch="$3"
    if [[ "$contract" == "new" ]]; then
        # New-image asset names are deterministic; the dev-latest prerelease's
        # asset is `airplanes-feeder-dev-arm64.img.xz` (or `stable` channel).
        printf '(?i)^airplanes-feeder-%s-%s\\.img\\.xz$\n' "$channel" "$arch"
    else
        # Legacy release-images repo ships a single asset per release with
        # historically inconsistent naming; accept any common image archive
        # extension.
        printf '(?i)\\.(img|img\\.xz|img\\.gz|zip|7z)$\n'
    fi
}

_image_source_strict_mode() {
    # 0 (strict) if exactly-one match required; 1 (permissive) otherwise.
    # Strict for `new` because the asset name is exact; legacy accepts any
    # archive extension and may produce multiple matches the tiebreaker
    # chooses between.
    [[ "$1" == "new" ]]
}

# ---- release JSON helpers ----

_image_source_extract_sha_from_body() {
    # Parses "Built from <repo> @ <sha>." from a release body. Used to surface
    # the source commit of `dev-latest` so reviewers can correlate which dev
    # commit's image was actually exercised by CI.
    # Args: <body string>
    local body="$1"
    printf '%s\n' "$body" \
        | sed -nE 's/.*Built from [^[:space:]]+ @ ([0-9a-f]+).*/\1/p' \
        | head -n1
}

_image_source_pick_asset() {
    # Reads a single release object as JSON on stdin. Picks the best-matching
    # asset by regex + qemu-name tiebreaker.
    #
    # Args: regex strict_mode_flag(0|1)
    # Output: <asset_name>\t<asset_url> on success
    # Return: 0 success, 1 no match, 2 strict-mode violation (multiple matches)
    local regex="$1" strict="$2"
    local result
    result="$(jq -r --arg re "$regex" --arg strict "$strict" '
        [.assets[]? | select(.name | test($re))] as $matches
        | if ($matches | length) == 0 then
              "MISS"
          elif (($matches | length) > 1) and ($strict == "1") then
              "STRICT:" + ([$matches[].name] | join(","))
          else
              (($matches | map(select(.name | test("qemu"; "i"))) | first) // ($matches | first))
              | "\(.name)\t\(.browser_download_url)"
          end
    ')" || return 2

    case "$result" in
        MISS)
            return 1
            ;;
        STRICT:*)
            echo "image-source: strict-mode violation — multiple assets matched: ${result#STRICT:}" >&2
            return 2
            ;;
        *)
            printf '%s\n' "$result"
            return 0
            ;;
    esac
}

# ---- download ----

_image_source_download() {
    # Args: url output_dir asset_name
    # Output: absolute path to downloaded file on stdout (one line)
    # Return: 0 success, 2 download failure
    local url="$1" output_dir="$2" name="$3"
    mkdir -p "$output_dir" || return 2
    local out="$output_dir/$name"
    if ! curl --fail --location --silent --show-error --output "$out" "$url"; then
        echo "image-source: download failed: $url" >&2
        return 2
    fi
    if [[ ! -s "$out" ]]; then
        echo "image-source: downloaded file is empty: $out" >&2
        return 2
    fi
    # Resolve to absolute path so stdout contract holds regardless of caller cwd.
    local abs
    abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
    printf '%s\n' "$abs"
}

_image_source_emit_selected() {
    # Emits the selected-tier / selected-release / selected-asset / selected-sha
    # observability lines to stderr. Caller invokes after a tier resolves and
    # before download (so the lines appear even if the subsequent download
    # races against `gh release upload --clobber`).
    # Args: tier_name release_json asset_url
    local tier="$1" release_json="$2" asset_url="$3"
    local tag body sha
    tag="$(printf '%s\n' "$release_json" | jq -r '.tag_name // ""')"
    body="$(printf '%s\n' "$release_json" | jq -r '.body // ""')"
    sha="$(_image_source_extract_sha_from_body "$body")"
    echo "selected-tier=$tier" >&2
    if [[ -n "$sha" ]]; then
        echo "selected-release=$tag selected-asset=$asset_url selected-sha=$sha" >&2
    else
        echo "selected-release=$tag selected-asset=$asset_url" >&2
    fi
}

# ---- tier helpers ----
#
# Each tier helper returns:
#   0 — resolved + downloaded; path written to stdout
#   1 — tier produced no asset; caller should try the next tier
#   2 — hard error inside the tier; caller should propagate

_resolve_release_stable() {
    # Args: repo regex strict_mode output_dir
    #
    # IMPORTANT: capture exit codes via `if cmd; then rc=0; else rc=$?; fi`,
    # not `cmd; rc=$?`. Two bash gotchas conspire here:
    # (1) Under `set -e` (active in bats test functions), `cmd; rc=$?`
    #     aborts at the failing cmd before rc=$? runs.
    # (2) `if ! cmd; then rc=$?` inverts the exit code via `!`; inside
    #     the then-block $? becomes the if-test result, not cmd's status.
    # The if/else pattern below puts the call in a tested context (set -e
    # suppressed) AND captures the unmodified exit code in the else branch.
    local repo="$1" regex="$2" strict="$3" output_dir="$4"
    local json pick rc name url
    if json="$(gh api "/repos/$repo/releases/latest" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        echo "skipped-tier=release-stable: no /releases/latest for $repo" >&2
        return 1
    fi
    if pick="$(printf '%s\n' "$json" | _image_source_pick_asset "$regex" "$strict")"; then
        rc=0
    else
        rc=$?
    fi
    case $rc in
        0) ;;
        1)
            echo "skipped-tier=release-stable: latest stable release has no matching asset" >&2
            return 1
            ;;
        *)
            return "$rc"
            ;;
    esac
    name="${pick%%$'\t'*}"
    url="${pick#*$'\t'}"
    _image_source_emit_selected "release-stable" "$json" "$url"
    _image_source_download "$url" "$output_dir" "$name"
}

_resolve_release_any() {
    # Args: repo regex strict_mode output_dir
    # See note in _resolve_release_stable about exit-code capture pattern.
    local repo="$1" regex="$2" strict="$3" output_dir="$4"
    local releases sorted release_json pick name url rc
    if releases="$(gh api "/repos/$repo/releases?per_page=30" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        echo "skipped-tier=release-any: failed to list releases for $repo" >&2
        return 1
    fi
    # Compact-stream sorted releases (newest first). jq's `-c` keeps each as
    # one JSON object per line, suitable for a `while read` loop.
    sorted="$(printf '%s\n' "$releases" | jq -c 'sort_by(.published_at) | reverse | .[]')"
    if [[ -z "$sorted" ]]; then
        echo "skipped-tier=release-any: no releases published in $repo" >&2
        return 1
    fi
    while IFS= read -r release_json; do
        if pick="$(printf '%s\n' "$release_json" | _image_source_pick_asset "$regex" "$strict")"; then
            rc=0
        else
            rc=$?
        fi
        if [[ $rc -eq 0 ]]; then
            name="${pick%%$'\t'*}"
            url="${pick#*$'\t'}"
            _image_source_emit_selected "release-any" "$release_json" "$url"
            _image_source_download "$url" "$output_dir" "$name"
            return $?
        elif [[ $rc -eq 2 ]]; then
            # Strict violation — hard failure on this release.
            return 2
        fi
        # rc=1: this release didn't have the asset, try next.
    done <<< "$sorted"
    echo "skipped-tier=release-any: no release in $repo had a matching asset" >&2
    return 1
}

# ---- entrypoint ----

image_source_resolve() {
    local repo="${1:?image_source_resolve: REPO required}"
    local contract="${2:?image_source_resolve: CONTRACT required}"
    local channel="${3:?image_source_resolve: CHANNEL required}"
    local arch="${4:?image_source_resolve: ARCH required}"
    local tier_list="${5:?image_source_resolve: TIER_LIST required (comma-separated)}"
    local output_dir="${6:?image_source_resolve: OUTPUT_DIR required}"
    local regex="${7:-}"

    _image_source_require_tools || return 1

    if [[ -z "$regex" ]]; then
        regex="$(_image_source_default_regex "$contract" "$channel" "$arch")"
    fi

    local strict
    if _image_source_strict_mode "$contract"; then
        strict=1
    else
        strict=0
    fi

    local -a tiers
    IFS=',' read -ra tiers <<< "$tier_list"

    local tier rc
    for tier in "${tiers[@]}"; do
        case "$tier" in
            release-stable)
                # set -e bypass via tested context, same pattern as the helpers.
                if _resolve_release_stable "$repo" "$regex" "$strict" "$output_dir"; then
                    rc=0
                else
                    rc=$?
                fi
                ;;
            release-any)
                if _resolve_release_any "$repo" "$regex" "$strict" "$output_dir"; then
                    rc=0
                else
                    rc=$?
                fi
                ;;
            *)
                echo "image-source: unknown tier '$tier' in tier list: $tier_list" >&2
                return 1
                ;;
        esac
        case "$rc" in
            0) return 0 ;;
            1) ;;  # tier empty, try next
            *) return "$rc" ;;
        esac
    done

    echo "image-source: all tiers exhausted (tier list: $tier_list)" >&2
    return 64
}
