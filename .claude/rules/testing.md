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

All run on `ubuntu-24.04` host. Names below are the status-check display names.

PR + push (workflow `ci.yml`):

- `lint` — shellcheck at warning severity, plus bash syntax check (`bash -n`).
- `unit tests` — full BATS suite.
- `script install (debian:13, bundle)` / `(debian:13, bootstrap)` / `(ubuntu:24, bundle)` / `(ubuntu:24, bootstrap)` — `install.sh` on a fresh OS, either with the full repo mounted (`bundle`) or with `install.sh` alone in a temp dir (`bootstrap`, simulating `curl … \| bash`).
- `image build mode` — runs `update.sh` in `AIRPLANES_BUILD_MODE=1` against a synthetic build-time rootfs (synthetic rootfs from `airplanes-live/airplanes-update`).
- `mounted image upgrade (legacy contract)` — mounts the legacy ARM64 image rootfs (downloaded from `airplanes-live/image-releases`) and runs `update.sh` chroot-style with stubbed systemd; asserts post-update state.
- `mounted image upgrade (new contract)` — same shape, against `airplanes-live/image`. Sources its image asset via the new tier-based library (`test/lib/image-source.sh`) — stable release on `main` paths, the rolling `dev-latest` prerelease on `dev` paths.
- `webconfig drift` — builds a webconfig-flavored rootfs, fingerprints webconfig-owned artifacts, runs `update.sh`, fails on any drift. Catches feed/update.sh clobbering files the image's webconfig layer owns.
- `script upgrade (stable main)` — installs `origin/main` HEAD, seeds legacy `USER=`, runs candidate `update.sh`, asserts MLAT migration + wire endpoints + state files.
- `script upgrade (pre-schema-split pin)` — same with a pinned pre-schema-split source SHA (historical regression coverage).

Manual dispatch only (workflow `image-boot-smoke.yml`, top-level name `Image boot`):

- `image boot (legacy contract)` / `(new contract)` — full QEMU boot + update + reboot + idempotency assertions. **Currently broken end-to-end** — see "QEMU boot smoke" below. The workflow stays `workflow_dispatch`-only until the boot harness is rebuilt; the push trigger was tried and reverted.

## QEMU boot smoke

`test/image-boot-smoke.sh` does not currently produce a working QEMU boot. Every CI run since the workflow gained a push trigger timed out at the 8-minute `QEMU_TIMEOUT` with zero kernel console output. The script-vs-current-Pi-OS incompatibility was investigated locally on Apple Silicon with QEMU 11.0 and the rolling `dev-latest` image. Findings:

1. **kernel8.img is gzip-compressed** in modern Pi OS (Bookworm onwards). `file kernel8.img` → `gzip compressed data`. QEMU's `-kernel` flag expects an uncompressed ARM64 boot executable image; passing the gzip blob makes QEMU boot silently with no console output. Fix: `gunzip -c kernel8.img > kernel8.uncompressed` before passing it to QEMU.

2. **`-M raspi3b` boots silently even with a decompressed kernel.** Same kernel that boots fine under `-M virt` produces zero output on `raspi3b`. QEMU's Pi 3B machine emulation drifts from what current Pi OS kernels expect. No `-d guest_errors` output reveals the cause; only the platform's SD-host peripheral throws `bcm2835_sdhost_read: Bad offset c` long after the kernel should have printed early messages. The script's strategy of "load the kernel and DTB the Pi firmware would" is no longer viable.

3. **`-M virt` boots but exposes storage as virtio, which the Pi initramfs cannot drive.** The Pi OS initramfs (`initramfs8` in `/boot`) bundles modules for Pi-specific hardware (mmc, ahci, ata) but **no virtio drivers**. Booting with virtio-blk reaches the `local-block` retry loop and times out with `ALERT! /dev/vda2 does not exist`. AHCI is the same — modules exist in the initramfs but the udev rules don't autoload them on a generic PCI vendor-id match.

Any real fix needs one of: (a) rebuild the initramfs with virtio modules added; (b) build a generic Debian-based initramfs that just chroots into the rootfs; (c) attach storage on a bus the Pi initramfs already drives via its existing autoload rules. None of these are a small change — they refactor `qemu_command` and `prepare_boot_files` substantially.

The deepened guest probe (UUID-stability, state-file schema, idempotency rerun, mlat is-active) is on disk and ready to run as soon as the boot harness is rebuilt.

## Asset-source library

The mounted-image smokes and the QEMU boot smoke share `test/lib/image-source.sh`, which resolves an image archive from a tiered source list. Tiers today: `release-stable` (excludes prereleases) and `release-any` (newest by `published_at`, prerelease-friendly). Library exits 64 on tier exhaustion — callers MUST handle this as skip-with-notice, not hard failure, so a long-dormant upstream image repo doesn't break feed CI.

Exit-code capture pattern: the library uses `if cmd; then rc=0; else rc=$?; fi`, not `cmd; rc=$?` and not `if ! cmd; then rc=$?`. The first form puts the call in a tested context (suppresses `set -e` propagation from bats's `set -euo pipefail`) AND captures the un-inverted exit code in the else branch. The other forms either abort under `set -e` or capture the wrong value. Mirror this pattern in any future library code that needs to capture rcs explicitly.

## The drift test

`test_inline_fallback_drift.bats` is a contract — see `architecture.md` for the actual function-body comparison rules. It must always pass; CI will block any PR that lets the inline fallback drift from the lib version.
