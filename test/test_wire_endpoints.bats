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

@test "configure.sh writes TARGET=feed.airplanes.live:30004 + feed2:64004 to feed.env" {
    grep -qE '^TARGET="--net-connector feed\.airplanes\.live,30004,beast_reduce_plus_out,feed2\.airplanes\.live,64004"$' \
        "$REPO_ROOT/configure.sh"
}

@test "configure.sh writes MLATSERVER=feed.airplanes.live:31090 to feed.env" {
    grep -qE '^MLATSERVER="feed\.airplanes\.live:31090"$' "$REPO_ROOT/configure.sh"
}

@test "airplanes-feed.sh image-default TARGET embeds feed.airplanes.live:30004 + feed2:64004" {
    grep -q 'feed\.airplanes\.live,30004,beast_reduce_plus_out,feed2\.airplanes\.live,64004' \
        "$REPO_ROOT/scripts/airplanes-feed.sh"
}

@test "claim CLI posts to /api/feeders/secret" {
    grep -q "/api/feeders/secret" "$REPO_ROOT/scripts/apl-feed/claim.sh"
}
