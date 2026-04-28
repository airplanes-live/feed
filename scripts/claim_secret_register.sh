#!/usr/bin/env bash
# claim_secret_register.sh — Register this feeder's claim secret with
# airplanes.live.
#
# Reads the existing UUID at /usr/local/share/airplanes/airplanes-uuid (or
# /boot/airplanes-uuid on the official image), generates a 16-char canonical
# claim secret if none is persisted yet, and POSTs it to the website's
# /api/feeders/secret endpoint. The secret is written to disk BEFORE the
# POST so that a crash mid-flight can be resumed without server-side state
# diverging from what's on disk.
#
# On success the secret is persisted to /etc/airplanes/claim-secret (mode
# 0600). Subsequent runs reuse it.
#
# Exit codes:
#   0  registration succeeded (HTTP 200 NOOP_REPLAY or 201 Created)
#   1  configuration error or fatal protocol error
#   2  network unreachable
#   3  retry budget exhausted (--max-retry-time)
#   4  feeder predates the claim-secret rollout (use the website's reinstall flow)

set -euo pipefail

ROOT='/'
TARGET_URL=''
DRY_RUN=0
MAX_RETRY_TIME=60

usage() {
    cat <<'USAGE'
Usage: claim_secret_register.sh --target-url URL [--root PATH] [--dry-run]

Options:
  --target-url URL    Website base URL (e.g. https://airplanes.live). Required.
  --root PATH         Filesystem root prefix (for testing in temp dirs).
                      Default: /
  --dry-run           Read UUID + generate secret, print, but don't POST.
  --max-retry-time N  Seconds; cap retry on 429 / 423 reset / 5xx. Default: 60.
  -h, --help          Show this message.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) ROOT="$2"; shift 2 ;;
        --target-url) TARGET_URL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --max-retry-time) MAX_RETRY_TIME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$TARGET_URL" ]]; then
    echo "ERROR: --target-url is required" >&2
    exit 1
fi

# Read UUID from the existing on-disk path; don't migrate, since
# scripts/airplanes-feed.sh still reads from these locations.
UUID_PATH="${ROOT%/}/usr/local/share/airplanes/airplanes-uuid"
if [[ ! -f "$UUID_PATH" ]]; then
    UUID_PATH="${ROOT%/}/boot/airplanes-uuid"
fi
if [[ ! -f "$UUID_PATH" ]]; then
    echo "ERROR: no UUID file at ${ROOT%/}/usr/local/share/airplanes/airplanes-uuid or ${ROOT%/}/boot/airplanes-uuid" >&2
    exit 1
fi
UUID="$(tr -d '\n' < "$UUID_PATH")"

# Validate UUID format up front — the server rejects malformed UUIDs with
# 400 anyway, but failing loud here gives a clearer error message. Pattern
# matches create-uuid.sh: canonical lowercase 8-4-4-4-12.
if [[ ! "$UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "ERROR: invalid UUID format at ${UUID_PATH}: ${UUID}" >&2
    exit 1
fi
echo "UUID: $UUID"

ALPHABET='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

# tr | head triggers SIGPIPE on the tr side once head closes after 16 bytes.
# Under `set -euo pipefail` that propagates a non-zero exit and kills the
# script. Wrap in a subshell with pipefail disabled — `( )` scopes the
# `set +o pipefail` so it doesn't leak.
generate_secret() (
    set +o pipefail
    LC_ALL=C tr -dc "$ALPHABET" </dev/urandom | head -c 16
)

# Persist the secret BEFORE the first POST so a crash between "row created
# server-side" and "secret written to disk" doesn't leave the next run
# generating a different secret and hitting 409 rotation_rejected.
#
# Read precedence:
#   1. existing /etc/airplanes/claim-secret         → reuse (expect NOOP_REPLAY)
#   2. existing /etc/airplanes/claim-secret.pending → reuse (mid-POST resume)
#   3. otherwise → generate fresh + write to .pending
#
# On 200/201 the pending file is atomically promoted to claim-secret.

SECRET_DIR="${ROOT%/}/etc/airplanes"
FINAL_PATH="$SECRET_DIR/claim-secret"
PENDING_PATH="$SECRET_DIR/claim-secret.pending"

if [[ -f "$FINAL_PATH" ]]; then
    read -r SECRET < "$FINAL_PATH" || SECRET=''
elif [[ -f "$PENDING_PATH" ]]; then
    read -r SECRET < "$PENDING_PATH" || SECRET=''
else
    SECRET="$(generate_secret)"
    if (( ! DRY_RUN )); then
        mkdir -p "$SECRET_DIR"
        printf '%s\n' "$SECRET" > "$PENDING_PATH"
        chmod 600 "$PENDING_PATH"
    fi
fi

if [[ -z "$SECRET" ]]; then
    echo "ERROR: read empty secret from filesystem at $FINAL_PATH or $PENDING_PATH" >&2
    exit 1
fi
echo "SECRET: $SECRET"

if (( DRY_RUN )); then
    echo "(dry-run; would POST to $TARGET_URL/api/feeders/secret)"
    exit 0
fi

# Response body for the most recent POST goes to a per-run temp file so
# concurrent or stale runs don't collide.
RESP_BODY="$(mktemp)"
trap 'rm -f "$RESP_BODY"' EXIT

# do_post writes the response body to $RESP_BODY and prints the HTTP status
# code on stdout (or empty string on curl failure; curl_rc holds the exit).
do_post() {
    local body
    body=$(printf '{"uuid":"%s","current_secret":null,"new_secret":"%s"}' \
        "$UUID" "$SECRET")
    curl --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data "$body" \
        --output "$RESP_BODY" \
        --write-out '%{http_code}' \
        "$TARGET_URL/api/feeders/secret"
}

# Parse a JSON top-level field; empty string if missing.
parse_field() {
    jq -r "$1 // empty" < "$RESP_BODY" 2>/dev/null || true
}

# Seconds until a given ISO 8601 timestamp; 0 if past or unparseable. Used
# by the 423 reset_locked retry path.
seconds_until_iso() {
    local iso="$1"
    local target_epoch now
    target_epoch=$(date -d "$iso" -u +%s 2>/dev/null || echo "")
    if [[ -z "$target_epoch" ]]; then
        echo 0
        return
    fi
    now=$(date -u +%s)
    local delta=$(( target_epoch - now ))
    if (( delta < 0 )); then
        echo 0
    else
        echo "$delta"
    fi
}

deadline=$(( $(date +%s) + MAX_RETRY_TIME ))
backoff=1

while true; do
    set +e
    status=$(do_post)
    curl_rc=$?
    set -e

    case "$curl_rc" in
        0) ;;  # HTTP ok (status code in $status); fall through.
        6|7|28)
            echo "ERROR: curl rc=$curl_rc (DNS/connect/timeout) — network unreachable" >&2
            exit 2
            ;;
        *)
            echo "ERROR: curl rc=$curl_rc — $TARGET_URL/api/feeders/secret unreachable" >&2
            exit 2
            ;;
    esac

    error=$(parse_field '.error')
    body_preview=$(head -c 200 "$RESP_BODY" || true)

    case "$status" in
        200|201)
            version=$(parse_field '.version')
            : "${version:=1}"
            # Atomic promotion: pending → final on success. If the secret
            # came from an existing final (NOOP_REPLAY scenario), there's
            # no pending to promote — the file is already in place.
            if [[ -f "$PENDING_PATH" ]]; then
                mkdir -p "$SECRET_DIR"
                mv "$PENDING_PATH" "$FINAL_PATH"
                chmod 600 "$FINAL_PATH"
            fi
            echo "SUCCESS ($status, version $version)"
            echo "Secret persisted to $FINAL_PATH"
            exit 0
            ;;
        400)
            echo "ERROR: 400 bad request — $body_preview" >&2
            exit 1
            ;;
        409)
            case "$error" in
                legacy_unclaimed)
                    echo "ERROR: 409 legacy_unclaimed — pre-secret-era row needs the website's reinstall flow ($body_preview)" >&2
                    exit 4
                    ;;
                rotation_rejected)
                    echo "ERROR: 409 rotation_rejected — server hash mismatched current_secret; local state has diverged" >&2
                    exit 1
                    ;;
                *)
                    echo "ERROR: 409 with unknown error=${error:-<missing>} — $body_preview" >&2
                    exit 1
                    ;;
            esac
            ;;
        423)
            case "$error" in
                feeder_blocked)
                    echo "ERROR: 423 feeder_blocked — admin block, no retry ($body_preview)" >&2
                    exit 1
                    ;;
                reset_locked)
                    reset_until=$(parse_field '.reset_until')
                    if [[ -z "$reset_until" ]]; then
                        echo "ERROR: 423 reset_locked without reset_until field" >&2
                        exit 1
                    fi
                    sleep_for=$(seconds_until_iso "$reset_until")
                    echo "INFO: 423 reset_locked until $reset_until; sleeping ${sleep_for}s" >&2
                    ;;
                *)
                    echo "ERROR: 423 with unknown error=${error:-<missing>} — $body_preview" >&2
                    exit 1
                    ;;
            esac
            ;;
        429)
            sleep_for=$(parse_field '.retry_after')
            : "${sleep_for:=5}"
            echo "INFO: 429 rate-limited; sleeping ${sleep_for}s (server retry_after)" >&2
            ;;
        404)
            ct=$(curl --silent --head --connect-timeout 5 --max-time 10 \
                "$TARGET_URL/api/feeders/secret" 2>/dev/null \
                | grep -i '^content-type' || true)
            if [[ "$ct" != *application/json* ]]; then
                echo "ERROR: 404 non-JSON response — endpoint disabled or wrong URL ($TARGET_URL)" >&2
                exit 1
            fi
            echo "ERROR: 404 from API — $body_preview" >&2
            exit 1
            ;;
        5*)
            sleep_for="$backoff"
            backoff=$(( backoff * 2 ))
            (( backoff > 60 )) && backoff=60
            echo "INFO: $status server error; backing off ${sleep_for}s" >&2
            ;;
        *)
            echo "ERROR: unexpected status $status — $body_preview" >&2
            exit 1
            ;;
    esac

    now=$(date +%s)
    if (( now + sleep_for > deadline )); then
        echo "ERROR: exceeded --max-retry-time=${MAX_RETRY_TIME}s on status $status" >&2
        exit 3
    fi
    sleep "$sleep_for"
done
