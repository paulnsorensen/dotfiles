#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export INSTALLER="$REAL_DOTFILES_DIR/bin/agent-secret-install"
    export INSTALL_ROOT="$TEST_HOME/root"
    export CREDENTIAL="$TEST_HOME/credential"
    printf '%s\n' 'installer-secret-sentinel' > "$CREDENTIAL"
    chmod 600 "$CREDENTIAL"
    REQUEST_USER="$(id -un)"
    export REQUEST_USER
    if [[ "$(id -u)" != "$(id -u root)" ]]; then
        export OPERATOR_USER=root
    elif id nobody >/dev/null 2>&1; then
        export OPERATOR_USER=nobody
    else
        skip "a distinct operator identity is required"
    fi
}

install_fixture() {
    DESTDIR="$INSTALL_ROOT" "$INSTALLER" install fixture \
        --credential-env FIXTURE_SECRET \
        --credential-file "$CREDENTIAL" \
        --request-user "$REQUEST_USER" \
        --operator-user "$OPERATOR_USER" \
        --read-tool read.item \
        --write-tool write.item \
        -- /usr/bin/context7-mcp --stdio
}

@test "installer renders exact policy and privilege-dropping system service idempotently" {
    run install_fixture
    assert_success
    [[ -z "$output" ]]

    run install_fixture
    assert_success
    [[ -z "$output" ]]

    policy="$INSTALL_ROOT/etc/dotfiles/agent-secret-broker/fixture.json"
    run python3 - "$policy" "$CREDENTIAL" "$(id -u "$REQUEST_USER")" "$(id -u "$OPERATOR_USER")" <<'PY'
import json
import sys

path, credential_file, request_uid, operator_uid = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    policy = json.load(handle)
expected = {
    "consumer": "fixture",
    "request_uid": int(request_uid),
    "operator_uid": int(operator_uid),
    "upstream": {
        "argv": ["/usr/bin/context7-mcp", "--stdio"],
        "credential_env": "FIXTURE_SECRET",
        "credential_file": credential_file,
    },
    "tools": {"read": ["read.item"], "write": ["write.item"]},
}
assert policy == expected, (policy, expected)
PY
    assert_success
    if [[ "$(uname -s)" == Darwin ]]; then
        home_abs="/var/db/dotfiles-agent-secrets/fixture"
    else
        home_abs="/var/lib/dotfiles-agent-secrets/fixture"
    fi
    home="$INSTALL_ROOT$home_abs"
    [[ "$(stat -c '%a' "$policy" 2>/dev/null || stat -f '%Lp' "$policy")" == 600 ]]
    [[ "$(stat -c '%a' "$INSTALL_ROOT/var/run/dotfiles-agent-secrets" 2>/dev/null || stat -f '%Lp' "$INSTALL_ROOT/var/run/dotfiles-agent-secrets")" == 755 ]]
    [[ "$(stat -c '%a' "$home" 2>/dev/null || stat -f '%Lp' "$home")" == 700 ]]
    if [[ "$(uname -s)" == Darwin ]]; then
        plist="$INSTALL_ROOT/Library/LaunchDaemons/com.dotfiles.agent-secret.fixture.plist"
        plist_value() {
            grep -A1 "<string>$1</string>" "$plist" | tail -n1 | sed -e 's/^[[:space:]]*<string>//' -e 's|</string>$||'
        }
        [[ "$(plist_value --run-user)" == 'agent-secret-fixture' ]]
        [[ "$(plist_value --upstream-home)" == "$home_abs" ]]
        [[ "$(plist_value --socket)" == '/var/run/dotfiles-agent-secrets/fixture.sock' ]]
        [[ "$(plist_value --control-socket)" == '/var/run/dotfiles-agent-secrets/fixture.control.sock' ]]
    else
        unit="$INSTALL_ROOT/etc/systemd/system/dotfiles-agent-secret@.service"
        [[ "$(grep '^ExecStart=' "$unit")" == *'--run-user agent-secret-fixture --upstream-home /var/lib/dotfiles-agent-secrets/fixture'* ]]
        [[ "$(grep '^ExecStart=' "$unit")" == *'--socket /var/run/dotfiles-agent-secrets/fixture.sock --control-socket /var/run/dotfiles-agent-secrets/fixture.control.sock'* ]]
        [[ "$(grep '^CapabilityBoundingSet=' "$unit")" == 'CapabilityBoundingSet=CAP_CHOWN CAP_SETGID CAP_SETUID' ]]
    fi
    run grep -R -q 'installer-secret-sentinel' "$INSTALL_ROOT"
    [[ "$status" -ne 0 ]]
}

@test "installer rejects empty policy, shared identities, and unsafe credentials" {
    run env DESTDIR="$INSTALL_ROOT" "$INSTALLER" install fixture \
        --credential-env FIXTURE_SECRET \
        --credential-file "$CREDENTIAL" \
        --request-user "$REQUEST_USER" \
        --operator-user "$OPERATOR_USER" \
        -- /usr/bin/context7-mcp
    assert_failure
    [[ "$output" == 'agent-secret-install: at least one tool must be allowed' ]]

    run env DESTDIR="$INSTALL_ROOT" "$INSTALLER" install fixture \
        --credential-env FIXTURE_SECRET \
        --credential-file "$CREDENTIAL" \
        --request-user "$REQUEST_USER" \
        --operator-user "$REQUEST_USER" \
        --read-tool read.item \
        -- /usr/bin/context7-mcp
    assert_failure
    [[ "$output" == 'agent-secret-install: request and operator users must be distinct' ]]
    credential_link="$TEST_HOME/credential-link"
    ln -s "$CREDENTIAL" "$credential_link"
    run env DESTDIR="$INSTALL_ROOT" "$INSTALLER" install fixture \
        --credential-env FIXTURE_SECRET \
        --credential-file "$credential_link" \
        --request-user "$REQUEST_USER" \
        --operator-user "$OPERATOR_USER" \
        --read-tool read.item \
        -- /usr/bin/context7-mcp
    assert_failure
    [[ "$output" == *'credential file must be a regular non-symlink'* ]]
}

@test "remove stops exposing the consumer but preserves credentials and shared runtime" {
    run install_fixture
    assert_success
    [[ -z "$output" ]]

    run env DESTDIR="$INSTALL_ROOT" "$INSTALLER" remove fixture
    assert_success
    [[ -z "$output" ]]
    [[ ! -e "$INSTALL_ROOT/etc/dotfiles/agent-secret-broker/fixture.json" ]]
    [[ -e "$CREDENTIAL" ]]
    if [[ "$(uname -s)" == Darwin ]]; then
        [[ ! -e "$INSTALL_ROOT/Library/LaunchDaemons/com.dotfiles.agent-secret.fixture.plist" ]]
    else
        [[ -e "$INSTALL_ROOT/etc/systemd/system/dotfiles-agent-secret@.service" ]]
    fi
    [[ -x "$INSTALL_ROOT/usr/local/libexec/dotfiles/agent-secret-broker.py" ]]
}

@test "installer ignores an inherited DOTFILES_DIR and uses its own sibling files" {
    export DECOY_DOTFILES="$TEST_HOME/decoy-dotfiles"
    mkdir -p "$DECOY_DOTFILES/bin"
    run env DOTFILES_DIR="$DECOY_DOTFILES" DESTDIR="$INSTALL_ROOT" "$INSTALLER" install fixture \
        --credential-env FIXTURE_SECRET \
        --credential-file "$CREDENTIAL" \
        --request-user "$REQUEST_USER" \
        --operator-user "$OPERATOR_USER" \
        --read-tool read.item \
        --write-tool write.item \
        -- /usr/bin/context7-mcp --stdio
    assert_success
    [[ -z "$output" ]]
    [[ -x "$INSTALL_ROOT/usr/local/libexec/dotfiles/agent-secret-broker.py" ]]
}

run_trusted_executable() {
    bash -c 'die() { echo "$@" >&2; exit 1; }
        eval "$(sed -n "/^trusted_executable/,/^}/p" "$1")"
        DESTDIR= trusted_executable "$2" "python interpreter"' _ "$INSTALLER" "$1"
}

@test "trusted_executable accepts a symlink to a root-owned interpreter" {
    ln -s /bin/sh "$TEST_HOME/python3"
    run run_trusted_executable "$TEST_HOME/python3"
    assert_success
}

@test "trusted_executable still rejects a symlink to a user-owned executable" {
    printf '#!/bin/sh\n' > "$TEST_HOME/user-owned"
    chmod 755 "$TEST_HOME/user-owned"
    ln -s "$TEST_HOME/user-owned" "$TEST_HOME/python3"
    run run_trusted_executable "$TEST_HOME/python3"
    assert_failure
    [[ "$output" == *"root-owned and not group/other-writable"* ]]
}
