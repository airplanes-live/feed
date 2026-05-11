#!/usr/bin/env bats

setup() {
    LIB="$BATS_TEST_DIRNAME/lib/image-source.sh"
    ROOT_DIR="$(mktemp -d)"
    STUB_DIR="$ROOT_DIR/bin"
    FIXTURE_DIR="$ROOT_DIR/fixtures"
    OUTPUT_DIR="$ROOT_DIR/output"
    mkdir -p "$STUB_DIR" "$FIXTURE_DIR" "$OUTPUT_DIR"
    export PATH="$STUB_DIR:$PATH"
    export FIXTURE_DIR

    # Stub `gh`: maps API paths to fixture files.
    #   gh api /repos/.../releases/latest    -> $FIXTURE_DIR/releases-latest.json
    #   gh api /repos/.../releases?per_page=30 -> $FIXTURE_DIR/releases.json
    # Missing fixture → exit 1 (simulates 404).
    cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
    api)
        path="$2"
        case "$path" in
            */releases/latest)
                fixture="$FIXTURE_DIR/releases-latest.json"
                ;;
            */releases\?per_page=30|*/releases)
                fixture="$FIXTURE_DIR/releases.json"
                ;;
            *)
                echo "gh stub: unexpected api path: $path" >&2
                exit 1
                ;;
        esac
        if [[ ! -f "$fixture" ]]; then
            exit 1
        fi
        cat "$fixture"
        exit 0
        ;;
    *)
        echo "gh stub: unexpected subcommand: $1" >&2
        exit 1
        ;;
esac
SH
    chmod +x "$STUB_DIR/gh"

    # Stub `curl`: two modes.
    #   1. If $FIXTURE_DIR/curl-stub-by-name/<basename-of-url> exists, emit
    #      its contents — used by manifest-fetch tests, where the picker
    #      curls the manifest URL and reads JSON from stdout (no --output).
    #   2. Otherwise, write `STUB-IMAGE-BYTES-FOR:<url>` to --output (default
    #      behavior for image-archive downloads).
    cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
output=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --fail|--location|--silent|--show-error) shift ;;
        --*) shift ;;
        *) url="$1"; shift ;;
    esac
done
if [[ -z "$url" ]]; then
    echo "curl stub: missing url" >&2
    exit 1
fi
basename="${url##*/}"
fixture_path="$FIXTURE_DIR/curl-stub-by-name/$basename"
if [[ -f "$fixture_path" ]]; then
    if [[ -n "$output" ]]; then
        mkdir -p "$(dirname "$output")"
        cp -- "$fixture_path" "$output"
    else
        cat -- "$fixture_path"
    fi
    exit 0
fi
# Sentinel for "fetch this URL should fail" — tests pre-create an empty file
# and rely on the absent fixture to take this branch.
if [[ "$basename" == *FAIL* ]]; then
    echo "curl stub: simulated fetch failure for $url" >&2
    exit 22
fi
if [[ -z "$output" ]]; then
    echo "curl stub: stdout-mode fetch with no fixture and no FAIL marker: $url" >&2
    exit 1
fi
mkdir -p "$(dirname "$output")"
printf 'STUB-IMAGE-BYTES-FOR:%s\n' "$url" > "$output"
exit 0
SH
    chmod +x "$STUB_DIR/curl"

    # shellcheck source=lib/image-source.sh
    source "$LIB"
}

teardown() {
    rm -rf "$ROOT_DIR"
}

# Helpers to write JSON fixtures.
fixture_releases_latest_empty() {
    rm -f "$FIXTURE_DIR/releases-latest.json"
}

fixture_releases_empty() {
    printf '%s\n' '[]' > "$FIXTURE_DIR/releases.json"
}

# Writes a `releases/latest` fixture with one asset.
fixture_releases_latest_one_asset() {
    local tag="$1" asset_name="$2" body="${3:-}"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "$tag",
  "body": "$body",
  "assets": [
    {"name": "$asset_name", "browser_download_url": "https://example.invalid/$asset_name"}
  ]
}
EOF
}

# Writes a `releases?per_page=30` fixture from a jq-built array argument.
# Args: <jq array expression that constructs releases>
fixture_releases_json() {
    local jq_expr="$1"
    jq -n "$jq_expr" > "$FIXTURE_DIR/releases.json"
}

# Drops a manifest JSON file at the path the curl stub will lookup by basename.
# Args: manifest_basename body_json (a JSON string written verbatim)
fixture_curl_body() {
    local name="$1" body="$2"
    mkdir -p "$FIXTURE_DIR/curl-stub-by-name"
    printf '%s' "$body" > "$FIXTURE_DIR/curl-stub-by-name/$name"
}

# Writes a minimal valid rpi-imager Custom Repository manifest body.
# Args: image_url manifest_basename
fixture_manifest_body() {
    local image_url="$1" manifest_basename="$2"
    fixture_curl_body "$manifest_basename" "$(jq -n --arg url "$image_url" '{
        os_list: [{
            name: "test feeder image",
            description: "test",
            url: $url,
            extract_size: 1024,
            extract_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            image_download_size: 512,
            release_date: "2026-01-01",
            init_format: "cloudinit-rpi",
            devices: ["pi3-64bit"],
            capabilities: []
        }]
    }')"
}

# ---------- tests ----------

@test "tier exhaustion when nothing matches anywhere" {
    fixture_releases_latest_empty
    fixture_releases_empty
    run image_source_resolve airplanes-live/image new dev arm64 release-stable,release-any "$OUTPUT_DIR"
    [ "$status" -eq 64 ]
}

@test "release-stable resolves and downloads when latest stable has matching asset" {
    fixture_releases_latest_one_asset stable/v0.1.0 "airplanes-feeder-dev-arm64.img.xz" ""
    # Separate stdout from stderr so we can verify the stdout contract directly.
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR" >"$stdout_file" 2>/dev/null
    status=$?
    [ "$status" -eq 0 ]
    path="$(cat "$stdout_file")"
    [[ "$path" == /*.img.xz ]]
    [ -s "$path" ]
    grep -q "airplanes-feeder-dev-arm64.img.xz" "$path"
}

@test "release-stable returns tier-empty when latest has no matching asset" {
    fixture_releases_latest_one_asset stable/v0.1.0 "completely-unrelated.txt" ""
    # release-stable alone exhausts → 64
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 64 ]
}

@test "release-any iterates from newest, falls back to older when newest has no matching asset" {
    fixture_releases_json '[
        {"tag_name": "newer", "published_at": "2026-04-01T00:00:00Z", "body": "", "assets": [{"name": "irrelevant.txt", "browser_download_url": "https://example.invalid/x"}]},
        {"tag_name": "older", "published_at": "2026-01-01T00:00:00Z", "body": "", "assets": [{"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/older.img.xz"}]}
    ]'
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-any "$OUTPUT_DIR" >"$stdout_file" 2>/dev/null
    [ "$?" -eq 0 ]
    path="$(cat "$stdout_file")"
    # Curl stub writes the URL into the downloaded file; assert the older
    # release's URL was used.
    grep -q "older.img.xz" "$path"
}

@test "release-any picks newest matching when newest also matches" {
    fixture_releases_json '[
        {"tag_name": "newer", "published_at": "2026-04-01T00:00:00Z", "body": "", "assets": [{"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/newer.img.xz"}]},
        {"tag_name": "older", "published_at": "2026-01-01T00:00:00Z", "body": "", "assets": [{"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/older.img.xz"}]}
    ]'
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-any "$OUTPUT_DIR" >"$stdout_file" 2>/dev/null
    [ "$?" -eq 0 ]
    path="$(cat "$stdout_file")"
    grep -q "newer.img.xz" "$path"
}

@test "qemu tiebreaker prefers asset with qemu in name (legacy/permissive)" {
    fixture_releases_json '[
        {"tag_name": "bookworm", "published_at": "2025-02-26T18:02:20Z", "body": "", "assets": [
            {"name": "image_2025-02-24-airplanes-live-full.zip", "browser_download_url": "https://example.invalid/plain.zip"},
            {"name": "image_2025-02-24-qemu.zip", "browser_download_url": "https://example.invalid/qemu.zip"}
        ]}
    ]'
    run image_source_resolve airplanes-live/image-releases legacy stable arm64 release-any "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *qemu.zip ]]
}

@test "strict mode (new) fails hard on multiple matching assets in one release" {
    # New contract uses an exact-match regex. If two assets ever match
    # (publish-step bug), the strict check produces rc=2 — caller should
    # see non-64 non-0.
    fixture_releases_latest_empty
    fixture_releases_json '[
        {"tag_name": "dev-latest", "published_at": "2026-04-01T00:00:00Z", "body": "", "assets": [
            {"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/a.img.xz"},
            {"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/b.img.xz"}
        ]}
    ]'
    run image_source_resolve airplanes-live/image new dev arm64 release-any "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [ "$status" -ne 64 ]
}

@test "release-any continues past first release if it has no matching asset" {
    fixture_releases_json '[
        {"tag_name": "newer-no-asset", "published_at": "2026-04-01T00:00:00Z", "body": "", "assets": [{"name": "release-notes.txt", "browser_download_url": "https://example.invalid/notes.txt"}]},
        {"tag_name": "older-good", "published_at": "2026-01-01T00:00:00Z", "body": "", "assets": [{"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/older.img.xz"}]}
    ]'
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-any "$OUTPUT_DIR" >"$stdout_file" 2>/dev/null
    [ "$?" -eq 0 ]
    grep -q "older.img.xz" "$(cat "$stdout_file")"
}

@test "tier chain: release-stable exhausts, release-any provides the asset" {
    fixture_releases_latest_empty
    fixture_releases_json '[
        {"tag_name": "dev-latest", "published_at": "2026-05-01T00:00:00Z", "body": "", "assets": [
            {"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/dev.img.xz"}
        ]}
    ]'
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-stable,release-any "$OUTPUT_DIR" >"$stdout_file" 2>/dev/null
    [ "$?" -eq 0 ]
    grep -q "dev.img.xz" "$(cat "$stdout_file")"
}

@test "selected-tier and selected-release emitted on stderr" {
    fixture_releases_latest_one_asset stable/v0.1.0 "airplanes-feeder-dev-arm64.img.xz" ""
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    # Combined output (bats `run` merges stdout+stderr into $output by default
    # but we asserted stdout-only contract elsewhere; for this test we check
    # the merged output for the diagnostic lines.)
    echo "$output" | grep -q '^selected-tier=release-stable$'
    echo "$output" | grep -q '^selected-release=stable/v0.1.0 selected-asset=https://example.invalid/airplanes-feeder-dev-arm64.img.xz$'
}

@test "selected-sha extracted from release body when Built from ... @ ... pattern is present" {
    fixture_releases_latest_one_asset dev-latest "airplanes-feeder-dev-arm64.img.xz" "Built from airplanes-live/image @ abc123def456."
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'selected-sha=abc123def456'
}

@test "stdout is exactly one absolute path, terminated by newline" {
    fixture_releases_latest_one_asset stable/v0.1.0 "airplanes-feeder-dev-arm64.img.xz" ""
    # Run with stdout separated from stderr so we can validate stdout alone.
    stdout_file="$ROOT_DIR/stdout.txt"
    stderr_file="$ROOT_DIR/stderr.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR" >"$stdout_file" 2>"$stderr_file"
    [ "$(wc -l < "$stdout_file" | tr -d ' ')" -eq 1 ]
    path="$(cat "$stdout_file")"
    [[ "$path" =~ ^/.+\.(img|img\.xz|img\.gz|zip|7z)$ ]]
    [ -s "$path" ]
}

@test "gh exit-1 (missing fixture / 401-like) is treated as tier-not-found, library continues" {
    # No releases/latest fixture → gh stub exits 1 → release-stable returns
    # tier-empty. release-any has a valid fixture → resolve succeeds.
    fixture_releases_latest_empty
    fixture_releases_json '[
        {"tag_name": "dev-latest", "published_at": "2026-04-01T00:00:00Z", "body": "", "assets": [
            {"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/dev.img.xz"}
        ]}
    ]'
    run image_source_resolve airplanes-live/image new dev arm64 release-stable,release-any "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
}

@test "unknown tier in list returns internal-error rc=1" {
    run image_source_resolve airplanes-live/image new dev arm64 bogus-tier "$OUTPUT_DIR"
    [ "$status" -eq 1 ]
}

@test "missing required tool returns internal-error rc=1" {
    fixture_releases_latest_one_asset stable/v0.1.0 "airplanes-feeder-dev-arm64.img.xz" ""
    # Narrow PATH in a subshell so the global PATH (used by teardown's rm)
    # stays intact. Inside the subshell, jq is no longer reachable, so the
    # library's preflight tools check fails with rc=1.
    rc=0
    ( PATH="$STUB_DIR"; image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ]
}

# ---------- manifest-following path (new contract, no explicit regex) ----------

# Writes a /releases/latest fixture for a `new`-contract release carrying both
# the immutable .img.xz and the manifest sidecar. Returns the manifest's
# image_url so tests can match it against the downloaded content.
fixture_release_with_manifest() {
    local tag="$1" channel="$2" arch="$3"
    local immutable_name="airplanes-feeder-${channel}-${arch}-deadbeef0001-r99-a1.img.xz"
    local immutable_url="https://example.invalid/${immutable_name}"
    local manifest_name="airplanes-feeder-${channel}-${arch}.rpi-imager-manifest.json"
    local manifest_url="https://example.invalid/${manifest_name}"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "$tag",
  "body": "",
  "assets": [
    {"name": "$immutable_name", "browser_download_url": "$immutable_url"},
    {"name": "$manifest_name", "browser_download_url": "$manifest_url"}
  ]
}
EOF
    fixture_manifest_body "$immutable_url" "$manifest_name"
    printf '%s\n' "$immutable_url"
}

@test "new contract: manifest path resolves to immutable url" {
    image_url="$(fixture_release_with_manifest dev-latest dev arm64)"
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR" >"$stdout_file" 2>/dev/null
    [ "$?" -eq 0 ]
    path="$(cat "$stdout_file")"
    [[ "$path" == /*-deadbeef0001-r99-a1.img.xz ]]
    # Stub curl wrote `STUB-IMAGE-BYTES-FOR:<url>` into the download target.
    # Assert the URL came from the manifest's url field, not from regex
    # matching a different asset.
    grep -qF "$image_url" "$path"
}

@test "new contract: manifest absent falls back to legacy regex picker" {
    # Release has the rolling .img.xz but NO manifest sidecar. Manifest
    # picker returns rc 1, strategy falls through to regex, which matches
    # the rolling asset.
    fixture_releases_latest_one_asset dev-latest "airplanes-feeder-dev-arm64.img.xz" ""
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR" >"$stdout_file" 2>/dev/null
    [ "$?" -eq 0 ]
    grep -q "airplanes-feeder-dev-arm64.img.xz" "$(cat "$stdout_file")"
}

@test "new contract: malformed manifest (no url) is a hard error, no regex fallback" {
    # Manifest present but `os_list[0].url` empty. Even though a regex-
    # matchable asset exists, the malformed manifest must surface, not get
    # papered over by the regex fallback.
    local immutable_name="airplanes-feeder-dev-arm64-deadbeef0002-r1-a1.img.xz"
    local manifest_name="airplanes-feeder-dev-arm64.rpi-imager-manifest.json"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "dev-latest",
  "body": "",
  "assets": [
    {"name": "$immutable_name", "browser_download_url": "https://example.invalid/$immutable_name"},
    {"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/rolling.img.xz"},
    {"name": "$manifest_name", "browser_download_url": "https://example.invalid/$manifest_name"}
  ]
}
EOF
    # url is empty string
    fixture_curl_body "$manifest_name" '{"os_list":[{"name":"x","description":"x","url":"","extract_size":1,"extract_sha256":"00","image_download_size":1,"release_date":"2026-01-01","init_format":"cloudinit-rpi","devices":[],"capabilities":[]}]}'
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 2 ]
}

@test "new contract: manifest url pointing outside the release is rejected" {
    local immutable_name="airplanes-feeder-dev-arm64-deadbeef0003-r1-a1.img.xz"
    local manifest_name="airplanes-feeder-dev-arm64.rpi-imager-manifest.json"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "dev-latest",
  "body": "",
  "assets": [
    {"name": "$immutable_name", "browser_download_url": "https://example.invalid/$immutable_name"},
    {"name": "$manifest_name", "browser_download_url": "https://example.invalid/$manifest_name"}
  ]
}
EOF
    # Manifest points at a URL that is NOT among the release's assets.
    fixture_manifest_body "https://example.invalid/some-other-release/airplanes-feeder-dev-arm64-FAKE.img.xz" "$manifest_name"
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 2 ]
}

@test "new contract: manifest url pointing at asset with wrong-pattern name is rejected" {
    local manifest_name="airplanes-feeder-dev-arm64.rpi-imager-manifest.json"
    local notes_url="https://example.invalid/release-notes.txt"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "dev-latest",
  "body": "",
  "assets": [
    {"name": "release-notes.txt", "browser_download_url": "$notes_url"},
    {"name": "$manifest_name", "browser_download_url": "https://example.invalid/$manifest_name"}
  ]
}
EOF
    # Manifest's url is in the release but points at the wrong asset
    # (release-notes.txt rather than an .img.xz).
    fixture_manifest_body "$notes_url" "$manifest_name"
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 2 ]
}

@test "new contract: manifest fetch failure is a hard error after retries" {
    # Manifest sidecar listed in the release but the curl stub is asked to
    # fail (FAIL marker in the basename). Library retries; each retry hits
    # the same failure and the resolver exits rc 2.
    local immutable_name="airplanes-feeder-dev-arm64-deadbeef0005-r1-a1.img.xz"
    local manifest_name="airplanes-feeder-dev-arm64.rpi-imager-manifest.json"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "dev-latest",
  "body": "",
  "assets": [
    {"name": "$immutable_name", "browser_download_url": "https://example.invalid/$immutable_name"},
    {"name": "$manifest_name", "browser_download_url": "https://example.invalid/FAIL-$manifest_name"}
  ]
}
EOF
    # Shorten the backoff to keep the test fast.
    export _IMAGE_SOURCE_MANIFEST_FETCH_ATTEMPTS=2
    export _IMAGE_SOURCE_MANIFEST_FETCH_BACKOFF_S=0
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 2 ]
}

@test "new contract: explicit regex override bypasses the manifest path" {
    # Release has a rolling-name asset and a manifest sidecar whose URL is
    # set to fail when curl tries to fetch it (FAIL marker). If the resolver
    # were attempting the manifest path it would error out — passing instead
    # proves the explicit regex actually bypassed manifest resolution.
    local manifest_name="airplanes-feeder-dev-arm64.rpi-imager-manifest.json"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "dev-latest",
  "body": "",
  "assets": [
    {"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/rolling.img.xz"},
    {"name": "$manifest_name", "browser_download_url": "https://example.invalid/FAIL-$manifest_name"}
  ]
}
EOF
    # Keep retries fast in case the bypass is broken and we accidentally
    # exercise the retry loop.
    export _IMAGE_SOURCE_MANIFEST_FETCH_ATTEMPTS=1
    export _IMAGE_SOURCE_MANIFEST_FETCH_BACKOFF_S=0
    stdout_file="$ROOT_DIR/stdout.txt"
    image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR" \
        '^airplanes-feeder-dev-arm64\.img\.xz$' >"$stdout_file" 2>/dev/null
    [ "$?" -eq 0 ]
    grep -q "rolling.img.xz" "$(cat "$stdout_file")"
}

@test "new contract: immutable .img.xz without manifest is a hard error, no regex fallback" {
    # Race / broken-publish scenario: a release contains the immutable
    # SHA-tagged asset but the manifest upload step never completed (or
    # raced). The strategy must NOT silently fall through to the regex
    # picker — if it did, release-any would happily advance to an older
    # release and we'd test the wrong image. Hard rc=2 instead.
    local immutable_name="airplanes-feeder-dev-arm64-deadbeef0006-r1-a1.img.xz"
    cat > "$FIXTURE_DIR/releases-latest.json" <<EOF
{
  "tag_name": "dev-latest",
  "body": "",
  "assets": [
    {"name": "$immutable_name", "browser_download_url": "https://example.invalid/$immutable_name"},
    {"name": "airplanes-feeder-dev-arm64.img.xz", "browser_download_url": "https://example.invalid/rolling.img.xz"}
  ]
}
EOF
    run image_source_resolve airplanes-live/image new dev arm64 release-stable "$OUTPUT_DIR"
    [ "$status" -eq 2 ]
}

@test "new contract: release-any does not silently advance past broken-publish release" {
    # Newer release has an immutable asset but no manifest (broken publish);
    # older release has a manifest + immutable. release-any must NOT skip
    # the broken release and pick the older one — that would silently test
    # a stale image.
    local newer_immutable="airplanes-feeder-dev-arm64-cafebabe0001-r1-a1.img.xz"
    local older_immutable="airplanes-feeder-dev-arm64-deadbeef0007-r1-a1.img.xz"
    local older_manifest="airplanes-feeder-dev-arm64.rpi-imager-manifest.json"
    fixture_releases_json '[
        {
            "tag_name": "dev-latest-broken",
            "published_at": "2026-05-01T00:00:00Z",
            "body": "",
            "assets": [
                {"name": "'"$newer_immutable"'", "browser_download_url": "https://example.invalid/'"$newer_immutable"'"}
            ]
        },
        {
            "tag_name": "dev-older",
            "published_at": "2026-04-01T00:00:00Z",
            "body": "",
            "assets": [
                {"name": "'"$older_immutable"'", "browser_download_url": "https://example.invalid/'"$older_immutable"'"},
                {"name": "'"$older_manifest"'", "browser_download_url": "https://example.invalid/'"$older_manifest"'"}
            ]
        }
    ]'
    # The older release's manifest is well-formed; doesn't matter because
    # we expect to hard-fail on the newer broken release before ever
    # reaching the older one.
    fixture_manifest_body "https://example.invalid/$older_immutable" "$older_manifest"
    run image_source_resolve airplanes-live/image new dev arm64 release-any "$OUTPUT_DIR"
    [ "$status" -eq 2 ]
}

@test "legacy contract: never reads the manifest, regex picker only" {
    # Legacy contract releases have a single asset under historical naming
    # and no manifest sidecar. Should resolve via regex, no manifest fetch.
    fixture_releases_json '[
        {"tag_name": "bookworm", "published_at": "2025-02-26T18:02:20Z", "body": "", "assets": [
            {"name": "image_2025-02-24-airplanes-live-full.zip", "browser_download_url": "https://example.invalid/plain.zip"}
        ]}
    ]'
    run image_source_resolve airplanes-live/image-releases legacy stable arm64 release-any "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    # `$output` (bats) merges stdout+stderr; downloaded path is on stdout,
    # selected-* observability lines are on stderr. Match the stdout-path
    # token specifically, anchored to the start of a line so an "asset"
    # mention elsewhere can't satisfy this.
    echo "$output" | grep -qE '^/.+/image_2025-02-24-airplanes-live-full\.zip$'
}
