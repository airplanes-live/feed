# Preserved behavior

No current entries.

When adding one, document the preserved behavior and the regression test pinning it. The previous entry — the mlat install command chain in `install_mlat_client` — was retired when the chain was restructured to make the failure-handling `else` branch reachable; build failures now propagate as originally intended.
