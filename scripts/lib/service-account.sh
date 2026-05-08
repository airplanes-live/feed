#!/usr/bin/env bash
# Service-account creation for the airplanes-feed daemon. Sourced by
# update.sh after the cloned tree is available at $GIT.
#
# Helper deps (must be in scope when sourced):
#   heal_claim_state_ownership   from scripts/lib/claim-registration.sh
#
# This function is intentionally airplanes-feed-specific despite taking the
# user/group names as arguments: heal_claim_state_ownership defaults its
# owner to airplanes-feed and the warning message references the webconfig
# 'claim show' surface, both of which are tied to the one daemon account
# this project creates. The arg shape is for testability, not reuse.

# Create or repair the airplanes-feed system account so the daemon and any
# other service that needs the airplanes-feed group (for claim-secret read)
# end up in a consistent state. After the account is in place, heal any
# claim-state files left behind by older feed versions that wrote them as
# root:root mode 0600.
#
# Args:
#   $1  uname           — daemon user name (production: airplanes-feed)
#   $2  gname           — daemon group name (production: airplanes-feed)
#   $3  home_dir        — passwd home dir for the user (production: $IPATH)
#   $4  etc_airplanes   — directory containing claim-state files to heal
#
# Aborts (exit 1) only when group creation fails completely. User creation
# falls back through adduser → useradd → final id -u recheck before
# aborting. Supplementary-group repair on existing users is non-fatal:
# usermod → gpasswd → warning, function returns 0.
ensure_airplanes_feed_account() {
    local uname="$1"
    local gname="$2"
    local home_dir="$3"
    local etc_airplanes="$4"

    if ! getent group "$gname" >/dev/null 2>&1
    then
        # Trailing recheck handles the case where a concurrent update
        # created the group between our guard and the addgroup call.
        addgroup --system "$gname" \
            || groupadd --system "$gname" \
            || getent group "$gname" >/dev/null 2>&1 \
            || { echo "ERROR: failed to create group '$gname' (no working addgroup/groupadd)." >&2; exit 1; }
    fi

    if ! id -u "$uname" &>/dev/null
    then
        # Fresh user creation: primary group is the daemon group so
        # processes started under User=$uname pick the group up without
        # a supplementary lookup. `||` chains are set -e safe.
        adduser --system --ingroup "$gname" --home "$home_dir" --no-create-home --quiet "$uname" \
            || adduser --system --gid "$(getent group "$gname" | cut -d: -f3)" --home-dir "$home_dir" --no-create-home "$uname" \
            || useradd --system --gid "$(getent group "$gname" | cut -d: -f3)" --home-dir "$home_dir" --no-create-home "$uname" \
            || id -u "$uname" &>/dev/null \
            || { echo "ERROR: failed to create user '$uname' (no working adduser/useradd)." >&2; exit 1; }
    else
        # Existing user from a pre-pivot install: primary group is likely
        # `nogroup`. Add the daemon group as supplementary so the running
        # daemon picks it up after the post-install service restart.
        if ! id -nG "$uname" 2>/dev/null | tr ' ' '\n' | grep -qx "$gname"
        then
            usermod -aG "$gname" "$uname" 2>/dev/null \
                || gpasswd -a "$uname" "$gname" 2>/dev/null \
                || echo "WARNING: could not add $uname to $gname group; webconfig 'claim show' may stay broken until manually fixed" >&2
        fi
    fi

    # heal_claim_state_ownership runs after account setup so its chown
    # target group exists. Defaults to airplanes-feed:airplanes-feed; the
    # uname/gname args here are not threaded through because the heal
    # surface is intentionally tied to the production account.
    heal_claim_state_ownership "$etc_airplanes"
}
