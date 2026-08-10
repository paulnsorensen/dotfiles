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

@test "credential_is_private rejects non-0600 mode and non-root ownership directly" {
    local wrong_mode="$TEST_HOME/credential-wrong-mode"
    printf 'x' > "$wrong_mode"
    chmod 644 "$wrong_mode"
    run bash -c "source '$INSTALLER'; credential_is_private '$wrong_mode'"
    assert_failure
    [[ "$output" == "agent-secret-install: credential file must be root-owned mode 0600: $wrong_mode" ]]

    local right_mode_wrong_owner="$TEST_HOME/credential-right-mode-wrong-owner"
    printf 'x' > "$right_mode_wrong_owner"
    chmod 600 "$right_mode_wrong_owner"
    run bash -c "source '$INSTALLER'; credential_is_private '$right_mode_wrong_owner'"
    assert_failure
    [[ "$output" == "agent-secret-install: credential file must be root-owned mode 0600: $right_mode_wrong_owner" ]]
}

@test "credential_is_private accepts a root-owned 0600 credential" {
    [[ "$(id -u)" == 0 ]] || skip "requires chown to root; unprivileged sandboxes cannot produce a root-owned file"
    local credential="$TEST_HOME/credential-root-owned"
    printf 'x' > "$credential"
    chown 0 "$credential"
    chmod 600 "$credential"
    run bash -c "source '$INSTALLER'; credential_is_private '$credential'"
    assert_success
}

@test "trusted_executable rejects group-writable and world-writable executables directly" {
    local group_writable="$TEST_HOME/exec-group-writable"
    printf '#!/bin/sh\n' > "$group_writable"
    chmod 775 "$group_writable"
    run bash -c "source '$INSTALLER'; trusted_executable '$group_writable' upstream"
    assert_failure
    [[ "$output" == "agent-secret-install: upstream must be root-owned and not group/other-writable: $group_writable" ]]

    local world_writable="$TEST_HOME/exec-world-writable"
    printf '#!/bin/sh\n' > "$world_writable"
    chmod 757 "$world_writable"
    run bash -c "source '$INSTALLER'; trusted_executable '$world_writable' upstream"
    assert_failure
    [[ "$output" == "agent-secret-install: upstream must be root-owned and not group/other-writable: $world_writable" ]]
}

@test "trusted_executable accepts a root-owned non-group-writable executable" {
    [[ "$(id -u)" == 0 ]] || skip "requires chown to root; unprivileged sandboxes cannot produce a root-owned file"
    local executable="$TEST_HOME/exec-root-owned"
    printf '#!/bin/sh\n' > "$executable"
    chown 0 "$executable"
    chmod 755 "$executable"
    run bash -c "source '$INSTALLER'; trusted_executable '$executable' upstream"
    assert_success
}

@test "ensure_identity no-ops for a service user that already exists" {
    local platform
    if [[ "$(uname -s)" == Darwin ]]; then platform=macos; else platform=linux; fi
    run bash -c "source '$INSTALLER'; ensure_identity '$platform' '$(id -un)' '$TEST_HOME'"
    assert_success
}

@test "ensure_identity attempts real identity creation for an unknown service user" {
    [[ "$(id -u)" != 0 ]] || skip "root would perform a real system identity creation; unsafe to exercise here"
    local platform
    if [[ "$(uname -s)" == Darwin ]]; then platform=macos; else platform=linux; fi
    run bash -c "source '$INSTALLER'; ensure_identity '$platform' 'agent-secret-install-test-nonexistent' '$TEST_HOME/nonexistent-home'"
    assert_failure
    [[ -n "$output" ]]
}
