# Testing rules

How to write and run tests, and which test failures to ignore on a dev laptop.

## Where tests live and how to run them

Tests live in `feed/test/` (note: singular `test`, not `tests`). Framework: BATS.

```
bats test/                  # full suite
bats test/test_X.bats       # one file
```

For Ubuntu parity on a macOS dev machine: run via the Docker image at `test/Dockerfile.apl-feed-test`, or install brew bash and use that interpreter when invoking bats.

## Stub pattern

Tests stub external commands via PATH manipulation plus a `COMMAND_LOG` file. Each test's `setup()`:

1. Creates a temp `STUB_DIR`.
2. Writes minimal shell scripts there that echo their argv into `COMMAND_LOG`.
3. Prepends `STUB_DIR` to `PATH`.

Assertions then `grep` `COMMAND_LOG` to check what was called and in what order. Look at `test/test_update_builds.bats` and `test/test_service_account.bats` for canonical examples.

## Sourcing libs in tests

Source order matters. In `setup()`:

1. `install-update-common.sh` first (defines `getGIT`, `revision`, `airplanes_is_build_mode`).
2. Any other libs the function-under-test depends on (e.g. `claim-registration.sh` for `heal_claim_state_ownership`).
3. The lib defining the function under test.

Override `getGIT`, `revision`, and similar helpers as bash functions **after** sourcing — that gives the test deterministic substitutes without needing a PATH stub.

## Testing `set -e` abort behavior

Non-obvious. Bash suppresses `set -e` in the dynamic scope of any tested context. Both of these patterns put the captured command in a tested context and silently disable `set -e` inside it:

```
run my_function …                    # bats's run captures into a tested context
( set -e; my_function … ) || st=$?   # the `||` wraps the subshell as tested
```

Even with `set -e` re-enabled inside, the suppression propagates from the outer scope. To genuinely test "function X aborts under set -e when Y fails", run the function inside a fresh `bash -c` invocation:

```
run bash -c '
set -e
source "'"$COMMON_LIB"'"
source "'"$LIB"'"
getGIT() { return 1; }
my_function …
'
[ "$status" -ne 0 ]
```

The fresh shell has its own dynamic scope; `set -e` there is genuinely active. Canonical pattern: see the `getGIT failure aborts` cases in `test/test_update_builds.bats`.

## Test seams

`update-builds.sh` exposes `${AIRPLANES_PYTHON_BIN:-/usr/bin/python3}` so the venv-creation step can be intercepted by a single python stub without needing PATH manipulation to override an absolute path. Apply the same shape to any new helper that hardcodes an absolute interpreter path — production behavior is unchanged when the env var isn't set.

## macOS dev parity

CI runs on `ubuntu-24.04`. Dev on macOS surfaces a recurring set of expected failures from GNU/Bash version differences. They are NOT regressions — but only ignore the categories listed below. A CI-green / macOS-red discrepancy in newly-written code outside these categories might still be a real bug.

Known portability cases:

- **GNU-only flags.** `stat -c '%a'` (BSD wants `stat -f '%A'`), `mv -fT` (BSD `mv` has no `-T`).
- **Bash 4.3+ namerefs.** `local -n` / `declare -n`. macOS ships Bash 3.2; brew Bash 5.x works.
- **`[[ … ]]` inside `#!/bin/sh` shebangs.** Works on macOS (sh is bash) but fails on Ubuntu (sh is dash). Use POSIX `[ … = … ]` in any test stub that uses a `#!/bin/sh` shebang, or switch the shebang to `#!/bin/bash`.
- **Network-flaky paths.** `getGIT`'s wget archive fallback may fail on macOS depending on local DNS / ICMP behavior.

Don't blanket-ignore. Default mental model: if a failing test on macOS doesn't fall into one of the above, treat it as a real signal until proven otherwise.

## CI workflows

All run on `ubuntu-24.04` host:

- `bats` — full BATS suite.
- `shellcheck + bash -n` — shellcheck at warning severity, plus bash syntax check.
- `update-regression smoke` — `update.sh` regression run.
- `installer smoke` × 4 — debian:13-slim and ubuntu:24.04, each in bundled (`install.sh`) and standalone (`update.sh` direct) modes.
- `image rootfs smoke` and `image release rootfs smoke` — Docker rootfs builds.

## The drift test

`test_inline_fallback_drift.bats` is a contract — see `architecture.md` for the actual function-body comparison rules. It must always pass; CI will block any PR that lets the inline fallback drift from the lib version.
