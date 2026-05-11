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
#
# Asset selection for the `new` contract is manifest-driven: when REGEX is
# unset, the resolver looks for the rpi-imager Custom Repository sidecar
# (`airplanes-feeder-${channel}-${arch}.rpi-imager-manifest.json`) in the
# resolved release, parses `os_list[0].url`, and downloads that — the same
# pointer rpi-imager itself follows. If the manifest is absent the resolver
# falls back to the legacy regex picker so releases that predate manifest
# publishing still resolve. A manifest that is PRESENT but malformed (unreadable,
# missing url, url points outside the release, basename does not match the
# expected pattern) is a hard error rather than a silent fallback.
# Pass an explicit REGEX to bypass the manifest path for one-off testing of
# a specific asset (e.g. image-boot-smoke's `image_asset_regex` input).

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

# Manifest-fetch retry tuning. GitHub release assets can be briefly
# inconsistent during `gh release upload --clobber` (DELETE-then-POST window),
# so we retry the small manifest sidecar before declaring a hard error. The
# .img.xz it references is uploaded under an immutable name and never
# clobbered, so a manifest-fetch retry is the only race we need to absorb.
_IMAGE_SOURCE_MANIFEST_FETCH_ATTEMPTS="${_IMAGE_SOURCE_MANIFEST_FETCH_ATTEMPTS:-3}"
_IMAGE_SOURCE_MANIFEST_FETCH_BACKOFF_S="${_IMAGE_SOURCE_MANIFEST_FETCH_BACKOFF_S:-2}"

_image_source_pick_asset_via_manifest() {
    # Reads a single release JSON object on stdin. Looks for a sidecar
    # `airplanes-feeder-${channel}-${arch}.rpi-imager-manifest.json` asset,
    # fetches it over HTTPS, parses the rpi-imager Custom Repository JSON,
    # extracts os_list[0].url, and validates the URL points at an asset of
    # the SAME release whose name matches the expected immutable pattern.
    # Emits <asset_name>\t<asset_url> on success.
    #
    # Args: channel arch
    # Return: 0 success
    #         1 no manifest sidecar present in this release (caller decides
    #             whether to fall back or escalate)
    #         2 manifest present but malformed, fetch failed after retries,
    #             url field missing/empty, url not an asset of this release,
    #             or url's asset name does not match the expected pattern
    local channel="$1" arch="$2"
    local manifest_name="airplanes-feeder-${channel}-${arch}.rpi-imager-manifest.json"
    local release_json manifest_url manifest_body image_url
    local matched_name expected_re attempt

    release_json="$(cat)"
    manifest_url="$(printf '%s\n' "$release_json" \
        | jq -r --arg name "$manifest_name" \
            '[.assets[]? | select(.name == $name)] | first | .browser_download_url // empty')"
    if [[ -z "$manifest_url" ]]; then
        # No manifest sidecar. Distinguish two cases:
        #   - Release has at least one asset matching the immutable
        #     SHA-tagged pattern → the publisher emits manifests, so a
        #     missing one is a broken publish (e.g., the sequential upload
        #     chain crashed between the .img.xz step and the manifest
        #     step). Hard error so callers don't silently regress to an
        #     older release via the regex fallback.
        #   - No immutable-pattern asset either → this is a pre-manifest
        #     release (rolling-only) or an unrelated release. Treat as
        #     "no manifest path here" and let the strategy fall back to
        #     the legacy regex picker.
        local immutable_re has_immutable
        immutable_re="^airplanes-feeder-${channel}-${arch}-[0-9a-f]+-r[0-9]+-a[0-9]+\\.img\\.xz$"
        has_immutable="$(printf '%s\n' "$release_json" \
            | jq -r --arg re "$immutable_re" \
                '[.assets[]? | select(.name | test($re))] | length')"
        if [[ "$has_immutable" -gt 0 ]]; then
            echo "image-source: release has immutable .img.xz asset(s) but no manifest sidecar — refusing to fall back to a stale release" >&2
            return 2
        fi
        return 1
    fi

    manifest_body=""
    for (( attempt = 1; attempt <= _IMAGE_SOURCE_MANIFEST_FETCH_ATTEMPTS; attempt++ )); do
        # --fail makes curl exit non-zero on HTTP >=400; --location follows
        # GitHub's redirect to the signed asset URL. stderr suppression here
        # keeps each attempt quiet — the final-failure message below is the
        # one that matters.
        if manifest_body="$(curl --fail --location --silent --show-error "$manifest_url" 2>/dev/null)"; then
            [[ -n "$manifest_body" ]] && break
            manifest_body=""
        fi
        if (( attempt < _IMAGE_SOURCE_MANIFEST_FETCH_ATTEMPTS )); then
            sleep "$_IMAGE_SOURCE_MANIFEST_FETCH_BACKOFF_S"
        fi
    done
    if [[ -z "$manifest_body" ]]; then
        echo "image-source: failed to fetch manifest after $_IMAGE_SOURCE_MANIFEST_FETCH_ATTEMPTS attempts: $manifest_url" >&2
        return 2
    fi

    # jq filter: require .os_list[0].url to be a non-empty string. `strings`
    # keeps only string values (drops null/numbers/arrays); `select(length > 0)`
    # drops empty strings. Output is empty iff any check fails.
    image_url="$(printf '%s\n' "$manifest_body" \
        | jq -r '.os_list[0].url // empty | strings | select(length > 0)')"
    if [[ -z "$image_url" ]]; then
        echo "image-source: manifest missing or invalid os_list[0].url: $manifest_url" >&2
        return 2
    fi

    # Structural validation: the manifest's url must equal one of the same
    # release's asset URLs. Prefix-only validation is too weak — it would
    # accept a malformed manifest pointing at a different release, wrong
    # channel/arch, or off-asset content.
    matched_name="$(printf '%s\n' "$release_json" \
        | jq -r --arg url "$image_url" \
            '[.assets[]? | select(.browser_download_url == $url)] | first | .name // empty')"
    if [[ -z "$matched_name" ]]; then
        echo "image-source: manifest url is not an asset of the resolved release: $image_url" >&2
        return 2
    fi

    # And its basename must match the expected immutable pattern for the
    # requested channel + arch. Catches a misrouted manifest that points at
    # e.g. the release-notes asset.
    expected_re="^airplanes-feeder-${channel}-${arch}(-.+)?\\.img\\.xz$"
    if ! [[ "$matched_name" =~ $expected_re ]]; then
        echo "image-source: manifest url asset name $matched_name does not match expected pattern $expected_re" >&2
        return 2
    fi

    printf '%s\t%s\n' "$matched_name" "$image_url"
}

_image_source_pick_via_strategy() {
    # Picks an asset from the given release JSON. For the `new` contract with
    # no explicit REGEX, tries the rpi-imager manifest sidecar first; if the
    # manifest is absent (rc 1 from the manifest picker), falls back to the
    # legacy regex picker so older or hand-crafted releases still resolve. A
    # manifest that is PRESENT but malformed (rc 2) is a hard error and is
    # NOT papered over by the regex fallback — the broken publisher must
    # surface, not silently get downgraded to "older asset pointed at by
    # regex". Reads release JSON on stdin.
    #
    # Args: contract channel arch regex strict explicit_regex
    #   explicit_regex: "1" if caller passed REGEX to image_source_resolve;
    #                   "" if the regex argument was the library default.
    # Output / return: identical to _image_source_pick_asset.
    local contract="$1" channel="$2" arch="$3"
    local regex="$4" strict="$5" explicit_regex="$6"
    local release_json
    release_json="$(cat)"
    if [[ "$contract" == "new" && -z "$explicit_regex" ]]; then
        local pick rc
        if pick="$(printf '%s\n' "$release_json" | _image_source_pick_asset_via_manifest "$channel" "$arch")"; then
            printf '%s\n' "$pick"
            return 0
        else
            rc=$?
        fi
        if [[ $rc -ne 1 ]]; then
            # rc 2: manifest present but malformed. Hard error — don't fall
            # back to regex, since that would let a broken manifest get
            # papered over with a stale rolling-name asset.
            return "$rc"
        fi
        # rc 1: no manifest sidecar in this release. Fall through to regex.
    fi
    printf '%s\n' "$release_json" | _image_source_pick_asset "$regex" "$strict"
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
    # Args: repo contract channel arch regex strict explicit_regex output_dir
    #
    # IMPORTANT: capture exit codes via `if cmd; then rc=0; else rc=$?; fi`,
    # not `cmd; rc=$?`. Two bash gotchas conspire here:
    # (1) Under `set -e` (active in bats test functions), `cmd; rc=$?`
    #     aborts at the failing cmd before rc=$? runs.
    # (2) `if ! cmd; then rc=$?` inverts the exit code via `!`; inside
    #     the then-block $? becomes the if-test result, not cmd's status.
    # The if/else pattern below puts the call in a tested context (set -e
    # suppressed) AND captures the unmodified exit code in the else branch.
    local repo="$1" contract="$2" channel="$3" arch="$4"
    local regex="$5" strict="$6" explicit_regex="$7" output_dir="$8"
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
    if pick="$(printf '%s\n' "$json" | _image_source_pick_via_strategy "$contract" "$channel" "$arch" "$regex" "$strict" "$explicit_regex")"; then
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
    # Args: repo contract channel arch regex strict explicit_regex output_dir
    # See note in _resolve_release_stable about exit-code capture pattern.
    local repo="$1" contract="$2" channel="$3" arch="$4"
    local regex="$5" strict="$6" explicit_regex="$7" output_dir="$8"
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
        if pick="$(printf '%s\n' "$release_json" | _image_source_pick_via_strategy "$contract" "$channel" "$arch" "$regex" "$strict" "$explicit_regex")"; then
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
            # Hard failure: strict-regex violation, malformed/missing
            # manifest, or other structural problem on this release. Don't
            # silently advance to an older release — escalate.
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

    # Track whether the caller passed an explicit regex. Explicit regex
    # bypasses the new-contract manifest path (one-off testing of a specific
    # asset, e.g. image-boot-smoke's image_asset_regex dispatch input).
    local explicit_regex=""
    if [[ -n "$regex" ]]; then
        explicit_regex=1
    else
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
                if _resolve_release_stable "$repo" "$contract" "$channel" "$arch" "$regex" "$strict" "$explicit_regex" "$output_dir"; then
                    rc=0
                else
                    rc=$?
                fi
                ;;
            release-any)
                if _resolve_release_any "$repo" "$contract" "$channel" "$arch" "$regex" "$strict" "$explicit_regex" "$output_dir"; then
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
