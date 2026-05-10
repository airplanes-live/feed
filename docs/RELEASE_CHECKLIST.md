# Release checklist

Step-by-step runbook for cutting a `feed` release. Lives here so it's versioned with the rest of the repo.

Releases are append-only — if `v0.1.0` fails after publish, fix and tag `v0.1.1`. Never delete a release tag, never force-push to it. GitHub's release-tag protection rules enforce this from the platform side.

## Tag format

Strict semver, lowercase `v` prefix, no leading zeroes, no prereleases:

- `v0.1.0` ✓
- `v1.2.3` ✓
- `v01.2.3` ✗ (leading zero)
- `v0.1.0-rc.1` ✗ (prerelease — not used at the feed layer for v0.1.x; if soak is needed, that happens on the dev channel)

The same regex is enforced in three places:

- `validate-tag` job in `.github/workflows/release.yml` (CI rejects malformed tags).
- `airplanes_resolve_latest_stable_tag` in `scripts/lib/install-update-common.sh` and `update.sh` (feeders ignore non-conforming tags during update resolution).

## Pre-release validation

Before cutting a real tag, exercise the pipeline via `workflow_dispatch`:

```
gh workflow run release.yml -R airplanes-live/feed \
    -f validation_ref=v0.0.0-validation
```

This renders `dist/install.sh` with `__FEED_REF__` substituted to `v0.0.0-validation`, runs the substitution-correctness assertion, runs `bash -n` on the rendered script, and verifies the `SHA256SUMS`. No GitHub Release is published.

If the dispatch run succeeds end-to-end, the release pipeline is ready for a real tag.

## Cutting a release

### 1. Land changes on feed/dev, verify CI is green

All v0.1.x work lands on feed/dev first. CI must be green on the commit you intend to ship.

### 2. Merge feed/dev → feed/main

Standard PR. Squash or merge, your call. The merge commit on feed/main is the commit you'll tag.

At this point `install.sh` on feed/main is the **full installer** (with the `__FEED_REF__` marker intact). This is intentional — release CI renders `dist/install.sh` from this file, so it must contain the marker to substitute.

### 3. Tag the merge commit

```
git fetch origin
git checkout main
git pull --ff-only
git tag -a -s v0.1.0 -m "feed v0.1.0"
git push origin v0.1.0
```

Use annotated signed tags (`-a -s`). The tag push triggers `release.yml`, which:

1. Validates the tag format
2. Runs the full test suite on the tagged commit
3. Renders `dist/install.sh` with `__FEED_REF__=v0.1.0`
4. Asserts the rendered asset contains no remaining `__FEED_REF__` literal
5. Creates a draft GitHub Release with `install.sh`, `update.sh`, `SHA256SUMS`
6. Flips draft to published, marks as `latest`

After the release publishes, `https://github.com/airplanes-live/feed/releases/latest/download/install.sh` returns the tag-pinned installer.

### 4. Apply install.sh shim swap on feed/main

**Only after the release is published.** This step replaces `feed/main/install.sh` with a tiny shim that redirects to `releases/latest/download/install.sh`. Anyone curling the legacy URL keeps getting a working install — they're redirected to the just-published release asset.

Do NOT do this before tagging — if `install.sh` on the tagged commit is a shim, release CI will render the shim (instead of the full installer) and publish that as `dist/install.sh`. The release asset would be a self-referential redirect.

The shim content lives in `dist/install-shim.sh` in the repo. Apply via PR:

```
git checkout main
git pull --ff-only
git checkout -b chore/install-shim-swap
cp dist/install-shim.sh install.sh
git add install.sh
git commit -m "chore(install): replace install.sh with releases/latest shim"
git push origin chore/install-shim-swap
gh pr create --base main --title "Replace install.sh with releases/latest shim" --body "Activates the compat shim now that v0.1.0 release exists."
```

Merge the PR. After this, `feed/main/install.sh` redirects to the release asset.

### 5. Verify

- `curl -fsSL https://github.com/airplanes-live/feed/releases/latest/download/install.sh | head -3` returns the rendered installer (look for the substituted `AIRPLANES_RELEASE_REF='v0.1.0'` line).
- `curl -fsSL https://raw.githubusercontent.com/airplanes-live/feed/main/install.sh | head -3` returns the shim (look for the `curl … releases/latest/download/install.sh` line).
- The release page shows `install.sh`, `update.sh`, `SHA256SUMS` as assets and `v0.1.0` is marked as the latest release.

## What can go wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `validate-tag` job fails | Tag format violation (leading zero, prerelease, missing prefix) | Re-tag with corrected format. Don't delete the bad tag — leave it for archaeology. |
| `render` job: "ERROR: `__FEED_REF__` marker not found in install.sh" | Shim swap happened before tag | Revert the shim swap on feed/main, re-tag with the full installer present. |
| `release` job: asset upload fails | GitHub API blip or permissions | Re-run the failed job. The release is still in draft so this is safe. |
| Published release has wrong assets | Manual upload, wrong source build | Cut next patch tag (`v0.1.1`) and ship that. Never edit the published v0.1.0. |
| User reports `releases/latest/download/install.sh` returns 404 | First release not yet published, or `latest` flag missing | Confirm release is marked `Set as the latest release` on GitHub. |

## Subsequent releases (v0.1.1, v0.2.0, …)

Same as v0.1.0 except step 4 (shim swap) is already done. Skip directly from tag-push (step 3) to verify (step 5).
