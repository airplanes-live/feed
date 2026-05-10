# Architecture rules

Patterns that look like incidental code style but are actually invariants. Violating them breaks production feeders, breaks the drift-test, opens a security boundary, or leaks stale files on already-upgraded installs. Read before refactoring `update.sh` or extracting/adding lib modules.

## The inline-fallback block

Both `update.sh` (long block before `airplanes_enable_build_mode_from_args "$@"`) and `install.sh` (the `else` branch of the `install-update-common.sh` source-or-fallback at the top) carry an inline copy of helpers from `scripts/lib/install-update-common.sh`.

**Why duplicated:** these two scripts are downloaded standalone via curl-pipe-bash. They need to self-bootstrap *before* the repo is on disk and *before* `source scripts/lib/install-update-common.sh` is possible. The fallback defines `airplanes_path`, `airplanes_init_paths`, `getGIT`, `revision`, etc. inline so the script can run from a single-file download.

**Drift contract** — `test/test_inline_fallback_drift.bats` enforces that inline copies stay in sync with the lib. The actual rule: it compares **selected function bodies** between the inline fallback and `install-update-common.sh`, not whole blocks byte-for-byte. `install.sh`'s `airplanes_init_paths` is checked as a **subset** of the lib version (the inline copy intentionally omits paths only `update.sh` needs, like `BOOT_CONFIG`). Function bodies that exist in both must match exactly.

**Don't:**

- Don't "deduplicate" the block by deleting the inline copy.
- Don't extract its functions into a new lib and skip the inline fallback.
- Don't add new fallback functions unless a new bootstrap need genuinely exists; if you do, extend the drift test to cover them.

## `AIRPLANES_FEED_BRANCH` release-channel mechanism

In `update.sh`'s fallback block, the variable defaults via `/etc/airplanes/release-channel`:

- `update.sh` reads that file to pin the runtime-update branch on image-built feeders. Allowlist is `{main, dev}`. Invalid value aborts (intentional — silent fallback to `main` on a `dev` image is a sticky regression).
- An **explicit `AIRPLANES_FEED_BRANCH` env var bypasses the allowlist** — the env var wins. There's a corresponding test in `test_install_update_common.bats` that pins this.
- **`install.sh`'s standalone fallback hardcodes `AIRPLANES_FEED_BRANCH=main`** and does NOT read the release-channel file. Only `update.sh` does. (Fine in practice: `install.sh` runs once at install time on a fresh box that has no release-channel marker yet.)

## `scripts/lib/` extraction discipline

Five rules observed across the shipped lib files. New libs follow them.

1. **Functions take paths/values as positional arguments.** Don't read or mutate `update.sh`'s config-state globals (`USER`, `MLAT_USER`, `INPUT`, `TARGET`, etc.). Helper utilities from sourced libs (`getGIT`, `revision`, `airplanes_is_build_mode`, `is_unit_masked`, `heal_claim_state_ownership`) are fair game.
2. **Each lib documents its helper deps at the top** ("must be in scope when sourced") so the source-order in `update.sh` stays explicit.
3. **Idempotent leaf helpers + composer entry points.** Small `migrate_X` / `install_X` / `build_X` functions do one thing. `run_X` composers wire them together for callers that need ordered phases (see `update-migrations.sh`'s six `run_*` entry points).
4. **Never `source` legacy config files inside helpers.** Sourcing executes arbitrary user-supplied shell content. `update.sh` sources `feed.env` itself — at the orchestrator boundary where the user-content risk is already accepted. Helpers do not.
5. **Build steps run in subshells:** `( cd "$git_dir" || exit; … )`. The `|| exit` is required by shellcheck SC2164. The subshell prevents the `cd` from leaking to the caller. (Note: `install_mlat_client` has a subshell *inside an `if`-test* where set -e is suppressed and the bare `cd` happens to work — that special case doesn't generalize. New subshells use `|| exit`.)

## `set -e` semantics for execution-path functions

Functions whose contract is "abort the script on failure" — for example `build_readsb_feed_client` invoking `make` — must be invoked as plain commands from `update.sh`. Never `if fn; then …` and never `fn || …`. Bash suppresses `set -e` in the dynamic scope of any tested context (the test of an `if`, a `while`, the left side of `&&`/`||`, after `!`), and that suppression propagates into the called function. If the call sits in a tested context, the `set -e` abort never fires inside the function, even with `set -e` re-enabled there.

This rule applies to **fail-loud build/install helpers**, not to predicate helpers (functions that intentionally return a boolean for use in conditionals — those are designed for tested contexts and work fine there).

## Image vs non-image install branches

`IMAGE_INSTALL` is set by `airplanes_is_image_install`. The two branches diverge on:

- **Config source.** Image: `/boot/airplanes-config.txt` + `/boot/airplanes-env`. Manual install: `/etc/airplanes/feed.env`.
- **Feed binary location.** Image ships a baked-in feed binary; manual installs build readsb from source.

Build mode (`AIRPLANES_BUILD_MODE`) is **orthogonal** — it's "produce a rootfs" mode used by image-builder pipelines. In build mode there's no live systemd to call, no host processes to kill, no live network probes. Helpers that gate on systemd or host state must check `airplanes_is_build_mode` first.

## Daemon runtime state files

Daemons (`airplanes-feed`, `airplanes-mlat`) publish their config decision to `/run/<service>/state` at every activation. The state-writer side lives in `scripts/lib/state-writer.sh`; the reader side in `state-reader.sh`. Both libs are installed to `$IPATH/lib/` for daemon use.

Format: `schema_version=1`, env-style `KEY=value` lines, atomic mktemp+rename so partial writes are never visible. Unit files declare `RuntimeDirectory=` + `RuntimeDirectoryPreserve=restart` so the file survives `Restart=always` cycles.

**`MLAT_ENABLED` is checked before geo** in `airplanes-mlat.sh`'s state classifier — explicit disable wins over a 0/0 (unset coords) misconfiguration. The classifier produces `enabled` / `disabled` / `misconfigured`.

**`update.sh` does NOT disable `airplanes-mlat` at the systemd level** based on config-derived disable. The unit stays enabled; the daemon self-disables via `sleep`+`exit`. User-visible: a `MLAT_ENABLED=false` feeder shows the unit as `enabled+active(sleeping)` rather than `disabled+inactive`. This keeps the daemon-owned state-file pattern coherent — future state consumers don't need to re-derive the predicate from `feed.env`.

Daemons use a **defensive `source`** of the state-writer so a partial install (lib missing or unreadable) can't take the daemon down at startup.

## The historical-ship manifest pattern

There are three manifests, all defined as bash arrays at the call site in `update.sh`:

- `historical_top_level_scripts` — names ever shipped from `scripts/` to `$IPATH`.
- `historical_apl_feed_modules` — names ever shipped from `scripts/apl-feed/` to `$IPATH/apl-feed/`.
- `historical_daemon_libs` — names ever shipped from `scripts/lib/` to `$IPATH/lib/` (i.e. libs that daemons source at runtime).

The matching prune step in `update-migrations.sh:prune_installed_script_artifacts` removes any installed file whose source counterpart is now gone. Symmetric to the wildcard `cp` install (which only ADDs files, never removes).

**Manifests are append-only by convention, not by enforcement.** `test/test_update_manifest.bats` verifies all currently-shipped files are listed AND has explicit retention tests for known-historical names (e.g. `second-mlat.sh`).

**When deleting a shipped file:** keep its name in the manifest array AND add a new retention test in the same shape as the existing ones. Without that, future contributors might "tidy" the array and leak the stale file on already-upgraded feeders.

## Daemon account

User and group are both `airplanes-feed`. Renamed from the historical `airplanes` to avoid collisions with what users typically pick as their console/SSH login on a fresh image flash. The original `airplanes` user is intentionally **not** removed on upgrade — it may be referenced by user-supplied drop-ins or orphan units.

The private `airplanes-feed` group exists so other service accounts can read claim-state files (mode 0640) without escalating to root. Membership grants read access to `/etc/airplanes/feeder-claim-secret`; only add service accounts that legitimately need to reveal claim secrets.

`heal_claim_state_ownership` (in `claim-registration.sh`) fixes ownership on installs that pre-date the group-pivot; runs idempotently on every update.
