#!/usr/bin/env bats
# Tests for ensure_airplanes_feed_account, defined in
# scripts/lib/service-account.sh. Stubs the user/group management tools
# (getent, addgroup, groupadd, adduser, useradd, id, usermod, gpasswd)
# via PATH manipulation so the function exercises its full
# create/repair cascade against deterministic synthetic state.
#
# heal_claim_state_ownership is sourced from claim-registration.sh and
# runs against a tmp directory containing claim-state files; the chown
# stub records the call without actually changing ownership.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/scripts/lib/service-account.sh"
    CLAIM_LIB="$REPO_ROOT/scripts/lib/claim-registration.sh"

    TMP="$(mktemp -d)"
    STUB_DIR="$TMP/bin"
    COMMAND_LOG="$TMP/commands.log"
    HOME_DIR="$TMP/home"
    ETC_AIRPLANES="$TMP/etc/airplanes"
    mkdir -p "$STUB_DIR" "$HOME_DIR" "$ETC_AIRPLANES"
    : > "$COMMAND_LOG"

    # Default stubs: every tool exists and reports success. Individual
    # tests override stubs via _stub helper to inject failures or shape
    # responses.
    _stub getent 'exit 0'
    _stub addgroup 'printf "addgroup %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub groupadd 'printf "groupadd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub adduser 'printf "adduser %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub useradd 'printf "useradd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub id 'printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub usermod 'printf "usermod %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub gpasswd 'printf "gpasswd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub chown 'printf "chown %s\n" "$*" >> "$COMMAND_LOG"; exit 0'
    _stub chmod 'printf "chmod %s\n" "$*" >> "$COMMAND_LOG"; exit 0'

    PATH="$STUB_DIR:$PATH"
    export PATH COMMAND_LOG

    # shellcheck source=/dev/null
    source "$CLAIM_LIB"
    # shellcheck source=/dev/null
    source "$LIB"
}

teardown() {
    rm -rf "$TMP"
}

_stub() {
    local name="$1"
    local body="$2"
    cat > "$STUB_DIR/$name" <<SH
#!/usr/bin/env bash
$body
SH
    chmod +x "$STUB_DIR/$name"
}

@test "fresh install: addgroup + adduser called when neither exists" {
    # getent group → fail (group missing), id -u → fail (user missing)
    _stub getent 'exit 2'
    _stub id 'printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 1'

    set -e
    ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    grep -q "^addgroup --system airplanes-feed$" "$COMMAND_LOG"
    grep -q "^adduser --system --ingroup airplanes-feed --home $HOME_DIR --no-create-home --quiet airplanes-feed$" "$COMMAND_LOG"
    # No supplementary-group repair on the fresh-create path.
    ! grep -q "^usermod " "$COMMAND_LOG"
    ! grep -q "^gpasswd " "$COMMAND_LOG"
}

@test "addgroup fallback: groupadd is called when addgroup is absent" {
    rm -f "$STUB_DIR/addgroup"
    _stub getent 'exit 2'
    _stub id 'printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 1'

    set -e
    ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    grep -q "^groupadd --system airplanes-feed$" "$COMMAND_LOG"
}

@test "group creation total failure: aborts under set -e with documented message" {
    # Neither addgroup, groupadd, nor the trailing getent recheck succeed.
    rm -f "$STUB_DIR/addgroup" "$STUB_DIR/groupadd"
    _stub getent 'exit 2'
    _stub id 'exit 1'

    set -e
    run ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to create group 'airplanes-feed'"* ]]
}

@test "existing user, missing supplementary group: usermod succeeds, no gpasswd" {
    # Group exists, user exists, but `id -nG` doesn't list the group.
    _stub getent 'exit 0'
    _stub id '
case "$1" in
    -u) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
    -nG) printf "id %s\n" "$*" >> "$COMMAND_LOG"; echo "nogroup"; exit 0;;
    *) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
esac'

    set -e
    ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    grep -q "^usermod -aG airplanes-feed airplanes-feed$" "$COMMAND_LOG"
    ! grep -q "^gpasswd " "$COMMAND_LOG"
    # No fresh-user creation paths fired.
    ! grep -q "^adduser " "$COMMAND_LOG"
    ! grep -q "^useradd " "$COMMAND_LOG"
}

@test "existing user, usermod fails, gpasswd succeeds: both called in order, no warning" {
    _stub getent 'exit 0'
    _stub id '
case "$1" in
    -u) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
    -nG) printf "id %s\n" "$*" >> "$COMMAND_LOG"; echo "nogroup"; exit 0;;
    *) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
esac'
    _stub usermod 'printf "usermod %s\n" "$*" >> "$COMMAND_LOG"; exit 1'
    _stub gpasswd 'printf "gpasswd %s\n" "$*" >> "$COMMAND_LOG"; exit 0'

    set -e
    run ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING:"* ]]
    grep -q "^usermod -aG airplanes-feed airplanes-feed$" "$COMMAND_LOG"
    grep -q "^gpasswd -a airplanes-feed airplanes-feed$" "$COMMAND_LOG"
    # Ordering: usermod before gpasswd.
    [ "$(grep -n '^usermod\|^gpasswd' "$COMMAND_LOG" | head -1 | cut -d: -f2-)" = "usermod -aG airplanes-feed airplanes-feed" ]
}

@test "existing user, both usermod AND gpasswd fail: warning printed, function returns 0" {
    _stub getent 'exit 0'
    _stub id '
case "$1" in
    -u) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
    -nG) printf "id %s\n" "$*" >> "$COMMAND_LOG"; echo "nogroup"; exit 0;;
    *) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
esac'
    _stub usermod 'printf "usermod %s\n" "$*" >> "$COMMAND_LOG"; exit 1'
    _stub gpasswd 'printf "gpasswd %s\n" "$*" >> "$COMMAND_LOG"; exit 1'

    set -e
    run ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: could not add airplanes-feed to airplanes-feed group"* ]]
}

@test "existing user, group already supplementary: no usermod or gpasswd call" {
    _stub getent 'exit 0'
    _stub id '
case "$1" in
    -u) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
    -nG) printf "id %s\n" "$*" >> "$COMMAND_LOG"; echo "nogroup airplanes-feed"; exit 0;;
    *) printf "id %s\n" "$*" >> "$COMMAND_LOG"; exit 0;;
esac'

    set -e
    ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    ! grep -q "^usermod " "$COMMAND_LOG"
    ! grep -q "^gpasswd " "$COMMAND_LOG"
}

@test "heal_claim_state_ownership runs after account setup" {
    # Override heal so it appends a marker to COMMAND_LOG and skips the
    # real chown logic. The marker's position in the log relative to
    # adduser/usermod proves call ordering.
    _stub getent 'exit 2'
    _stub id 'exit 1'
    heal_claim_state_ownership() {
        printf "heal %s\n" "$*" >> "$COMMAND_LOG"
    }

    set -e
    ensure_airplanes_feed_account airplanes-feed airplanes-feed "$HOME_DIR" "$ETC_AIRPLANES"

    # Heal entry exists and comes after the adduser entry.
    local heal_line adduser_line
    heal_line="$(grep -n '^heal ' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
    adduser_line="$(grep -n '^adduser ' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
    [ -n "$heal_line" ]
    [ -n "$adduser_line" ]
    [ "$heal_line" -gt "$adduser_line" ]
    grep -q "^heal $ETC_AIRPLANES$" "$COMMAND_LOG"
}
