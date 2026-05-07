#!/usr/bin/env bash
set -euo pipefail

FEED_DIR="${AIRPLANES_FEED_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
UPDATE_DIR="${AIRPLANES_UPDATE_DIR:-}"
if [[ -z "$UPDATE_DIR" ]]; then
    if [[ -d "$FEED_DIR/../airplanes-update" ]]; then
        UPDATE_DIR="$FEED_DIR/../airplanes-update"
    else
        echo "AIRPLANES_UPDATE_DIR is required when ../airplanes-update is unavailable" >&2
        exit 1
    fi
fi

[[ -d "$FEED_DIR" ]] || { echo "Feed dir not found: $FEED_DIR" >&2; exit 1; }
[[ -d "$UPDATE_DIR/skeleton" ]] || { echo "Image skeleton not found: $UPDATE_DIR/skeleton" >&2; exit 1; }
[[ -d "$UPDATE_DIR/boot-configs" ]] || { echo "Image boot configs not found: $UPDATE_DIR/boot-configs" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends git ca-certificates
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

make_repo() {
    local repo="$1"
    local branch="$2"
    chown -R "$(id -u):$(id -g)" "$repo" 2>/dev/null || true
    git -C "$repo" init -q -b "$branch"
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name "Image Rootfs Smoke"
    git -C "$repo" add .
    git -C "$repo" commit -q -m fixture
}

FEED_REPO="$WORK_DIR/feed-source"
MLAT_REPO="$WORK_DIR/mlat-source"
ROOT_DIR="$WORK_DIR/rootfs"
STUB_DIR="$WORK_DIR/bin"
COMMAND_LOG="$WORK_DIR/commands.log"
CLAIM_LOG="$WORK_DIR/claim.log"
RUNTIME_ARG_LOG="$WORK_DIR/feed-runtime.args"

mkdir -p "$FEED_REPO" "$MLAT_REPO" "$ROOT_DIR" "$STUB_DIR"
cp -a "$FEED_DIR/." "$FEED_REPO/"
rm -rf "$FEED_REPO/.git"
make_repo "$FEED_REPO" main

printf '%s\n' "mlat fixture" > "$MLAT_REPO/README"
make_repo "$MLAT_REPO" master

cp -a "$UPDATE_DIR/skeleton/." "$ROOT_DIR/"
mkdir -p "$ROOT_DIR/boot" "$ROOT_DIR/etc/default" "$ROOT_DIR/etc/airplanes" "$ROOT_DIR/usr/bin"
cp "$UPDATE_DIR/boot-configs/airplanes-config.txt" "$ROOT_DIR/boot/airplanes-config.txt"
cp "$UPDATE_DIR/boot-configs/airplanes-env" "$ROOT_DIR/boot/airplanes-env"
if [[ -f "$UPDATE_DIR/boot-configs/airplanes-978env" ]]; then
    cp "$UPDATE_DIR/boot-configs/airplanes-978env" "$ROOT_DIR/boot/airplanes-978env"
fi
sed -i \
    -e 's/^LATITUDE=.*/LATITUDE="52.52000"/' \
    -e 's/^LONGITUDE=.*/LONGITUDE="13.40500"/' \
    -e 's/^ALTITUDE=.*/ALTITUDE="35m"/' \
    -e 's/^USER=.*/USER="image-rootfs-smoke"/' \
    "$ROOT_DIR/boot/airplanes-config.txt"
printf '%s\n' 'VERSION_ID="13"' > "$ROOT_DIR/etc/os-release"
ln -sfn /boot/airplanes-config.txt "$ROOT_DIR/etc/default/airplanes"

cat > "$ROOT_DIR/usr/bin/airplanes-feeder" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then
    exit 0
fi
printf '%s\n' "$*" > "${AIRPLANES_RUNTIME_ARG_LOG:?}"
exit 0
SH
chmod +x "$ROOT_DIR/usr/bin/airplanes-feeder"

IPATH="$ROOT_DIR/usr/local/share/airplanes"
mkdir -p "$IPATH/venv/bin"
cp "$FEED_REPO/update.sh" "$IPATH/update.sh"
# Simulate an upgraded install that still has the legacy second-mlat.sh
# helper left over from an older feed release; update.sh must sweep it
# regardless of whether the new tree carries the file or not. The post-update
# `test ! -e "$IPATH/second-mlat.sh"` below guards the sweep.
printf '#!/bin/bash\nexit 0\n' > "$IPATH/second-mlat.sh"
chmod +x "$IPATH/second-mlat.sh"
cat > "$IPATH/venv/bin/mlat-client" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$IPATH/venv/bin/mlat-client"
git -C "$MLAT_REPO" rev-parse HEAD > "$IPATH/mlat_version"

cat > "$STUB_DIR/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
cat > "$STUB_DIR/id" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" && "${2:-}" == "airplanes-feed" ]]; then
    exit 0
fi
if [[ "${1:-}" == "-u" ]]; then
    printf '0\n'
    exit 0
fi
/usr/bin/id "$@"
SH
cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${COMMAND_LOG:?}"
if [[ "${1:-}" == "is-enabled" ]]; then
    printf 'disabled\n'
fi
exit 0
SH
cat > "$STUB_DIR/journalctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$STUB_DIR/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$STUB_DIR/nc" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$STUB_DIR/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$STUB_DIR/renice" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$STUB_DIR/adduser" <<'SH'
#!/usr/bin/env bash
printf 'adduser %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
cat > "$STUB_DIR/useradd" <<'SH'
#!/usr/bin/env bash
printf 'useradd %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
cat > "$STUB_DIR/apl-feed-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLAIM_LOG:?}"
exit 0
SH
chmod +x "$STUB_DIR"/*

PATH="$STUB_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
COMMAND_LOG="$COMMAND_LOG" \
CLAIM_LOG="$CLAIM_LOG" \
AIRPLANES_RUNTIME_ARG_LOG="$RUNTIME_ARG_LOG" \
AIRPLANES_ROOT="$ROOT_DIR" \
AIRPLANES_SKIP_ROOT_CHECK=1 \
AIRPLANES_PACKAGE_MANAGER=apt \
AIRPLANES_FEED_REPO="file://$FEED_REPO" \
AIRPLANES_FEED_BRANCH=main \
AIRPLANES_MLAT_REPO="file://$MLAT_REPO" \
AIRPLANES_MLAT_BRANCH=master \
APL_FEED_BIN="$STUB_DIR/apl-feed-stub" \
    bash "$FEED_REPO/update.sh"

test -f "$ROOT_DIR/boot/airplanes-config.txt"
test -f "$ROOT_DIR/boot/airplanes-env"
test -f "$ROOT_DIR/etc/airplanes/feeder-id"
grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$ROOT_DIR/etc/airplanes/feeder-id"
test -L "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid"
test "$(readlink "$ROOT_DIR/usr/local/share/airplanes/airplanes-uuid")" = "../../../../etc/airplanes/feeder-id"
test -x "$ROOT_DIR/usr/bin/airplanes-feeder"
test -x "$ROOT_DIR/usr/local/bin/apl-feed"
test -f "$IPATH/apl-feed/common.sh"
test -f "$IPATH/airplanes-feed.sh"
test -f "$IPATH/airplanes-mlat.sh"
test ! -e "$IPATH/second-mlat.sh"
test -f "$ROOT_DIR/etc/systemd/system/airplanes-feed.service"
test -f "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service"
test ! -e "$ROOT_DIR/lib/systemd/system/airplanes-feed.service"
test ! -e "$ROOT_DIR/lib/systemd/system/airplanes-mlat.service"
test ! -e "$ROOT_DIR/etc/airplanes/feed.env"
test -L "$ROOT_DIR/etc/default/airplanes"
test "$(readlink "$ROOT_DIR/etc/default/airplanes")" = "/boot/airplanes-config.txt"

grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-feed.sh' "$ROOT_DIR/etc/systemd/system/airplanes-feed.service"
grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh' "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service"
grep -q 'After=airplanes-first-run.service' "$ROOT_DIR/etc/systemd/system/airplanes-feed.service"
grep -q 'After=airplanes-first-run.service' "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service"
grep -qE '^User=airplanes-feed$' "$ROOT_DIR/etc/systemd/system/airplanes-feed.service"
grep -qE '^User=airplanes-feed$' "$ROOT_DIR/etc/systemd/system/airplanes-mlat.service"
grep -q 'feed2.airplanes.live,64004' "$IPATH/airplanes-feed.sh"
grep -q 'claim register' "$CLAIM_LOG"
grep -q 'systemctl restart airplanes-feed' "$COMMAND_LOG"
grep -q 'systemctl restart airplanes-mlat' "$COMMAND_LOG"
test "$(grep -c 'systemctl daemon-reload' "$COMMAND_LOG")" = "1"

PATH="$STUB_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
AIRPLANES_ROOT="$ROOT_DIR" \
AIRPLANES_RUNTIME_ARG_LOG="$RUNTIME_ARG_LOG" \
    bash "$IPATH/airplanes-feed.sh"

grep -q -- '--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004' "$RUNTIME_ARG_LOG"
grep -q -- '--net-ro-interval 0.2' "$RUNTIME_ARG_LOG"
grep -q -- '--db-file=none' "$RUNTIME_ARG_LOG"
grep -q -- '--max-range 450' "$RUNTIME_ARG_LOG"
if grep -q -- '--net-bi-port 30004,30104' "$RUNTIME_ARG_LOG"; then
    echo "decoder NET_OPTIONS leaked into feed runtime args" >&2
    exit 1
fi

echo "image rootfs smoke passed"
