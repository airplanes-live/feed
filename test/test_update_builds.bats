#!/usr/bin/env bats
# Tests for install_mlat_client and build_readsb_feed_client, defined in
# scripts/lib/update-builds.sh. Stubs git, systemctl, python3, pip, make
# via PATH manipulation. The AIRPLANES_PYTHON_BIN seam routes the venv
# creation step through the same stubbed python3 so a single shim covers
# both the bare invocation and `python3 -c` / `python3 -m pip` calls.
#
# Helper deps: install-update-common.sh provides getGIT, revision, and
# airplanes_is_build_mode. Tests override getGIT/revision as bash
# functions after sourcing so they don't actually clone/run-git, and
# control airplanes_is_build_mode via the AIRPLANES_BUILD_MODE env var
# (which is the function's real input).

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/scripts/lib/update-builds.sh"
    COMMON_LIB="$REPO_ROOT/scripts/lib/install-update-common.sh"

    TMP="$(mktemp -d)"
    STUB_DIR="$TMP/bin"
    COMMAND_LOG="$TMP/commands.log"
    IPATH="$TMP/install"
    VENV="$IPATH/venv"
    MLAT_GIT="$TMP/mlat-client-git"
    READSB_GIT="$TMP/readsb-git"
    READSB_BIN="$IPATH/feed-airplanes"
    LOGFILE="$TMP/lastlog"
    mkdir -p "$STUB_DIR" "$IPATH"
    : > "$COMMAND_LOG"
    : > "$LOGFILE"

    AIRPLANES_BUILD_MODE=
    export AIRPLANES_BUILD_MODE COMMAND_LOG

    # Default git stub returns a deterministic SHA for ls-remote so the
    # version-skip-check has a stable target. Tests override per-case.
    _stub git '
case "$1" in
    ls-remote)
        printf "git ls-remote %s\n" "$*" >> "$COMMAND_LOG"
        printf "deadbeef\trefs/heads/%s\n" "${3:-master}"
        exit 0
        ;;
    *)
        printf "git %s\n" "$*" >> "$COMMAND_LOG"
        exit 0
        ;;
esac'

    _stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub make 'printf "make %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub cp 'printf "cp %s\n" "$*" >> "$COMMAND_LOG"; /bin/cp "$@"'
    _stub pip '
printf "pip %s\n" "$*" >> "$COMMAND_LOG"
exit "${PIP_EXIT:-0}"'
    _stub python3 '
printf "python3 %s\n" "$*" >> "$COMMAND_LOG"
case "$1" in
    -m)
        case "$2" in
            venv)
                # Mirror real python3 -m venv: create the dir tree and
                # stub binaries the chain expects to find afterward.
                mkdir -p "$3/bin"
                : > "$3/bin/activate"
                printf "#!/bin/sh\nexit 0\n" > "$3/bin/mlat-client"
                chmod +x "$3/bin/mlat-client"
                exit "${PYTHON_VENV_EXIT:-0}"
                ;;
            pip)
                # `python3 -m pip install <X>` — succeed unless overridden.
                exit "${PYTHON_PIP_EXIT:-0}"
                ;;
        esac
        ;;
    -c)
        case "$2" in
            "import setuptools") exit "${PYTHON_IMPORT_SETUPTOOLS_EXIT:-0}" ;;
            "import asyncore")   exit "${PYTHON_IMPORT_ASYNCORE_EXIT:-0}"   ;;
        esac
        ;;
esac
exit 0'

    AIRPLANES_PYTHON_BIN="$STUB_DIR/python3"
    PATH="$STUB_DIR:$PATH"
    export PATH AIRPLANES_PYTHON_BIN

    # shellcheck source=/dev/null
    source "$COMMON_LIB"
    # shellcheck source=/dev/null
    source "$LIB"

    # Override real getGIT (which would actually clone) with a stub that
    # creates the target dir so subsequent `cd $target` succeeds. (`git`
    # is stubbed and `revision` is overridden below, so the dir's git
    # state itself isn't read by anything in the test.)
    getGIT() {
        local target="$3"
        printf "getGIT %s %s %s\n" "$1" "$2" "$3" >> "$COMMAND_LOG"
        if [[ "${GETGIT_EXIT:-0}" != 0 ]]; then
            return "$GETGIT_EXIT"
        fi
        mkdir -p "$target"
        ( cd "$target" && git init -q && git config user.email t@e.invalid \
            && git config user.name t && git commit --allow-empty -q -m fixture )
    }

    # revision normally runs `git rev-parse HEAD` in cwd. Override to a
    # deterministic value so tests can assert on the version file content.
    revision() {
        printf "deadbeef"
    }
}

teardown() {
    rm -rf "$TMP"
}

_stub() {
    local name="$1"
    local body="$2"
    cat > "$STUB_DIR/$name" <<SH
#!/usr/bin/env bash
$body
SH
    chmod +x "$STUB_DIR/$name"
}

# ---------------------------------------------------------------------------
# install_mlat_client
# ---------------------------------------------------------------------------

@test "install_mlat_client: happy path writes mlat_version and leaves \$PWD unchanged" {
    local before_pwd="$PWD"
    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    [ -f "$IPATH/mlat_version" ]
    [ "$(cat "$IPATH/mlat_version")" = "deadbeef" ]
    [ -x "$VENV/bin/mlat-client" ]
    [ "$PWD" = "$before_pwd" ]
}

@test "install_mlat_client: skip when version matches AND service is active" {
    echo deadbeef > "$IPATH/mlat_version"
    mkdir -p "$VENV/bin"
    printf "#!/bin/sh\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"
    _stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; [[ "$1" == "is-active" ]] && exit 0; exit 0'

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    # Skip path: getGIT not invoked, no rebuild attempted.
    ! grep -q "^getGIT " "$COMMAND_LOG"
    ! grep -q "^pip install" "$COMMAND_LOG"
}

@test "install_mlat_client: skip via MLAT_DISABLED=1 even with inactive service" {
    echo deadbeef > "$IPATH/mlat_version"
    mkdir -p "$VENV/bin"
    printf "#!/bin/sh\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"
    # systemctl is-active fails (service inactive)
    _stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; [[ "$1" == "is-active" ]] && exit 1; exit 0'

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 1

    ! grep -q "^getGIT " "$COMMAND_LOG"
}

@test "install_mlat_client: skip via build mode without consulting systemctl" {
    echo deadbeef > "$IPATH/mlat_version"
    mkdir -p "$VENV/bin"
    printf "#!/bin/sh\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"
    AIRPLANES_BUILD_MODE=1
    export AIRPLANES_BUILD_MODE

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    ! grep -q "^getGIT " "$COMMAND_LOG"
    # Build-mode short-circuits the conjunction; systemctl shouldn't be reached
    ! grep -q "^systemctl is-active" "$COMMAND_LOG"
}

@test "install_mlat_client: empty git ls-remote falls back to sentinel and forces rebuild" {
    # Pre-existing version file. Buggy old code with empty MLAT_VERSION
    # would falsely match here via grep -e "" and skip. The empty-guard
    # produces a $RANDOM-$RANDOM sentinel that doesn't match.
    echo "real-version-sha" > "$IPATH/mlat_version"
    mkdir -p "$VENV/bin"
    printf "#!/bin/sh\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"
    _stub git '
case "$1" in
    ls-remote)
        printf "git ls-remote %s\n" "$*" >> "$COMMAND_LOG"
        # Empty stdout: simulates network/auth failure
        exit 0
        ;;
    *)
        printf "git %s\n" "$*" >> "$COMMAND_LOG"
        exit 0
        ;;
esac'

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    # Rebuild proceeded → getGIT was called.
    grep -q "^getGIT https://example/mlat-client master " "$COMMAND_LOG"
}

@test "install_mlat_client: REINSTALL=yes forces rebuild even when skip-conditions match" {
    # Skip would otherwise fire: matching version, mlat-client binary in
    # place, active service. REINSTALL=yes is the operator's explicit
    # override for "rebuild regardless".
    echo deadbeef > "$IPATH/mlat_version"
    mkdir -p "$VENV/bin"
    printf "#!/bin/sh\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"
    _stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; [[ "$1" == "is-active" ]] && exit 0; exit 0'

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" yes 0

    grep -q "^getGIT https://example/mlat-client master " "$COMMAND_LOG"
}

@test "install_mlat_client: missing version file forces rebuild" {
    # No prior $IPATH/mlat_version file at all (fresh-ish install or
    # post-uninstall). The skip's `grep -qs ... mlat_version` fails on
    # the missing file, forcing rebuild.
    [ ! -f "$IPATH/mlat_version" ]
    mkdir -p "$VENV/bin"
    printf "#!/bin/sh\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    grep -q "^getGIT https://example/mlat-client master " "$COMMAND_LOG"
}

@test "install_mlat_client: missing mlat-client binary forces rebuild" {
    # Version file matches but $VENV/bin/mlat-client is gone (e.g.
    # half-broken venv from a prior interrupted update). The skip's
    # shebang grep on the binary fails, forcing rebuild.
    echo deadbeef > "$IPATH/mlat_version"
    [ ! -e "$VENV/bin/mlat-client" ]

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    grep -q "^getGIT https://example/mlat-client master " "$COMMAND_LOG"
}

@test "install_mlat_client: pip install . failure restores backup and prints warning" {
    # The chain restructure (strict && with braced fallback groups) makes
    # the if-test's else branch reachable. A `pip install .` failure now
    # propagates: backup is restored to $VENV with its original content,
    # any pre-existing mlat_version stays untouched (the revision/rm-f
    # group is never reached), and the operator-facing warning prints.
    # Function still returns 0 so update.sh continues to the readsb build.
    mkdir -p "$VENV/bin"
    printf "OLD_VERSION_MARKER\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"
    printf "OLD_SHA" > "$IPATH/mlat_version"

    PIP_EXIT=1
    export PIP_EXIT

    run install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing mlat-client failed"* ]]
    # Backup restored to its original location with its original content.
    [ -x "$VENV/bin/mlat-client" ]
    grep -q OLD_VERSION_MARKER "$VENV/bin/mlat-client"
    # Backup directory consumed by the rename.
    [ ! -e "$VENV-backup" ]
    # Pre-existing version file is preserved — the chain failed before
    # reaching `revision > X || rm -f X`, so neither side of that group
    # touched the file.
    [ "$(cat "$IPATH/mlat_version")" = "OLD_SHA" ]
}

@test "install_mlat_client: venv-creation failure restores backup and prints warning" {
    mkdir -p "$VENV/bin"
    printf "OLD_VERSION_MARKER\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"

    PYTHON_VENV_EXIT=1
    export PYTHON_VENV_EXIT

    run install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing mlat-client failed"* ]]
    [ -x "$VENV/bin/mlat-client" ]
    grep -q OLD_VERSION_MARKER "$VENV/bin/mlat-client"
}

@test "install_mlat_client: source-activate failure restores backup and prints warning" {
    # Override the python3 stub for venv: succeed but write an activate
    # script that returns non-zero from the sourced context. The subtle
    # bit: use `return 1`, NOT `exit 1`. `exit` inside a sourced file
    # terminates the entire subshell immediately, which would also have
    # short-circuited the OLD buggy chain — so the test wouldn't actually
    # exercise the fix. `return` only returns from the sourced file,
    # propagating the non-zero status through the `&&` chain. The new
    # chain catches it; the old `||`-cascade would have masked it.
    _stub python3 '
printf "python3 %s\n" "$*" >> "$COMMAND_LOG"
case "$1" in
    -m)
        case "$2" in
            venv)
                mkdir -p "$3/bin"
                printf "return 1\n" > "$3/bin/activate"
                printf "#!/bin/sh\nexit 0\n" > "$3/bin/mlat-client"
                chmod +x "$3/bin/mlat-client"
                exit 0
                ;;
            pip) exit 0 ;;
        esac
        ;;
    -c) exit 0 ;;
esac
exit 0'

    mkdir -p "$VENV/bin"
    printf "OLD_VERSION_MARKER\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"

    run install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing mlat-client failed"* ]]
    [ -x "$VENV/bin/mlat-client" ]
    grep -q OLD_VERSION_MARKER "$VENV/bin/mlat-client"
}

@test "install_mlat_client: setuptools double-failure restores backup and prints warning" {
    # `python3 -c "import setuptools"` fails (setuptools missing) AND
    # `python3 -m pip install setuptools` also fails — both legs of the
    # `{ ... || ... }` fallback group fail, so the group exits non-zero
    # and the chain aborts. Without the brace grouping, the second
    # leg's `||` would extend across the rest of the chain and a later
    # `&& <always-succeeds>` step could mask this failure.
    mkdir -p "$VENV/bin"
    printf "OLD_VERSION_MARKER\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"

    PYTHON_IMPORT_SETUPTOOLS_EXIT=1
    PYTHON_PIP_EXIT=1
    export PYTHON_IMPORT_SETUPTOOLS_EXIT PYTHON_PIP_EXIT

    run install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing mlat-client failed"* ]]
    [ -x "$VENV/bin/mlat-client" ]
    grep -q OLD_VERSION_MARKER "$VENV/bin/mlat-client"
}

@test "install_mlat_client: asyncore double-failure restores backup and prints warning" {
    # Same shape as the setuptools double-failure test, one group later
    # in the chain. Setuptools succeeds (import returns 0 by default), so
    # PYTHON_PIP_EXIT=1 only ever bites at the asyncore-pip install
    # invocation.
    mkdir -p "$VENV/bin"
    printf "OLD_VERSION_MARKER\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"

    PYTHON_IMPORT_ASYNCORE_EXIT=1
    PYTHON_PIP_EXIT=1
    export PYTHON_IMPORT_ASYNCORE_EXIT PYTHON_PIP_EXIT

    run install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing mlat-client failed"* ]]
    [ -x "$VENV/bin/mlat-client" ]
    grep -q OLD_VERSION_MARKER "$VENV/bin/mlat-client"
}

@test "install_mlat_client: pip install wheel failure restores backup and prints warning" {
    # Wheel install is an unconditional step (no fallback). Its failure
    # aborts the chain directly. Custom python3 stub fails only on
    # `python3 -m pip install wheel` to avoid colliding with the
    # setuptools/asyncore fallback paths (which use the same stub).
    _stub python3 '
printf "python3 %s\n" "$*" >> "$COMMAND_LOG"
case "$1" in
    -m)
        case "$2" in
            venv)
                mkdir -p "$3/bin"
                : > "$3/bin/activate"
                printf "#!/bin/sh\nexit 0\n" > "$3/bin/mlat-client"
                chmod +x "$3/bin/mlat-client"
                exit 0
                ;;
            pip)
                if [ "$3 $4" = "install wheel" ]; then exit 1; fi
                exit 0
                ;;
        esac
        ;;
    -c) exit 0 ;;
esac
exit 0'

    mkdir -p "$VENV/bin"
    printf "OLD_VERSION_MARKER\n" > "$VENV/bin/mlat-client"
    chmod +x "$VENV/bin/mlat-client"

    run install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing mlat-client failed"* ]]
    [ -x "$VENV/bin/mlat-client" ]
    grep -q OLD_VERSION_MARKER "$VENV/bin/mlat-client"
}

@test "install_mlat_client: getGIT failure aborts under set -e" {
    # Bash set -e is suppressed in the dynamic scope of an &&/|| chain,
    # which means a `( ... ) || status=$?` capture pattern actually
    # disables set -e inside the subshell despite an inner `set -e` line.
    # `bats run` has the same problem (it disables set -e for the captured
    # command). Use a fresh `bash -c` instead so set -e inside the
    # captured shell is genuinely active.
    GETGIT_EXIT=1
    export GETGIT_EXIT VENV IPATH MLAT_GIT LOGFILE COMMAND_LOG STUB_DIR \
        AIRPLANES_PYTHON_BIN AIRPLANES_BUILD_MODE PATH

    run bash -c '
set -e
source "'"$COMMON_LIB"'"
source "'"$LIB"'"
getGIT() { return "${GETGIT_EXIT:-1}"; }
revision() { printf "deadbeef"; }
install_mlat_client https://example/mlat-client master \
    "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0
'
    [ "$status" -ne 0 ]
}

@test "install_mlat_client: setuptools/asyncore fallback chain installs missing modules in order" {
    # `python3 -c "import setuptools"` fails → triggers `python3 -m pip
    # install setuptools` fallback. Same for asyncore → pyasyncore.
    PYTHON_IMPORT_SETUPTOOLS_EXIT=1
    PYTHON_IMPORT_ASYNCORE_EXIT=1
    export PYTHON_IMPORT_SETUPTOOLS_EXIT PYTHON_IMPORT_ASYNCORE_EXIT

    install_mlat_client \
        https://example/mlat-client master "$VENV" "$IPATH" "$MLAT_GIT" "$LOGFILE" no 0

    # Both fallbacks fired with the right module names.
    grep -q "^python3 -m pip install setuptools$" "$COMMAND_LOG"
    grep -q "^python3 -m pip install pyasyncore$" "$COMMAND_LOG"
    # And in the right order.
    local setuptools_line asyncore_line
    setuptools_line="$(grep -n 'pip install setuptools' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
    asyncore_line="$(grep -n 'pip install pyasyncore' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
    [ -n "$setuptools_line" ]
    [ -n "$asyncore_line" ]
    [ "$setuptools_line" -lt "$asyncore_line" ]
}

# ---------------------------------------------------------------------------
# build_readsb_feed_client
# ---------------------------------------------------------------------------

@test "build_readsb_feed_client: happy path builds and writes readsb_version, leaves \$PWD unchanged" {
    # Make `cp readsb $READSB_BIN` succeed by seeding a fake binary in
    # the build dir before make would have written it. The getGIT stub
    # creates the dir; we add a readsb file via a make stub that drops
    # one in cwd.
    _stub make '
printf "make %s\n" "$*" >> "$COMMAND_LOG"
[[ "$1" == "clean" ]] && exit 0
printf "#!/bin/sh\nexit 0\n" > readsb
chmod +x readsb
exit 0'

    local before_pwd="$PWD"
    build_readsb_feed_client \
        https://example/readsb dev "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no

    [ -x "$READSB_BIN" ]
    [ -f "$IPATH/readsb_version" ]
    [ "$(cat "$IPATH/readsb_version")" = "deadbeef" ]
    [ "$PWD" = "$before_pwd" ]
}

@test "build_readsb_feed_client: skip when version matches AND binary -V succeeds AND service active" {
    echo deadbeef > "$IPATH/readsb_version"
    cat > "$READSB_BIN" <<'SH'
#!/bin/sh
[ "$1" = "-V" ] && exit 0
exit 0
SH
    chmod +x "$READSB_BIN"
    _stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; [[ "$1" == "is-active" ]] && exit 0; exit 0'

    build_readsb_feed_client \
        https://example/readsb dev "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no

    ! grep -q "^getGIT " "$COMMAND_LOG"
    ! grep -q "^make " "$COMMAND_LOG"
}

@test "build_readsb_feed_client: skip via build mode without consulting systemctl" {
    echo deadbeef > "$IPATH/readsb_version"
    cat > "$READSB_BIN" <<'SH'
#!/bin/sh
[ "$1" = "-V" ] && exit 0
exit 0
SH
    chmod +x "$READSB_BIN"
    AIRPLANES_BUILD_MODE=1
    export AIRPLANES_BUILD_MODE

    build_readsb_feed_client \
        https://example/readsb dev "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no

    ! grep -q "^getGIT " "$COMMAND_LOG"
    ! grep -q "^systemctl is-active" "$COMMAND_LOG"
}

@test "build_readsb_feed_client: empty git ls-remote falls back to sentinel and forces rebuild" {
    echo "real-version-sha" > "$IPATH/readsb_version"
    cat > "$READSB_BIN" <<'SH'
#!/bin/sh
[ "$1" = "-V" ] && exit 0
exit 0
SH
    chmod +x "$READSB_BIN"
    _stub git '
case "$1" in
    ls-remote)
        printf "git ls-remote %s\n" "$*" >> "$COMMAND_LOG"
        exit 0
        ;;
    *)
        printf "git %s\n" "$*" >> "$COMMAND_LOG"
        exit 0
        ;;
esac'
    _stub make '
printf "make %s\n" "$*" >> "$COMMAND_LOG"
[[ "$1" == "clean" ]] && exit 0
printf "#!/bin/sh\n" > readsb
chmod +x readsb
exit 0'

    build_readsb_feed_client \
        https://example/readsb dev "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no

    grep -q "^getGIT https://example/readsb dev " "$COMMAND_LOG"
}

@test "build_readsb_feed_client: REINSTALL=yes forces rebuild even when skip-conditions match" {
    echo deadbeef > "$IPATH/readsb_version"
    cat > "$READSB_BIN" <<'SH'
#!/bin/sh
[ "$1" = "-V" ] && exit 0
exit 0
SH
    chmod +x "$READSB_BIN"
    _stub systemctl 'printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"; [[ "$1" == "is-active" ]] && exit 0; exit 0'
    _stub make '
printf "make %s\n" "$*" >> "$COMMAND_LOG"
[[ "$1" == "clean" ]] && exit 0
printf "#!/bin/sh\nexit 0\n" > readsb
chmod +x readsb
exit 0'

    build_readsb_feed_client \
        https://example/readsb dev "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" yes

    grep -q "^getGIT https://example/readsb dev " "$COMMAND_LOG"
}

@test "build_readsb_feed_client: missing version file forces rebuild" {
    [ ! -f "$IPATH/readsb_version" ]
    cat > "$READSB_BIN" <<'SH'
#!/bin/sh
[ "$1" = "-V" ] && exit 0
exit 0
SH
    chmod +x "$READSB_BIN"
    _stub make '
printf "make %s\n" "$*" >> "$COMMAND_LOG"
[[ "$1" == "clean" ]] && exit 0
printf "#!/bin/sh\nexit 0\n" > readsb
chmod +x readsb
exit 0'

    build_readsb_feed_client \
        https://example/readsb dev "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no

    grep -q "^getGIT https://example/readsb dev " "$COMMAND_LOG"
}

@test "build_readsb_feed_client: binary -V failure forces rebuild" {
    # Version file matches but the existing binary refuses -V (corrupted,
    # ABI mismatch, partial copy from interrupted prior update). The
    # skip's `"$readsb_bin" -V` leg fails → rebuild.
    echo deadbeef > "$IPATH/readsb_version"
    cat > "$READSB_BIN" <<'SH'
#!/bin/sh
exit 1
SH
    chmod +x "$READSB_BIN"
    _stub make '
printf "make %s\n" "$*" >> "$COMMAND_LOG"
[[ "$1" == "clean" ]] && exit 0
printf "#!/bin/sh\nexit 0\n" > readsb
chmod +x readsb
exit 0'

    build_readsb_feed_client \
        https://example/readsb dev "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no

    grep -q "^getGIT https://example/readsb dev " "$COMMAND_LOG"
}

@test "build_readsb_feed_client: make failure aborts under set -e" {
    # See note on the mlat getGIT-failure test: use bash -c so set -e
    # genuinely applies inside the captured shell.
    _stub make '
printf "make %s\n" "$*" >> "$COMMAND_LOG"
[[ "$1" == "clean" ]] && exit 0
exit 2'

    export READSB_GIT READSB_BIN IPATH LOGFILE COMMAND_LOG STUB_DIR \
        AIRPLANES_BUILD_MODE PATH

    run bash -c '
set -e
source "'"$COMMON_LIB"'"
source "'"$LIB"'"
getGIT() { mkdir -p "$3"; ( cd "$3" && git init -q && git config user.email t@e.invalid && git config user.name t && git commit --allow-empty -q -m fixture ); }
revision() { printf "deadbeef"; }
build_readsb_feed_client https://example/readsb dev \
    "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no
'
    [ "$status" -ne 0 ]
}

@test "build_readsb_feed_client: getGIT failure aborts under set -e" {
    GETGIT_EXIT=1
    export GETGIT_EXIT READSB_GIT READSB_BIN IPATH LOGFILE COMMAND_LOG \
        STUB_DIR AIRPLANES_BUILD_MODE PATH

    run bash -c '
set -e
source "'"$COMMON_LIB"'"
source "'"$LIB"'"
getGIT() { return "${GETGIT_EXIT:-1}"; }
revision() { printf "deadbeef"; }
build_readsb_feed_client https://example/readsb dev \
    "$READSB_GIT" "$READSB_BIN" "$IPATH" "$LOGFILE" no
'
    [ "$status" -ne 0 ]
}
