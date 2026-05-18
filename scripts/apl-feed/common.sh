#!/usr/bin/env bash

ROOT='/'

# Precedence: CLI flag (--website-url) > APL_FEED_WEBSITE_URL env > on-disk
# feed.env > built-in default. systemd-launched timers run without env vars,
# so the feed.env grep is the only way they pick up a non-prod backend set
# via airplanes-config.txt's WEBSITE_URL key. feed.env is parsed (not
# sourced) because the file is operator-editable and apl-feed runs as root.
# shellcheck disable=SC2120  # production call site uses default; bats overrides
_resolve_website_url() {
    local feed_env="${1:-/etc/airplanes/feed.env}"
    if [[ -n "${APL_FEED_WEBSITE_URL:-}" ]]; then
        printf '%s' "$APL_FEED_WEBSITE_URL"
        return 0
    fi
    if [[ -r "$feed_env" ]]; then
        local val
        val="$(awk -F= '
            /^APL_FEED_WEBSITE_URL=/ {
                v = substr($0, length($1) + 2)
                sub(/^"/, "", v)
                sub(/"$/, "", v)
                last = v
            }
            END { if (last != "") print last }
        ' "$feed_env" 2>/dev/null)"
        if [[ -n "$val" ]]; then
            printf '%s' "$val"
            return 0
        fi
    fi
    printf 'https://airplanes.live'
}

# Derive WEBSITE_HOST (host[:port], no scheme/userinfo/path/query/fragment)
# from WEBSITE_URL. Used as a `host=` tag in structured journal lines emitted
# by airplanes-diagnostics.sh and apl-feed/config.sh so operators can tell at
# a glance which backend a request hit (production vs FEED_HOST-overridden
# staging). Re-derived from parse_common_option's --website-url branch so CLI
# overrides propagate before any log call.
_set_website_host() {
    local s="${WEBSITE_URL#*://}"
    s="${s#*@}"          # strip optional userinfo
    s="${s%%/*}"         # strip path
    s="${s%%\?*}"        # strip query
    s="${s%%#*}"         # strip fragment
    WEBSITE_HOST="$s"
}

# shellcheck disable=SC2034  # WEBSITE_URL/WEBSITE_HOST/MAX_RETRY_TIME/DRY_RUN/FORCE are read by sibling modules sourced from apl-feed.sh
WEBSITE_URL="$(_resolve_website_url)"
# shellcheck disable=SC2034
WEBSITE_HOST=""
_set_website_host
# shellcheck disable=SC2034
MAX_RETRY_TIME="${APL_FEED_MAX_RETRY_TIME:-60}"
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034
FORCE=0
TMP_FILES=()

cleanup_tmp_files() {
    if ((${#TMP_FILES[@]})); then
        rm -f "${TMP_FILES[@]}"
    fi
}
trap cleanup_tmp_files EXIT

new_tmp_file() {
    local file
    file="$(mktemp)"
    TMP_FILES+=("$file")
    printf '%s' "$file"
}

usage() {
    cat <<'USAGE'
Usage:
  apl-feed status [--json]
  apl-feed claim register
  apl-feed claim show
  apl-feed claim rotate
  apl-feed claim rotate --abort
  apl-feed claim set [--force]
  apl-feed id set [--force]
  apl-feed mlat enable
  apl-feed mlat disable
  apl-feed mlat setup
  apl-feed mlat user <name>
  apl-feed mlat user --clear
  apl-feed mlat geo <lat> <lon> <alt>
  apl-feed mlat private enable
  apl-feed mlat private disable
  apl-feed 978 enable [--serial SERIAL] [--gain GAIN]
  apl-feed 978 disable
  apl-feed 978 setup
  apl-feed 978 status
  apl-feed diagnostics enable
  apl-feed diagnostics disable
  apl-feed apply [--no-restart] [--lock-timeout SECS]
  apl-feed schema
  apl-feed config sync [--dry-run] [--no-restart]
  apl-feed import legacy-config [--no-restart] <path>
  apl-feed backup <file>
  apl-feed restore <file>
  apl-feed restore --check <file>
  apl-feed restore --uuid <uuid> [--check]

Options:
  --force             For restore / claim set / id set: overwrite differing
                      local state.
  --check             For restore: validate the source without writing.
  -h, --help          Show this message.

`apl-feed claim set` reads a claim secret from stdin (or prompts when run
on a TTY) and saves it locally. The feeder will use the new secret on its
next contact with the website. No daemon restart — neither airplanes-feed
nor airplanes-mlat consumes the claim secret.

`apl-feed id set` reads a Feeder ID (UUID) from stdin and saves it
locally. Both airplanes-feed and airplanes-mlat consume the UUID, so this
command restarts both services after writing.

`apl-feed restore --uuid <uuid>` is the website-restore path. It writes
both the supplied UUID and a fresh secret read from stdin in one atomic
two-file commit, then restarts both daemons.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

root_path() {
    local path="$1"
    if [[ "$ROOT" == "/" ]]; then
        printf '%s' "$path"
    else
        printf '%s%s' "${ROOT%/}" "$path"
    fi
}

feeder_id_path() {
    root_path '/etc/airplanes/feeder-id'
}

uuid_file_primary() {
    feeder_id_path
}

uuid_file_legacy() {
    root_path '/usr/local/share/airplanes/airplanes-uuid'
}

uuid_file_boot() {
    root_path '/boot/airplanes-uuid'
}

secret_final_path() {
    root_path '/etc/airplanes/feeder-claim-secret'
}

secret_pending_path() {
    root_path '/etc/airplanes/feeder-claim-secret.pending'
}

secret_version_path() {
    root_path '/etc/airplanes/feeder-claim-secret.version'
}

feed_env_path() {
    if [[ -f "$(root_path '/etc/airplanes/feed.env')" ]]; then
        root_path '/etc/airplanes/feed.env'
        return
    fi
    if [[ -x "$(root_path '/usr/bin/airplanes-feeder')" && -f "$(root_path '/boot/airplanes-config.txt')" ]]; then
        root_path '/boot/airplanes-config.txt'
        return
    fi
    root_path '/etc/airplanes/feed.env'
}

# Canonical write target for feed.env. Always /etc/airplanes/feed.env
# under ROOT, regardless of what's currently on disk. Distinct from
# feed_env_path() — which has a bridged-legacy fallback to
# /boot/airplanes-config.txt for status readers when no canonical file
# exists yet. Writers must NOT use that fallback: translating the legacy
# source file into itself never produces the canonical feed.env that
# the new daemons source. apl-feed/import.sh, apl-feed/mlat.sh, and
# apl-feed/uat.sh all pass this to apl_feed_apply via --feed-env.
feed_env_write_path() {
    root_path '/etc/airplanes/feed.env'
}

# Bootstrap the canonical feed.env from a bridged-legacy boot config when
# canonical is missing. Idempotent: no-op when canonical already exists.
# Detection mirrors feed_env_path()'s legacy fallback: airplanes-feeder
# binary installed (bridge ran) + /boot/airplanes-config.txt present.
#
# Without this, every apl-feed writer (mlat, uat, eventually configure
# wrappers) would error out with "feed.env not found" on a bridged-legacy
# box even though the legacy source carries all the operational keys.
# Auto-bootstrap calls apl_feed_import_legacy_config (which must be in
# scope — apl-feed.sh sources scripts/apl-feed/import.sh after common.sh
# so this is satisfied in production) with --no-restart, since writer
# callers own the post-write restart themselves.
#
# Always returns 0 so bare callers under apl-feed.sh's `set -euo pipefail`
# don't exit before _mlat_emit_result / _uat_emit_result can surface a
# structured error. A failed bootstrap is logged to stderr; the caller's
# subsequent apl_feed_apply then produces a structured filesystem_error
# because canonical still doesn't exist — the user sees both lines.
feed_env_ensure_canonical_for_write() {
    local canonical
    canonical="$(feed_env_write_path)"
    [[ -f "$canonical" ]] && return 0

    local boot_config feeder_binary
    boot_config="$(root_path '/boot/airplanes-config.txt')"
    feeder_binary="$(root_path '/usr/bin/airplanes-feeder')"
    if [[ ! -x "$feeder_binary" || ! -f "$boot_config" ]]; then
        return 0
    fi

    if ! declare -F apl_feed_import_legacy_config >/dev/null; then
        echo "feed_env_ensure_canonical_for_write: apl_feed_import_legacy_config not in scope — source apl-feed/import.sh before invoking writers" >&2
        return 0
    fi

    echo "Bootstrapping canonical feed.env from $boot_config" >&2
    local rc=0
    apl_feed_import_legacy_config --no-restart "$boot_config" || rc=$?
    if (( rc != 0 )); then
        echo "feed_env_ensure_canonical_for_write: bootstrap import failed rc=$rc; the writer's apply will surface a structured filesystem_error next" >&2
    fi
    return 0
}

feed_env_paths() {
    if [[ -f "$(root_path '/etc/airplanes/feed.env')" ]]; then
        root_path '/etc/airplanes/feed.env'
        printf '\n'
        return
    fi
    if [[ -x "$(root_path '/usr/bin/airplanes-feeder')" && -f "$(root_path '/boot/airplanes-config.txt')" ]]; then
        root_path '/boot/airplanes-config.txt'
        printf '\n'
        root_path '/boot/airplanes-env'
        printf '\n'
        return
    fi
    feed_env_path
    printf '\n'
}

# Canonical lock path for feed.env writes. apl_feed_apply takes this
# through --lock-file. Same root_path pattern as feed_env_path — tests
# override this helper so the library doesn't try to open /run/airplanes
# on a test runner that doesn't have that path writable.
feed_env_lock_path() {
    root_path '/run/airplanes/feed-env.lock'
}

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required"
}

canonicalize_secret() {
    printf '%s' "$1" | tr -d '[:space:]-' | tr 'a-z' 'A-Z'
}

validate_secret() {
    local secret="$1"
    [[ "${#secret}" -eq 16 ]] || return 1
    [[ "$secret" =~ ^[A-Z0-9]{16}$ ]]
}

display_secret() {
    local secret="$1"
    printf '%s-%s-%s-%s' \
        "${secret:0:4}" "${secret:4:4}" "${secret:8:4}" "${secret:12:4}"
}

read_secret_file() {
    local path="$1"
    local raw secret
    [[ -f "$path" ]] || return 1
    read -r raw < "$path" || raw=''
    secret="$(canonicalize_secret "$raw")"
    validate_secret "$secret" || die "invalid secret format at $path"
    printf '%s' "$secret"
}

# Daemon user/group that own claim-state files. airplanes-feed.service runs
# as this user; the matching group lets other service accounts (e.g. an
# image-side webconfig dropped into the airplanes-feed group) read the
# secret directly without a sudo bump. Override owner/group via
# APL_FEED_SECRET_OWNER / APL_FEED_SECRET_GROUP for tests; production
# matches the User= line in airplanes-feed.service and the private group
# created in update.sh.
claim_state_owner() {
    printf '%s' "${APL_FEED_SECRET_OWNER:-airplanes-feed}"
}

claim_state_group() {
    printf '%s' "${APL_FEED_SECRET_GROUP:-$(claim_state_owner)}"
}

# Hand off ownership of a claim-state file to the daemon user/group so the
# secret is readable by airplanes-feed.service (and any other service
# account in the airplanes-feed group) without escalating to root. No-ops
# silently when running as a non-root user (chown would EPERM anyway), or
# when the target user/group doesn't yet exist (e.g. very first install
# pass before adduser/addgroup has run).
chown_claim_state() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    [[ "$(id -u)" == "0" ]] || return 0
    local owner group
    owner="$(claim_state_owner)"
    group="$(claim_state_group)"
    getent passwd "$owner" >/dev/null 2>&1 || return 0
    getent group "$group" >/dev/null 2>&1 || return 0
    chown "$owner":"$group" "$path"
}

write_secret_file() {
    local path="$1"
    local secret="$2"
    local dir tmp
    validate_secret "$secret" || die "refusing to write invalid secret"
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="${path}.$$"
    umask 077
    printf '%s\n' "$secret" > "$tmp"
    # Order matters: chown BEFORE chmod 0640. The reverse opens a brief
    # window where the file is group-readable as group=root (the umask 077
    # default). Doing chown first keeps the file 0600 root:root → 0600
    # airplanes-feed:airplanes-feed → 0640 airplanes-feed:airplanes-feed,
    # so no member of group root ever has read access.
    chown_claim_state "$tmp"
    # Mode 0640: owner read/write, group read, other none. Group-read lets
    # service accounts in the airplanes-feed group consume the secret
    # directly. Group-write is intentionally NOT granted — only the
    # daemon user mutates the secret.
    chmod 640 "$tmp"
    mv -f "$tmp" "$path"
}

write_version_file() {
    local version="$1"
    local path tmp
    [[ -n "$version" && "$version" != "null" ]] || return 0
    [[ "$version" =~ ^[0-9]+$ ]] || return 0
    path="$(secret_version_path)"
    mkdir -p "$(dirname "$path")"
    tmp="${path}.$$"
    printf '%s\n' "$version" > "$tmp"
    chown_claim_state "$tmp"
    chmod 640 "$tmp"
    mv -f "$tmp" "$path"
}

read_version_file() {
    local path version
    path="$(secret_version_path)"
    [[ -f "$path" ]] || return 1
    read -r version < "$path" || version=''
    [[ "$version" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$version"
}

feed_env_get() {
    local key="$1"
    local path output
    output="$(
        while IFS= read -r path; do
            [[ -f "$path" ]] || continue
            sed -n \
                -e "s/^${key}=\"\\(.*\\)\"[[:space:]]*$/\\1/p" \
                -e "s/^${key}='\\(.*\\)'[[:space:]]*$/\\1/p" \
                -e "s/^${key}=\\([^#[:space:]]*\\).*$/\\1/p" \
                "$path"
        done < <(feed_env_paths)
    )"
    [[ -n "$output" ]] || return 1
    printf '%s\n' "$output" | tail -n 1
}

apl_auth_token() {
    # Build the v1 Authorization: Bearer token shape `alv1.<uuid>.<secret>`
    # from a raw uuid + secret pair. Canonicalizes both internally so call
    # sites can't accidentally send unnormalized inputs. Returns 0 with the
    # assembled token on stdout, 1 if either input fails its canonical-form
    # check (caller should fail loud — the server would 401 either way).
    local raw_uuid="${1:-}" raw_secret="${2:-}"
    local uuid secret
    uuid="$(canonicalize_uuid "$raw_uuid")" || return 1
    secret="$(canonicalize_secret "$raw_secret")"
    validate_secret "$secret" || return 1
    printf 'alv1.%s.%s' "$uuid" "$secret"
}

canonicalize_uuid() {
    # Strip whitespace + braces + hyphens are kept; lowercase hex; require
    # the canonical 8-4-4-4-12 shape after normalization. Returns 0 with
    # the canonical UUID on stdout, 1 if the input doesn't match.
    local raw uuid
    raw="$(printf '%s' "${1:-}" | tr -d '\n\r\t {}')"
    uuid="$(printf '%s' "$raw" | tr 'A-F' 'a-f')"
    if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        printf '%s' "$uuid"
        return 0
    fi
    return 1
}

read_uuid() {
    local path raw uuid
    for path in "$(feeder_id_path)" "$(uuid_file_legacy)" "$(uuid_file_boot)"; do
        [[ -f "$path" ]] || continue
        raw="$(tr -d '\n\r{}' < "$path")"
        uuid="$(printf '%s' "$raw" | tr 'A-F' 'a-f')"
        if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            printf '%s' "$uuid"
            return 0
        fi
        die "invalid Feeder ID format at $path: $raw"
    done
    die "no Feeder ID file at $(feeder_id_path), $(uuid_file_legacy), or $(uuid_file_boot)"
}

write_uuid() {
    local uuid="$1"
    local path dir tmp
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || die "refusing to write invalid Feeder ID"
    path="$(feeder_id_path)"
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="${path}.$$"
    printf '%s\n' "$uuid" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$path"
}

generate_secret() (
    set +o pipefail
    LC_ALL=C tr -dc 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' </dev/urandom 2>/dev/null | head -c 16
)

restart_feeder_services() {
    # Restart both feeder daemons after a UUID change. Order is
    # `airplanes-feed` first, then `airplanes-mlat` — mlat-client has a
    # 2s sleep + nc reachability check on its INPUT port at startup, so
    # letting the feed side settle first keeps mlat from racing against
    # a still-restarting feed.
    #
    # Used by `apl-feed id set` and `apl-feed restore --uuid X`. Not
    # used by `claim set`: the claim secret is CLI-only data; no daemon
    # consumes it.
    #
    # Skip when ROOT != "/" so a maintenance run with `--root /mnt/...`
    # never bounces the host's real services. Returns 0 on success
    # (including the skip path), 1 if any attempted restart failed.
    if [[ "$ROOT" != "/" ]]; then
        echo "Skipping service restart (--root=$ROOT, not the host root)" >&2
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    local svc rc=0 failed_services=()
    for svc in airplanes-feed airplanes-mlat; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null \
                && ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            # Service isn't running and isn't enabled on this host. Not
            # an error — just skip it silently.
            continue
        fi
        if systemctl restart "$svc" 2>/dev/null; then
            echo "Restarted $svc"
        else
            echo "Could not restart $svc — re-run as root, or: sudo systemctl restart $svc" >&2
            failed_services+=("$svc")
            rc=1
        fi
    done
    if (( rc != 0 )); then
        echo "Restart hint: sudo systemctl restart ${failed_services[*]}" >&2
    fi
    return $rc
}

parse_common_option() {
    case "${1:-}" in
        --root)
            [[ $# -ge 2 ]] || die "--root requires PATH"
            ROOT="$2"
            return 2
            ;;
        --website-url)
            [[ $# -ge 2 ]] || die "--website-url requires URL"
            # shellcheck disable=SC2034  # consumed by http.sh/claim.sh after parse
            WEBSITE_URL="$2"
            _set_website_host
            return 2
            ;;
        --max-retry-time)
            [[ $# -ge 2 ]] || die "--max-retry-time requires N"
            # shellcheck disable=SC2034  # consumed by claim.sh after parse
            MAX_RETRY_TIME="$2"
            return 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            return 0
            ;;
    esac
}

parse_field_from() {
    local file="$1"
    local expr="$2"
    jq -r "$expr | if . == null then empty else . end" < "$file" 2>/dev/null || true
}

json_has_key() {
    local file="$1"
    local key="$2"
    jq -r --arg key "$key" 'has($key)' < "$file" 2>/dev/null || true
}

seconds_until_iso() {
    local iso="$1"
    local target_epoch now delta
    target_epoch="$(date -d "$iso" -u +%s 2>/dev/null || true)"
    if [[ -z "$target_epoch" ]]; then
        echo 0
        return
    fi
    now="$(date -u +%s)"
    delta=$(( target_epoch - now ))
    if (( delta < 0 )); then
        echo 0
    else
        echo "$delta"
    fi
}

human_duration_ago() {
    local seconds="$1"
    local days hours minutes
    [[ "$seconds" =~ ^[0-9]+$ ]] || { printf '%s' "$seconds"; return; }
    if (( seconds < 60 )); then
        printf '%ss ago' "$seconds"
    elif (( seconds < 3600 )); then
        printf '%sm ago' $(( seconds / 60 ))
    elif (( seconds < 86400 )); then
        hours=$(( seconds / 3600 ))
        minutes=$(( (seconds % 3600) / 60 ))
        if (( minutes > 0 )); then
            printf '%sh %sm ago' "$hours" "$minutes"
        else
            printf '%sh ago' "$hours"
        fi
    else
        days=$(( seconds / 86400 ))
        hours=$(( (seconds % 86400) / 3600 ))
        if (( hours > 0 )); then
            printf '%sd %sh ago' "$days" "$hours"
        else
            printf '%sd ago' "$days"
        fi
    fi
}
