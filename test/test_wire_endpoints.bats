#!/usr/bin/env bats

# Fast-feedback regression net for wire-protocol literals. These endpoints
# are the contract between feeders and the airplanes.live infrastructure;
# changing one silently is how production fleets quietly stop reporting.
# An accidental edit fails this test in ~30s, long before the legacy upgrade
# smoke job would surface it. If a literal genuinely needs to change, update
# this test in the same PR — that's the desired friction.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
}

@test "airplanes-feed.sh TARGET default embeds feed.airplanes.live:30004 + feed2:64004" {
    # Brand endpoint lives as a daemon default since feed.env was slimmed
    # to operator data; configure.sh no longer writes TARGET.
    grep -q 'feed\.airplanes\.live,30004,beast_reduce_plus_out,feed2\.airplanes\.live,64004' \
        "$REPO_ROOT/scripts/airplanes-feed.sh"
}

@test "airplanes-mlat.sh MLATSERVER default embeds feed.airplanes.live:31090" {
    grep -qE 'MLATSERVER="\$\{MLATSERVER:-feed\.airplanes\.live:31090\}"' \
        "$REPO_ROOT/scripts/airplanes-mlat.sh"
}

@test "configure.sh does not write brand endpoints or tuning defaults to feed.env" {
    # These keys are owned by the daemon defaults now. Keeping them in
    # the rendered feed.env would freeze them on every feeder. `! grep -q`
    # is a tested context for bash, so set -e doesn't fire on match —
    # use grep -c for the count so a regression actually aborts.
    [ "$(grep -cE '^TARGET=' "$REPO_ROOT/configure.sh")" -eq 0 ]
    [ "$(grep -cE '^MLATSERVER=' "$REPO_ROOT/configure.sh")" -eq 0 ]
    [ "$(grep -cE '^NET_OPTIONS=' "$REPO_ROOT/configure.sh")" -eq 0 ]
    [ "$(grep -cE '^JSON_OPTIONS=' "$REPO_ROOT/configure.sh")" -eq 0 ]
    [ "$(grep -cE '^REDUCE_INTERVAL=' "$REPO_ROOT/configure.sh")" -eq 0 ]
    [ "$(grep -cE '^RESULTS[0-9]*=' "$REPO_ROOT/configure.sh")" -eq 0 ]
    [ "$(grep -cE '^UAT_INPUT=' "$REPO_ROOT/configure.sh")" -eq 0 ]
}

@test "claim CLI posts to /api/feeders/secret" {
    grep -q "/api/feeders/secret" "$REPO_ROOT/scripts/apl-feed/claim.sh"
}

@test "claim CLI uses post_json_bearer (v2 wire shape) for /api/feeders/secret" {
    # DEV-427 migrated /secret from body-auth to bearer. claim.sh must
    # ship every /secret call through post_json_bearer; a post_json call
    # to /secret would send the v1 body shape and the server now returns
    # 400 missing_authorization.
    [ "$(grep -cE "post_json_bearer .+ '/api/feeders/secret'" \
        "$REPO_ROOT/scripts/apl-feed/claim.sh")" -ge 2 ]
    # Negative guard: no legacy post_json call to /secret.
    [ "$(grep -cE "post_json '/api/feeders/secret'" \
        "$REPO_ROOT/scripts/apl-feed/claim.sh")" -eq 0 ]
    # Negative guard: no legacy body-field current_secret in the wire
    # payload. (The string appears once in a user-facing error message
    # explaining a 409 rotation_rejected response — that's not a body
    # key. We match the JSON-key shape `"current_secret":` only.)
    [ "$(grep -cE '"current_secret":' "$REPO_ROOT/scripts/apl-feed/claim.sh")" -eq 0 ]
}

@test "stats uploader posts to /api/feeders/stats" {
    grep -q -- "/api/feeders/stats" "$REPO_ROOT/scripts/airplanes-stats.sh"
}

@test "no script posts to the retired /api/feeders/reception endpoint" {
    # The scalar reception lane was replaced by the raw-snapshot /stats lane.
    # A stray /reception literal would silently 404/410 on every feeder tick.
    [ "$(grep -rlF -- '/api/feeders/reception' "$REPO_ROOT/scripts" | wc -l)" -eq 0 ]
}
