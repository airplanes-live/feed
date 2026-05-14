#!/usr/bin/env bash
set -euo pipefail

: "${AIRPLANES_FEED_REPO:?AIRPLANES_FEED_REPO is required}"
: "${AIRPLANES_FEED_BRANCH:?AIRPLANES_FEED_BRANCH is required}"
TEST_PATH="${AIRPLANES_TEST_PATH:-bundle}"
case "$TEST_PATH" in
    bundle|bootstrap) ;;
    *) echo "Unknown AIRPLANES_TEST_PATH: $TEST_PATH (expected bundle|bootstrap)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends bash ca-certificates git python3
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
# and reject legacy body fields. A bare 201 response would let a client
# silently regress to the v1 body shape.
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
            self.wfile.write(json.dumps({"error": "missing_or_malformed_authorization"}).encode())
            return
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        # v2 body must contain ONLY new_secret. current_secret / uuid are
        # legacy keys and prove the client never picked up the migration.
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
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true' EXIT

# Wait for the mock server to bind before continuing.
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
export APL_FEED_SERVER_URL="http://127.0.0.1:18080"
export APL_FEED_MAX_RETRY_TIME=5
export AIRPLANES_PACKAGE_MANAGER=apt

if [[ "$TEST_PATH" == "bootstrap" ]]; then
    mkdir -p /tmp/bootstrap
    cp /workspace/install.sh /tmp/bootstrap/install.sh
    bash /tmp/bootstrap/install.sh
else
    bash /workspace/install.sh
fi

# Post-install assertions (catch install-only regressions before update repairs them).
test -d /usr/local/share/airplanes/git
test -x /usr/local/bin/apl-feed
test -f /etc/airplanes/feed.env

bash /usr/local/share/airplanes/git/update.sh

# Post-update assertions.
test -f /etc/airplanes/feeder-id
test -L /usr/local/share/airplanes/airplanes-uuid
test -f /usr/local/share/airplanes/apl-feed/common.sh
test -f /lib/systemd/system/airplanes-feed.service
test -f /lib/systemd/system/airplanes-mlat.service
test -f /etc/airplanes/feeder-claim-secret
test "$(readlink /etc/default/airplanes)" = "/etc/airplanes/feed.env"
grep -q 'systemctl restart airplanes-feed' /tmp/systemctl.log
# 978 is opt-in: UAT_INPUT must not default to anything in feed.env (the
# initial configure.sh-written file) NOR in the daemon wrapper. Operators
# opt in via `apl-feed 978 enable` (CLI) or webconfig (image), and a fresh
# install leaves the connector unwired.
! grep -q 'UAT_INPUT="127.0.0.1:30978"' /etc/airplanes/feed.env
! grep -q 'UAT_INPUT="127.0.0.1:30978"' /usr/local/share/airplanes/airplanes-feed.sh
