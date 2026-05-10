# Preserved behavior

Places where the code looks wrong but is preserved verbatim because changing the behavior needs a deliberate conversation. Each entry has a regression test pinning it; the test will fail if the code is "tidied", and that's the signal to think rather than rewrite.

## The mlat install command chain — `install_mlat_client` in `scripts/lib/update-builds.sh`

The mixed `&& / ||` chain inside the `if` ends with:

```
…
&& revision > "$ipath/mlat_version" || rm -f "$ipath/mlat_version" \
&& echo 48
```

Because `rm -f` always returns 0, the chain *always* exits 0 — meaning the surrounding `if/then/else` always takes the success branch and the `else` (the "Installing mlat-client failed" message + venv-backup restore) is effectively unreachable through normal failures inside the chain (e.g. a `pip install .` that returns non-zero).

Pinned by `test_update_builds.bats: install_mlat_client: pip failure is masked by chain (regression — preserve verbatim)`. Don't reorder, regroup, or simplify the chain. If you want to fix the masking so failures actually trigger the rollback, propose the behavior change explicitly in its own PR — it's a real bug, just not one to fix as a side effect of a refactor.
