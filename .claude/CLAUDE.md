# feed/

Installer and updater shipped to end-user feeder hardware. Bash. Target: Debian / Ubuntu / Raspberry Pi OS, runs as root via curl-pipe-bash. CI is Ubuntu (`ubuntu-24.04`); macOS dev surfaces known portability failures (see `rules/testing.md`).

## Tree map

| Path | Role |
|---|---|
| `update.sh` | Install/update orchestrator. Self-replaces, fetches the repo, runs migrations, builds mlat-client + readsb, writes systemd units, registers claim secret. |
| `install.sh` | Standalone bootstrap. Fetches the repo and delegates to `setup.sh`. Has its own (smaller) inline-fallback block. |
| `setup.sh` | Interactive whiptail config (lat/long, MLAT user, receiver input). |
| `configure.sh` | Builds systemd units, applies config to running services. |
| `uninstall.sh` | Stops/disables units, wipes state, preserves the canonical UUID. |
| `create-uuid.sh` | Per-device UUID generation/migration. |
| `scripts/lib/` | Shared library modules (see `rules/architecture.md` for the extraction discipline). Current set: `install-update-common.sh`, `systemd-helpers.sh`, `claim-registration.sh`, `update-migrations.sh`, `service-account.sh`, `update-builds.sh`, `state-writer.sh`, `state-reader.sh`. |
| `scripts/` | `apl-feed.sh` (CLI dispatcher), `airplanes-feed.sh` / `airplanes-mlat.sh` (daemon scripts), unit files. |
| `scripts/apl-feed/` | CLI command modules: `claim`, `id`, `status`, `backup`, `http`, `common`. |
| `test/` | BATS test suite. See `rules/testing.md`. |

## Where to start for common tasks

| Task | Start at |
|---|---|
| Bug in feeder install/update | `update.sh` + add a BATS test under `test/`. |
| Adding a new shared lib module | Mirror `scripts/lib/update-builds.sh` shape. Read `rules/architecture.md` first. |
| Daemon-state question | `scripts/lib/state-writer.sh` + `state-reader.sh`. State files live at `/run/<service>/state`. |
| MLAT enable/disable behavior | `airplanes-mlat.sh`'s state classifier; `MLAT_ENABLED` is checked before geo. |
| Image-side change (rootfs build, first-run, webconfig) | Wrong repo. |
| Cross-cutting touches feed and another repo | Read `apl-workspace/CLAUDE.md` for the polyrepo orientation. |

## Rules files

- `rules/architecture.md` — load-bearing structural rules (inline-fallback discipline, lib extraction conventions, daemon state-file pattern, manifest pattern, etc.). Read this before adding/extracting any lib module or modifying `update.sh`'s top-level flow.
- `rules/testing.md` — BATS conventions, stub patterns, set-e abort testing, macOS portability inventory, CI workflow list.
- `rules/commit-guidelines.md` — conventional-commits format. Layers on top of the workspace-wide `apl-workspace/.claude/rules/commit-and-pr.md` (which covers PR-body conventions).
- `rules/preserved-behavior.md` — quirks pinned by regression tests; do not "tidy" without an explicit fix proposal.

## Local dev

```
bats test/                  # full suite
bats test/test_X.bats       # one file
```

For Ubuntu parity on a macOS dev box: run via the Docker image at `test/Dockerfile.apl-feed-test`, or install brew bash and use that interpreter. Don't blanket-ignore macOS test failures — only the known-portability cases listed in `rules/testing.md` are expected.
