#!/usr/bin/env bash
set -euo pipefail

: "${AIRPLANES_SOURCE_REPO:?AIRPLANES_SOURCE_REPO is required}"
: "${AIRPLANES_CANDIDATE_REPO:?AIRPLANES_CANDIDATE_REPO is required}"

DIAG_DIR=/tmp/script-upgrade-diag
mkdir -p "$DIAG_DIR"
MOCK_PID=

dump_diag() {
    cp -a /etc/airplanes "$DIAG_DIR/etc-airplanes" 2>/dev/null || true
    if [[ -e /etc/default/airplanes ]]; then
        cp -a /etc/default/airplanes "$DIAG_DIR/etc-default-airplanes" 2>/dev/null || true
    fi
    cp /tmp/systemctl.log "$DIAG_DIR/systemctl.log" 2>/dev/null || true
    cp /var/lib/airplanes/runtime/lastlog "$DIAG_DIR/lastlog" 2>/dev/null || true
    cp -a /run/airplanes/feed "$DIAG_DIR/run-airplanes-feed" 2>/dev/null || true
    cp -a /run/airplanes/mlat "$DIAG_DIR/run-airplanes-mlat" 2>/dev/null || true
    git -C /var/lib/airplanes/runtime/git remote -v > "$DIAG_DIR/git-remote.txt" 2>&1 || true
    git -C /var/lib/airplanes/runtime/git rev-parse HEAD > "$DIAG_DIR/git-head.txt" 2>&1 || true
    ls -la /etc/systemd/system/ > "$DIAG_DIR/systemd-units.txt" 2>&1 || true
}

on_exit() {
    local ec=$?
    if [[ -n "$MOCK_PID" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
    fi
    dump_diag
    exit "$ec"
}
trap on_exit EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
# pkg-config is pre-installed on Raspberry Pi OS but absent from debian:13-slim;
# main's update.sh package list doesn't include it (dev's does), so without
# this the readsb build fails to link ncurses during the source install.
apt-get install -y --no-install-recommends bash ca-certificates git pkg-config python3
git config --global --add safe.directory '*'

install -d -m 0755 /usr/local/sbin

cat > /usr/local/sbin/whiptail <<'SH'
#!/usr/bin/env bash
set -euo pipefail
counter=/tmp/whiptail-counter
if printf '%s\n' "$@" | grep -q -- '--inputbox'; then
    n=0
    [[ -f "$counter" ]] && n="$(cat "$counter")"
    n=$((n + 1))
    printf '%s\n' "$n" > "$counter"
    case "$n" in
        1) printf '%s\n' "ci-feeder" >&2 ;;
        2) printf '%s\n' "52.52000" >&2 ;;
        3) printf '%s\n' "13.40500" >&2 ;;
        *) printf '%s\n' "35m" >&2 ;;
    esac
fi
exit 0
SH
chmod +x /usr/local/sbin/whiptail

cat > /usr/local/sbin/systemctl <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> /tmp/systemctl.log
if [[ "${1:-}" == "is-enabled" ]]; then
    printf '%s\n' disabled
fi
exit 0
SH
chmod +x /usr/local/sbin/systemctl

cat > /usr/local/sbin/journalctl <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x /usr/local/sbin/journalctl

cat > /usr/local/sbin/nc <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x /usr/local/sbin/nc

python3 - <<'PY' &
import http.server
import json
import re

# v2 wire shape (DEV-427): require Authorization: Bearer alv1.<uuid>.<secret>
# and reject legacy body fields.
BEARER_RE = re.compile(r"^Bearer alv1\.[0-9a-fA-F-]{32,36}\.[A-Za-z0-9]{1,64}$")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        if self.path != "/api/feeders/secret":
            self.send_response(404)
            self.end_headers()
            return
        auth = self.headers.get("Authorization", "")
        if not BEARER_RE.match(auth):
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "missing_authorization"}).encode())
            return
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        if not isinstance(body, dict) or set(body.keys()) != {"new_secret"}:
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "invalid_request"}).encode())
            return
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"version": 1}).encode())

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 18080), Handler)
server.serve_forever()
PY
MOCK_PID=$!

ready=0
for _ in $(seq 1 50); do
    if python3 -c 'import urllib.request, sys
try:
    urllib.request.urlopen("http://127.0.0.1:18080/_probe", timeout=0.2)
except urllib.error.HTTPError:
    sys.exit(0)
except Exception:
    sys.exit(1)
sys.exit(0)' 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.1
done
[[ "$ready" -eq 1 ]] || { echo "mock HTTP server did not become ready" >&2; exit 1; }

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export APL_FEED_WEBSITE_URL="http://127.0.0.1:18080"
export APL_FEED_MAX_RETRY_TIME=5
export AIRPLANES_PACKAGE_MANAGER=apt

# ---- Phase 1: install source ----
# main's install.sh AND update.sh both hardcode
# REPO="https://github.com/airplanes-live/feed.git". A literal
# `bash /source/install.sh` would re-fetch *public* main into $IPATH/git,
# silently bypassing the SHA pinning of the /source mount. Mimic install.sh
# (which is just mkdir + apt + clone + setup.sh) but seed $IPATH/git from
# the mount, then redirect the in-update.sh re-fetch at the same mount so
# the pin holds end-to-end.
echo "=== Phase 1: install source from $AIRPLANES_SOURCE_REPO ==="
# Phase 1 installs origin/main (the PRE-FHS layout), so it must use main's own
# old paths: main's setup.sh/update.sh hardcode /usr/local/share/airplanes/git.
# The candidate (Phase 3) installs the new /opt layout and migrates this away.
mkdir -p /usr/local/share/airplanes
git clone --branch main "$AIRPLANES_SOURCE_REPO" /usr/local/share/airplanes/git

sed -i \
    -e 's|^REPO=".*airplanes-live/feed\.git"$|REPO="'"$AIRPLANES_SOURCE_REPO"'"|' \
    /usr/local/share/airplanes/git/update.sh

bash /usr/local/share/airplanes/git/setup.sh

# Post-install sanity. Only assert artifacts the source install is guaranteed
# to produce — apl-feed CLI, feed.env-only layout, etc. are dev-branch
# additions that predate this test. Phase 2's detect_source_env picks the
# right config file regardless of which shape the source produced.
test -d /usr/local/share/airplanes/git

# ---- Phase 2: seed USER= state ----
# Force the migration code path: drop any MLAT_* keys the source install may
# have written, leave a single legacy USER=. Detect whichever config file the
# install actually produced — modern main writes /etc/airplanes/feed.env;
# ancient main writes /etc/default/airplanes as a real file.
detect_source_env() {
    if [[ -f /etc/airplanes/feed.env && ! -L /etc/airplanes/feed.env ]]; then
        echo /etc/airplanes/feed.env; return
    fi
    if [[ -f /etc/default/airplanes && ! -L /etc/default/airplanes ]]; then
        echo /etc/default/airplanes; return
    fi
    echo /etc/airplanes/feed.env
}
SOURCE_ENV="$(detect_source_env)"
echo "=== Phase 2: seed USER=ci-source-feeder into $SOURCE_ENV ==="
mkdir -p "$(dirname "$SOURCE_ENV")"
touch "$SOURCE_ENV"
sed -i \
    -e '/^MLAT_USER=/d' \
    -e '/^MLAT_ENABLED=/d' \
    -e '/^USER=/d' \
    -e '/^LATITUDE=/d' \
    -e '/^LONGITUDE=/d' \
    "$SOURCE_ENV"
{
    echo 'USER=ci-source-feeder'
    echo 'LATITUDE=52.52000'
    echo 'LONGITUDE=13.40500'
} >> "$SOURCE_ENV"

# ---- Phase 3: upgrade via candidate ----
# Realistic upgrade path. main's `update.sh` has no working in-place
# self-replace (its condition `if diff "$GIT/update.sh" "$IPATH/update.sh"`
# is satisfied only when files are *identical*, which is a no-op). Real
# feeders upgrade by re-bootstrapping from the latest tree, so we invoke the
# candidate's update.sh directly. The candidate's first action is to fetch
# AIRPLANES_FEED_REPO/AIRPLANES_FEED_BRANCH into $IPATH/git and self-replace
# $IPATH/update.sh — exercising candidate's full install path against the
# source state Phases 1-2 left in place.
echo "=== Phase 3: upgrade via candidate from $AIRPLANES_CANDIDATE_REPO ==="
AIRPLANES_FEED_REPO="$AIRPLANES_CANDIDATE_REPO" \
AIRPLANES_FEED_BRANCH=dev \
    bash /candidate/update.sh

# ---- Phase 4: enabled-USER assertions ----
echo "=== Phase 4: assertions (enabled-USER migration) ==="

# 4A. MLAT schema migration
test -f /etc/airplanes/feed.env

env -i bash -c '
    set -euo pipefail
    # shellcheck disable=SC1091
    source /etc/airplanes/feed.env
    [[ "${MLAT_USER:-}"    == "ci-source-feeder" ]] || { echo "FAIL: MLAT_USER=${MLAT_USER:-<unset>}" >&2; exit 1; }
    [[ "${MLAT_ENABLED:-}" == "true" ]]             || { echo "FAIL: MLAT_ENABLED=${MLAT_ENABLED:-<unset>}" >&2; exit 1; }
'

[[ "$(grep -c '^USER='        /etc/airplanes/feed.env || true)" -eq 0 ]] \
    || { echo "FAIL: USER= line not removed from feed.env" >&2; exit 1; }
[[ "$(grep -c '^MLAT_USER='     /etc/airplanes/feed.env)" -eq 1 ]] \
    || { echo "FAIL: expected exactly one MLAT_USER= line" >&2; exit 1; }
[[ "$(grep -c '^MLAT_ENABLED='  /etc/airplanes/feed.env)" -eq 1 ]] \
    || { echo "FAIL: expected exactly one MLAT_ENABLED= line" >&2; exit 1; }

# Modern shape: legacy file is now a symlink to feed.env
if [[ -e /etc/default/airplanes ]]; then
    [[ "$(readlink /etc/default/airplanes)" = "/etc/airplanes/feed.env" ]] \
        || { echo "FAIL: /etc/default/airplanes is not a symlink to feed.env" >&2; exit 1; }
fi

# 4B. Wire-protocol contract — after update.sh's default-prune migrator
# strips canonical brand-endpoint values from feed.env, the daemon-effective
# TARGET/MLATSERVER come from the wrapper defaults. Source feed.env, apply
# the same `${VAR:-default}` shape the wrappers use, and assert the result.
env -i bash -c '
    set -euo pipefail
    # shellcheck disable=SC1091
    source /etc/airplanes/feed.env
    TARGET="${TARGET:-"--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"}"
    MLATSERVER="${MLATSERVER:-feed.airplanes.live:31090}"
    [[ "${TARGET}"     == *"feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004"* ]] \
        || { echo "FAIL: TARGET=${TARGET:-<unset>}" >&2; exit 1; }
    [[ "${MLATSERVER}" == "feed.airplanes.live:31090" ]] \
        || { echo "FAIL: MLATSERVER=${MLATSERVER:-<unset>}" >&2; exit 1; }
'

grep -q 'feed\.airplanes\.live,30004,beast_reduce_plus_out,feed2\.airplanes\.live,64004' \
    /opt/airplanes/current/share/airplanes/airplanes-feed.sh \
    || { echo "FAIL: failover TARGET literal missing in installed airplanes-feed.sh default" >&2; exit 1; }

grep -q 'feed\.airplanes\.live:31090' /opt/airplanes/current/share/airplanes/airplanes-mlat.sh \
    || { echo "FAIL: MLATSERVER literal missing in installed airplanes-mlat.sh default" >&2; exit 1; }

grep -rq '/api/feeders/secret' /opt/airplanes/current/share/airplanes/ \
    || { echo "FAIL: /api/feeders/secret reference missing" >&2; exit 1; }

# 4C. Daemon state-file pattern
# Snapshot feed.env so we can mutate it for the disabled subtest and restore.
cp /etc/airplanes/feed.env /tmp/feed.env.snapshot

# C.1 — airplanes-mlat in disabled state. Daemon does
# `unset MLAT_ENABLED; source feed.env`, so write the value to the file rather
# than passing inline env (which would be wiped by the unset).
sed -i '/^MLAT_ENABLED=/d' /etc/airplanes/feed.env
echo 'MLAT_ENABLED=false' >> /etc/airplanes/feed.env
mkdir -p /run/airplanes/mlat
timeout 3 bash /opt/airplanes/current/share/airplanes/airplanes-mlat.sh || true

[[ -f /run/airplanes/mlat/state ]] \
    || { echo "FAIL: /run/airplanes/mlat/state not written" >&2; exit 1; }
grep -q '^schema_version=1$'          /run/airplanes/mlat/state \
    || { echo "FAIL: airplanes-mlat state missing schema_version=1" >&2; exit 1; }
grep -q '^state=disabled$'            /run/airplanes/mlat/state \
    || { echo "FAIL: airplanes-mlat state not 'disabled'" >&2; exit 1; }
grep -q '^reason=mlat_enabled_false$' /run/airplanes/mlat/state \
    || { echo "FAIL: airplanes-mlat reason not 'mlat_enabled_false' (classifier order regression?)" >&2; exit 1; }

# Restore for C.2
cp /tmp/feed.env.snapshot /etc/airplanes/feed.env

# C.2 — airplanes-feed in enabled state. Stub the feed binary so exec succeeds
# quickly and the script terminates (otherwise we'd block on a real binary).
mkdir -p /run/airplanes/feed
AIRPLANES_FEED_BIN=/bin/true \
    timeout 3 bash /opt/airplanes/current/share/airplanes/airplanes-feed.sh || true

[[ -f /run/airplanes/feed/state ]] \
    || { echo "FAIL: /run/airplanes/feed/state not written" >&2; exit 1; }
grep -q '^schema_version=1$' /run/airplanes/feed/state \
    || { echo "FAIL: airplanes-feed state missing schema_version=1" >&2; exit 1; }
grep -q '^state=enabled$'    /run/airplanes/feed/state \
    || { echo "FAIL: airplanes-feed state not 'enabled'" >&2; exit 1; }

# ---- Phase 5: disabled-USER second subcase ----
# A disabled legacy USER=0 must migrate to MLAT_USER="" + MLAT_ENABLED=false,
# not MLAT_ENABLED=true with empty MLAT_USER (which would trip the daemon's
# strict-fail exit-64 path).
echo "=== Phase 5: assertions (disabled-USER migration, USER=0) ==="
sed -i \
    -e '/^MLAT_USER=/d' \
    -e '/^MLAT_ENABLED=/d' \
    -e '/^USER=/d' \
    /etc/airplanes/feed.env
echo 'USER=0' >> /etc/airplanes/feed.env

# After Phase 3 self-replace, $IPATH/update.sh is the candidate version.
# Pass the env vars explicitly so it doesn't fall back to the public main
# branch (which would self-replace away from candidate).
AIRPLANES_FEED_REPO="$AIRPLANES_CANDIDATE_REPO" \
AIRPLANES_FEED_BRANCH=dev \
    bash /var/lib/airplanes/runtime/git/update.sh

env -i bash -c '
    set -euo pipefail
    # shellcheck disable=SC1091
    source /etc/airplanes/feed.env
    [[ "${MLAT_ENABLED:-}" == "false" ]] \
        || { echo "FAIL: USER=0 should yield MLAT_ENABLED=false, got ${MLAT_ENABLED:-<unset>}" >&2; exit 1; }
    [[ -z "${MLAT_USER:-}" ]] \
        || { echo "FAIL: USER=0 should yield empty MLAT_USER, got ${MLAT_USER}" >&2; exit 1; }
'

echo "=== Upgrade smoke OK ==="
