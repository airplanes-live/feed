#!/bin/bash
# airplanes.live feed installer — compat shim.
#
# This file replaces install.sh on feed/main after a stable release exists.
# Users who curl the legacy raw.githubusercontent.com URL get redirected to
# the rendered installer attached to the latest GitHub Release.
#
# Source of truth for the actual install logic is install.sh on feed/dev,
# rendered into dist/install.sh at release time with __FEED_REF__ substituted
# for the tag being released. See docs/RELEASE_CHECKLIST.md.

set -eo pipefail

echo "Switching to the latest stable airplanes.live feed release..."

# -fsSL: fail on HTTP error, silent progress, follow redirects.
# Pipe to sudo bash so the redirected installer keeps the same elevation
# semantics as the legacy curl-pipe-bash form.
#
# pipefail is mandatory here — without it, a curl 404 (release missing or
# yanked) feeds an empty body to bash which exits 0, silently producing a
# "successful" no-op install.
curl -fsSL https://github.com/airplanes-live/feed/releases/latest/download/install.sh | sudo bash -s -- "$@"
