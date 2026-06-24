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
#
# Order is path-then-userinfo, not the other way around: a path with an
# embedded `@` (e.g. https://airplanes.live/api/user@example) would otherwise
# get mis-tagged as host=example. We also greedy-strip userinfo (##*@) so a
# pathological double-@ in userinfo lands on the canonical separator.
#
# The result is then validated against a hostname charset (alnum, hyphen,
# dot, colon). If the source URL contains anything outside that set (CRLF,
# spaces, `=` from a deliberate ` level=error` smuggle), WEBSITE_HOST is
# set to `invalid` rather than risking a journal-line injection.
_set_website_host() {
    local s="${WEBSITE_URL#*://}"
    s="${s%%/*}"          # strip path
    s="${s%%\?*}"         # strip query
    s="${s%%#*}"          # strip fragment
    s="${s##*@}"          # strip userinfo (greedy: pick last @)
    if [[ "$s" =~ ^[A-Za-z0-9.:-]+$ ]]; then
        WEBSITE_HOST="$s"
    else
        WEBSITE_HOST="invalid"
    fi
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
apl-feed — airplanes.live feeder control

Usage: apl-feed <command> [subcommand] [options]

Commands:
  status        Show feeder status
  claim         Manage the claim secret (register/show/rotate/set)
  id            Manage the Feeder ID (set)
  mlat          Configure MLAT (enable/disable/setup/user/geo/private)
  978           Configure 978 MHz UAT (enable/disable/setup/status)
  diagnostics   Enable or disable diagnostics push (enable/disable)
  config        Show config and remote sync (show/sync/enable/disable)
  import        Import configuration (legacy-config)
  apply         Apply config keys from a JSON payload on stdin
  schema        Print the feed.env config schema as JSON
  backup        Write a config backup (claim secret + Feeder ID)
  restore       Restore from a backup file or the website

Options:
  -h, --help    Show this message.

Run 'apl-feed <command> --help' for details on a command.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Usage-error exit path. Prints an optional "ERROR: <message>" line, then
# the relevant command's help, both to stderr, and exits 2 — the
# argparse / bash-builtin / coreutils convention for "invoked wrong",
# kept distinct from die()'s exit 1 for runtime / precondition failures.
# The usage function is named (not called directly) so callers can refer
# to a usage_* defined in a later-sourced module; declare -F guards a
# mistyped or not-yet-sourced name by falling back to the top-level index.
usage_error() {
    local usage_fn="$1"
    shift || true
    if [[ $# -gt 0 && -n "$1" ]]; then
        echo "ERROR: $*" >&2
    fi
    if declare -F "$usage_fn" >/dev/null 2>&1; then
        "$usage_fn" >&2
    else
        usage >&2
    fi
    exit 2
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
    root_path '/var/lib/airplanes/runtime/airplanes-uuid'
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
    if [[ -f "$(root_path '/etc/airplanes/image-install')" && -f "$(root_path '/boot/airplanes-config.txt')" ]]; then
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
# Detection mirrors feed_env_path()'s legacy fallback: the image-install
# marker is present + /boot/airplanes-config.txt present.
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

    local boot_config image_marker
    boot_config="$(root_path '/boot/airplanes-config.txt')"
    image_marker="$(root_path '/etc/airplanes/image-install')"
    if [[ ! -f "$image_marker" || ! -f "$boot_config" ]]; then
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
    if [[ -f "$(root_path '/etc/airplanes/image-install')" && -f "$(root_path '/boot/airplanes-config.txt')" ]]; then
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

# Single-key read over the effective config files (feed_env_paths order,
# later files override). Delegates to the strict reader from
# feed-env-apply.sh — the same parser behind `apply` and `config show` —
# so the CLI has one feed.env parser. Contract: rc 0 + value when the
# key is present and non-empty; rc 1 when absent, explicitly empty, or
# on a contract-violating line the strict reader drops (callers treat
# absent and empty identically, e.g. UAT_INPUT's disabled state).
feed_env_get() {
    local key="$1"
    local path value="" found=0
    if ! declare -F _apl_feed_apply_read >/dev/null 2>&1; then
        echo "feed_env_get: feed-env-apply.sh not in scope; reinstall feed" >&2
        return 1
    fi
    while IFS= read -r path; do
        [[ -f "$path" ]] || continue
        local -A _feg_file=()
        _apl_feed_apply_read "$path" _feg_file
        if [[ -n "${_feg_file[$key]+set}" ]]; then
            value="${_feg_file[$key]}"
            found=1
        fi
    done < <(feed_env_paths)
    (( found )) || return 1
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

# parse_report_status RAW
#   echoes one of: enabled, disabled, invalid, empty
#   "empty" means the raw value was empty (key unset on the line read).
#   Treated as enabled by report_status_consent.
parse_report_status() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        printf '%s' 'empty'
        return
    fi
    local lower
    lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    # strip leading/trailing whitespace
    lower="${lower#"${lower%%[![:space:]]*}"}"
    lower="${lower%"${lower##*[![:space:]]}"}"
    case "$lower" in
        true|yes|1|on) printf '%s' 'enabled' ;;
        false|no|0|off) printf '%s' 'disabled' ;;
        *) printf '%s' 'invalid' ;;
    esac
}

# report_status_consent
#   Resolve the REPORT_STATUS privacy toggle across the effective feed.env
#   files. Echoes one of: enabled | disabled | invalid.
#     - unset/absent              → enabled (the opt-out default)
#     - present but the strict reader refuses it (same-line comment, broken
#       quoting) → invalid: privacy toggles fail CLOSED, never to enabled
#     - parseable value           → enabled/disabled/invalid via parse_report_status
#   Single-sourced here so airplanes-diagnostics.sh and airplanes-stats.sh
#   apply the identical fail-closed rule — a drift between them is a privacy bug.
report_status_consent() {
    local raw
    raw="$(feed_env_get REPORT_STATUS 2>/dev/null || true)"
    if [[ -z "$raw" ]]; then
        local _rs_path
        while IFS= read -r _rs_path; do
            [[ -f "$_rs_path" ]] || continue
            if grep -q '^[[:space:]]*REPORT_STATUS=.' "$_rs_path"; then
                printf '%s' 'invalid'
                return
            fi
        done < <(feed_env_paths)
        printf '%s' 'enabled'
        return
    fi
    parse_report_status "$raw"
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

# Stop the image-side airplanes-claim.timer after a successful claim write
# (claim register / claim set). The timer drives retry of unclaimed feeders;
# once the secret is on disk it has nothing to do, and every subsequent
# 5-min fire logs `Condition check resulted in ... skipped` against the
# service unit — which the webconfig "Claim activity" panel surfaces as
# noise. The timer's WantedBy=timers.target keeps it re-armable on next
# reboot if the secret is ever deleted (factory reset, manual reclaim).
#
# Defensive on every leg: silently no-ops on hosts without systemctl,
# hosts without the timer unit (legacy non-image installs), and non-root
# --root invocations (mirrors restart_feeder_services — stopping the
# host's timer when operating on a different rootfs is wrong).
#
# APL_FEED_TEST_TIMER_STOP_FORCE is a test-only override so bats
# integration tests can exercise the helper while using --root to scope
# filesystem fixtures. The TEST prefix is deliberate so a stray export
# in a production shell is visible at a glance; production callers must
# never set this.
stop_claim_timer_if_present() {
    if [[ "$ROOT" != "/" && -z "${APL_FEED_TEST_TIMER_STOP_FORCE:-}" ]]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    systemctl --no-block stop airplanes-claim.timer 2>/dev/null || true
}

# Nudge airplanes-config-sync.service so a just-claimed feeder syncs its
# remote configuration within seconds instead of waiting for the unit's
# ~60s timer tick. Mirrors stop_claim_timer_if_present's guards:
# host-root-only (so a chroot / build-mode run doesn't poke the host's
# systemd) and systemctl-present. The service self-gates — it skips when
# the claim secret is absent (ConditionPathExists) and exits silently
# unless REMOTE_CONFIG_ENABLED is opted in — so an unconditional nudge on
# every secret-landed path is safe and idempotent.
#
# APL_FEED_TEST_CONFIG_SYNC_NUDGE_FORCE is the test-only override (separate
# from APL_FEED_TEST_TIMER_STOP_FORCE so a test can exercise one helper
# without implicitly forcing the other). Production callers must never set
# it.
nudge_config_sync_if_present() {
    if [[ "$ROOT" != "/" && -z "${APL_FEED_TEST_CONFIG_SYNC_NUDGE_FORCE:-}" ]]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    systemctl --no-block start airplanes-config-sync.service 2>/dev/null || true
}

# Run the systemd side effects for "a claim secret just landed on disk":
# stop the now-pointless claim retry timer, then nudge the config syncer.
# Grouping the two keeps every secret-write success path consistent — a
# future path can't silently pick up one side effect and miss the other.
# Both self-gate, so calling this on a re-confirm or an already-claimed
# feeder is a harmless no-op.
claim_secret_landed_side_effects() {
    stop_claim_timer_if_present
    nudge_config_sync_if_present
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
