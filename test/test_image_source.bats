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

    # Stub `curl`: write a known byte stream to whatever --output target is given.
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
if [[ -z "$output" || -z "$url" ]]; then
    echo "curl stub: missing output ($output) or url ($url)" >&2
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
