#!/usr/bin/env bash
# Build phases for the airplanes.live feed scripts: compile + install the
# mlat-client venv and the readsb-based feed client. Sourced by update.sh
# after the cloned tree is available at $GIT.
#
# Helper deps (must be in scope when sourced):
#   getGIT, revision, airplanes_is_build_mode   from install-update-common.sh
#
# Each function takes paths and values as positional arguments and does not
# read or mutate update.sh's config-state globals (USER, TARGET, MLAT_*).
#
# Test seam: the mlat-client venv creation honors AIRPLANES_PYTHON_BIN so
# tests can intercept the python binary without a PATH stub.
#
# The mlat install chain is structured as a strict `&&` sequence with
# intentional fallbacks (`{ a || b; }`) braced into local groups. This
# replaces an earlier free-form `&&`/`||` cascade whose precedence quirk
# (`A && B || C && D` parses as `((A && B) || C) && D`) silently masked
# build failures: any unintentional `||` could reset the chain accumulator
# to success, so a `pip install` failure routed through later success
# steps (`rm -f` always succeeds, `echo` always succeeds) and the
# if-test's else branch — which restores the venv from backup and prints
# a "build failed" warning — never fired. The braced groups confine each
# fallback's scope so the chain ultimately fails when any required step
# does, making the else branch reachable.

# Compute the upstream HEAD SHA for $branch on $repo. Returns a random
# sentinel when the lookup produces no output (network failure, DNS miss,
# git auth issue): the previous inline form
#
#     "$(git ls-remote ... | cut -f1 || echo "$RANDOM-$RANDOM")"
#
# was broken because the trailing `|| echo` only fires when `cut` itself
# fails — without `set -o pipefail`, pipe failures upstream of `cut`
# produce empty stdout, leaving the variable empty. The skip-check then
# uses `grep -e ""` which matches any non-empty version file, falsely
# taking the skip branch and stranding feeders on stale builds when the
# version-check fetch flakes. The empty-guard restores the intended
# "force a mismatch when we couldn't fetch the truth" behavior.
_compute_remote_version() {
    local repo="$1"
    local branch="$2"
    local version
    version="$(git ls-remote "$repo" "$branch" 2>/dev/null | cut -f1)"
    if [[ -z "$version" ]]; then
        version="$RANDOM-$RANDOM"
    fi
    printf '%s' "$version"
}

# Install the mlat-client into a Python venv.
#
# Args:
#   $1  mlat_repo       — git URL for the mlat-client repo
#   $2  mlat_branch     — branch to fetch
#   $3  venv            — venv path (e.g. $IPATH/venv)
#   $4  ipath           — install dir (used for $ipath/mlat_version)
#   $5  mlat_git        — local clone target
#   $6  logfile         — append-only log path for build noise
#   $7  reinstall       — "yes" to force rebuild even when versions match
#   $8  mlat_disabled   — "1" allows skip-without-active-service (mlat
#                          intentionally off via USER=0/disable)
#
# Skip path: when version matches, mlat-client binary exists, and at
# least one of {build mode, active service, mlat-disabled} holds.
#
# Failure handling: getGIT failure aborts under set -e (different from
# the in-build failure path, which restores $venv-backup and continues so
# the readsb build can still run). In-build failure (any required step in
# the install chain returns non-zero) restores $venv from backup and
# prints the documented warning; the function returns 0 so update.sh can
# continue. Note that `revision()` always exits 0 via its own internal
# `|| echo "$RANDOM-$RANDOM"` sentinel (see install-update-common.sh), so
# the `revision > $ipath/mlat_version || rm -f $ipath/mlat_version` group
# in the chain defends against a write failure on $ipath/mlat_version
# itself (disk full, permission denied), not git-dir failure.
install_mlat_client() {
    local mlat_repo="$1"
    local mlat_branch="$2"
    local venv="$3"
    local ipath="$4"
    local mlat_git="$5"
    local logfile="$6"
    local reinstall="$7"
    local mlat_disabled="$8"

    local mlat_version
    mlat_version="$(_compute_remote_version "$mlat_repo" "$mlat_branch")"

    if [[ "$reinstall" != yes ]] && grep -e "$mlat_version" -qs "$ipath/mlat_version" \
        && grep -qs -e '#!' "$venv/bin/mlat-client" && { airplanes_is_build_mode || systemctl is-active airplanes-mlat &>/dev/null || [[ "$mlat_disabled" == "1" ]]; }
    then
        echo
        echo "mlat-client already installed, git hash:"
        cat "$ipath/mlat_version"
        echo
        return 0
    fi

    echo
    echo "Installing mlat-client to virtual environment"
    echo

    getGIT "$mlat_repo" "$mlat_branch" "$mlat_git" &> "$logfile"

    echo 34

    rm -rf "$venv-backup"
    mv -f "$venv" "$venv-backup" &>/dev/null || true

    # Build runs in a subshell so cd and venv activation don't leak to
    # the caller (caller's $PWD is unchanged after this function returns).
    # Strict `&&` chain with `{ a || b; }`-braced fallbacks: each required
    # step (venv creation, source activate, wheel install, `pip install .`)
    # is unconditionally chained, while the setuptools/asyncore "import
    # or install" fallbacks and the `revision`/`rm -f` tail are scoped
    # locally so a fallback succeeding doesn't reset the accumulator for
    # an unrelated earlier failure. The braces matter — without them the
    # `||` would extend across the chain (see the precedence note in the
    # file header).
    if (
        cd "$mlat_git" &&
        "${AIRPLANES_PYTHON_BIN:-/usr/bin/python3}" -m venv "$venv" >> "$logfile" &&
        echo 36 &&
        source "$venv/bin/activate" >> "$logfile" &&
        echo 37 &&
        { python3 -c "import setuptools" || python3 -m pip install setuptools; } &&
        echo 39 &&
        { python3 -c "import asyncore" || python3 -m pip install pyasyncore; } &&
        python3 -m pip install wheel &&
        echo 40 &&
        pip install . &&
        echo 46 &&
        { revision > "$ipath/mlat_version" || rm -f "$ipath/mlat_version"; } &&
        echo 48
    ); then
        rm -rf "$venv-backup"
    else
        rm -rf "$venv"
        mv "$venv-backup" "$venv" &>/dev/null || true
        echo "--------------------"
        echo "Installing mlat-client failed, if there was an old version it has been restored."
        echo "Will continue installation to try and get at least the feed client working."
        echo "Please report this error on Discord."
        echo "--------------------"
    fi
}

# Compile the readsb-based feed client.
#
# Args:
#   $1  readsb_repo     — git URL for the readsb fork
#   $2  readsb_branch   — branch to build (caller picks: dev/jessie/etc.)
#   $3  readsb_git      — local clone target
#   $4  readsb_bin      — output binary path (e.g. $IPATH/feed-airplanes)
#   $5  ipath           — install dir (used for $ipath/readsb_version)
#   $6  logfile         — append-only log path for compile noise
#   $7  reinstall       — "yes" to force rebuild even when versions match
#
# Skip path: when version matches, the existing binary responds to `-V`,
# and at least one of {build mode, active airplanes-feed.service} holds.
#
# Failure handling: getGIT and `make` are plain commands; under set -e
# their failure aborts the script. This is the intended behavior — a
# broken feed client is fatal for an updater run, in contrast to mlat
# (which can be intentionally disabled).
build_readsb_feed_client() {
    local readsb_repo="$1"
    local readsb_branch="$2"
    local readsb_git="$3"
    local readsb_bin="$4"
    local ipath="$5"
    local logfile="$6"
    local reinstall="$7"

    local readsb_version
    readsb_version="$(_compute_remote_version "$readsb_repo" "$readsb_branch")"

    if [[ "$reinstall" != yes ]] && grep -e "$readsb_version" -qs "$ipath/readsb_version" \
        && "$readsb_bin" -V && { airplanes_is_build_mode || systemctl is-active airplanes-feed &>/dev/null; }
    then
        echo
        echo "Feed client already installed, git hash:"
        cat "$ipath/readsb_version"
        echo
        return 0
    fi

    echo
    echo "Compiling / installing the readsb based feed client"
    echo

    echo 72

    getGIT "$readsb_repo" "$readsb_branch" "$readsb_git" &> "$logfile"

    echo "-----------------------------------------------"
    echo "Now compiling code can take a few minutes"
    echo "-----------------------------------------------"

    echo 74

    # Build runs in a subshell so the cd doesn't leak. The subshell is
    # called as a plain statement (not inside an if), so set -e propagates:
    # any failure aborts the script, matching the original inline form
    # where `make` failure was a hard stop for the updater.
    (
        cd "$readsb_git" || exit
        make clean
        make -j2 AIRCRAFT_HASH_BITS=12 >> "$logfile"
        echo 80
        rm -f "$readsb_bin"
        cp readsb "$readsb_bin"
        revision > "$ipath/readsb_version" || rm -f "$ipath/readsb_version"
    )

    echo
}
