#!/bin/bash
# Helpers for inspecting systemd unit state. Sourced by update.sh; the
# function bodies are kept small so they can be unit-tested against a
# stubbed `systemctl` (see test/test_systemd_helpers.bats).

# is_unit_masked UNIT_NAME — return 0 if the unit is currently masked
# (i.e. systemctl is-enabled prints "masked"), non-zero otherwise.
is_unit_masked() {
    [[ "$(systemctl is-enabled "$1" 2>/dev/null)" == "masked" ]]
}
