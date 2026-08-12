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
        grep -q '<string>--ensure-socket-parent</string>' "$plist"
    else
        unit="$INSTALL_ROOT/etc/systemd/system/dotfiles-agent-secret@.service"
        exec_start="$(grep '^ExecStart=' "$unit")"
        [[ "$exec_start" == *'--policy /etc/dotfiles/agent-secret-broker/%i.json'* ]]
        [[ "$exec_start" == *'--socket /var/run/dotfiles-agent-secrets/%i.sock --control-socket /var/run/dotfiles-agent-secrets/%i.control.sock'* ]]
        [[ "$exec_start" == *'--run-user agent-secret-%i --upstream-home /var/lib/dotfiles-agent-secrets/%i'* ]]
        [[ "$(grep '^CapabilityBoundingSet=' "$unit")" == 'CapabilityBoundingSet=CAP_CHOWN CAP_SETGID CAP_SETUID' ]]
    fi
    run grep -R -q 'installer-secret-sentinel' "$INSTALL_ROOT"
    [[ "$status" -ne 0 ]]
}

@test "installer renders a write-only policy with an empty read-tool array" {
    run env DESTDIR="$INSTALL_ROOT" "$INSTALLER" install write-only \
        --credential-env FIXTURE_SECRET \
        --credential-file "$CREDENTIAL" \
        --request-user "$REQUEST_USER" \
        --operator-user "$OPERATOR_USER" \
        --write-tool write.item \
        -- /usr/bin/context7-mcp --stdio
    assert_success
    [[ -z "$output" ]]

    jq -e '.tools.read == []
        and .tools.write == ["write.item"]
        and .upstream.argv == ["/usr/bin/context7-mcp", "--stdio"]' \
        "$INSTALL_ROOT/etc/dotfiles/agent-secret-broker/write-only.json" >/dev/null
}

@test "installer leaves an existing LaunchDaemons directory unchanged" {
    local fake_bin="$TEST_HOME/fake-bin"
    local launch_daemons="$INSTALL_ROOT/Library/LaunchDaemons"
    local real_install
    real_install="$(command -v install)"
    mkdir -p "$fake_bin" "$launch_daemons"

    cat > "$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
    cat > "$fake_bin/install" <<'EOF'
#!/usr/bin/env bash
target=""
for target; do :; done
if [[ "${1:-}" == -d && -d "$target" ]]; then
    printf 'install: chmod 755 %s: Operation not permitted\n' "$target" >&2
    exit 1
fi
exec "$REAL_INSTALL" "$@"
EOF
    chmod +x "$fake_bin/uname" "$fake_bin/install"

    run env \
        PATH="$fake_bin:$PATH" \
        REAL_INSTALL="$real_install" \
        DESTDIR="$INSTALL_ROOT" \
        "$INSTALLER" install launchd-existing \
        --credential-env FIXTURE_SECRET \
        --credential-file "$CREDENTIAL" \
        --request-user "$REQUEST_USER" \
        --operator-user "$OPERATOR_USER" \
        --read-tool read.item \
        -- /usr/bin/context7-mcp
    assert_success
    [[ -z "$output" ]]
    [ -f "$launch_daemons/com.dotfiles.agent-secret.launchd-existing.plist" ]
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

run_installer_helper() {
    local helper="$1" stub_owner="${STUB_STAT_OWNER:-}" stub_mode="${STUB_STAT_MODE:-}"
    shift
    # shellcheck disable=SC2016  # expansions belong to the isolated child shell
    env -u DESTDIR PATH="${INSTALLER_HELPER_PATH:-$PATH}" bash -c '
        source "$1"
        helper="$2"
        stub_owner="$3"
        stub_mode="$4"
        shift 4
        if [[ -n "$stub_owner" ]]; then
            stat() {
                case "$2" in
                    "%u") printf "%s\n" "$stub_owner" ;;
                    "%a"|"%Lp") printf "%s\n" "$stub_mode" ;;
                    *) return 64 ;;
                esac
            }
        fi
        "$helper" "$@"
    ' _ "$INSTALLER" "$helper" "$stub_owner" "$stub_mode" "$@"
}

@test "credential_is_private validates ownership and mode independently" {
    local credential="$TEST_HOME/credential"
    printf 'x' > "$credential"
    chmod 600 "$credential"

    STUB_STAT_OWNER=0 STUB_STAT_MODE=644 run run_installer_helper credential_is_private "$credential"
    assert_failure
    [[ "$output" == "agent-secret-install: credential file must be root-owned mode 0600: $credential" ]]

    STUB_STAT_OWNER=1 STUB_STAT_MODE=600 run run_installer_helper credential_is_private "$credential"
    assert_failure
    [[ "$output" == "agent-secret-install: credential file must be root-owned mode 0600: $credential" ]]
}

@test "credential_is_private accepts root ownership with mode 0600" {
    local credential="$TEST_HOME/credential"
    printf 'x' > "$credential"
    chmod 600 "$credential"
    STUB_STAT_OWNER=0 STUB_STAT_MODE=600 run run_installer_helper credential_is_private "$credential"
    assert_success
    [[ -z "$output" ]]
}

@test "trusted_executable validates writable mode bits independently" {
    local executable="$TEST_HOME/upstream"
    printf '#!/bin/sh\n' > "$executable"
    chmod 755 "$executable"

    STUB_STAT_OWNER=0 STUB_STAT_MODE=775 run run_installer_helper trusted_executable "$executable" upstream
    assert_failure
    [[ "$output" == "agent-secret-install: upstream must be root-owned and not group/other-writable: $executable" ]]

    STUB_STAT_OWNER=0 STUB_STAT_MODE=757 run run_installer_helper trusted_executable "$executable" upstream
    assert_failure
    [[ "$output" == "agent-secret-install: upstream must be root-owned and not group/other-writable: $executable" ]]
}

@test "trusted_executable accepts root ownership without writable group or other bits" {
    local executable="$TEST_HOME/upstream"
    printf '#!/bin/sh\n' > "$executable"
    chmod 755 "$executable"
    STUB_STAT_OWNER=0 STUB_STAT_MODE=755 run run_installer_helper trusted_executable "$executable" upstream
    assert_success
    [[ -z "$output" ]]
}

@test "ensure_identity no-ops for a service user that already exists" {
    local platform
    if [[ "$(uname -s)" == Darwin ]]; then platform=macos; else platform=linux; fi
    run run_installer_helper ensure_identity "$platform" "$(id -un)" "$TEST_HOME"
    assert_success
    [[ -z "$output" ]]
}

@test "ensure_identity dispatches an unknown user to the platform identity creator" {
    local fake_bin="$TEST_HOME/fake-bin"
    local platform service_user=agent-secret-install-test-nonexistent
    local home="$TEST_HOME/nonexistent-home" expected
    mkdir -p "$fake_bin"

    if [[ "$(uname -s)" == Darwin ]]; then
        platform=macos
        cat > "$fake_bin/dscl" <<'EOF'
#!/usr/bin/env bash
printf 'dscl:%s\n' "$*"
case "$2" in
    -read|-search) exit 1 ;;
esac
exit 23
EOF
        expected="dscl:. -create /Groups/$service_user"
    else
        platform=linux
        cat > "$fake_bin/getent" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
        cat > "$fake_bin/useradd" <<'EOF'
#!/usr/bin/env bash
printf 'useradd:%s\n' "$*"
exit 23
EOF
        expected="useradd:--system --user-group --home-dir $home --shell /usr/sbin/nologin $service_user"
    fi
    chmod +x "$fake_bin"/*

    INSTALLER_HELPER_PATH="$fake_bin:$PATH" run \
        run_installer_helper ensure_identity "$platform" "$service_user" "$home"
    [ "$status" -eq 23 ]
    [[ "$output" == "$expected" ]]
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

@test "the shared systemd template never bakes in one consumer's paths" {
    [[ "$(uname -s)" == Linux ]] || skip "the systemd template is Linux-only"
    run install_fixture
    assert_success
    run env DESTDIR="$INSTALL_ROOT" "$INSTALLER" install second \
        --credential-env SECOND_SECRET \
        --credential-file "$CREDENTIAL" \
        --request-user "$REQUEST_USER" \
        --operator-user "$OPERATOR_USER" \
        --read-tool read.item \
        -- /usr/bin/tavily-mcp --stdio
    assert_success

    # Both consumers get their own policy, but a single unit file backs every
    # instance. Installing the second must not repoint the first at it.
    [[ -f "$INSTALL_ROOT/etc/dotfiles/agent-secret-broker/fixture.json" ]]
    [[ -f "$INSTALL_ROOT/etc/dotfiles/agent-secret-broker/second.json" ]]

    unit="$INSTALL_ROOT/etc/systemd/system/dotfiles-agent-secret@.service"
    run grep -nE 'fixture|second' "$unit"
    [[ "$status" -ne 0 ]]
    # The sandbox paths must be instance-generic too, or every instance would be
    # confined to the last-installed consumer's policy and state directory.
    [[ "$(grep '^ReadOnlyPaths=' "$unit")" == 'ReadOnlyPaths=/etc/dotfiles/agent-secret-broker/%i.json' ]]
    [[ "$(grep '^ReadWritePaths=' "$unit")" == 'ReadWritePaths=/var/run/dotfiles-agent-secrets /var/lib/dotfiles-agent-secrets/%i' ]]
}


@test "launchd restart waits for bootout and retries bootstrap" {
    local fake_bin="$TEST_HOME/fake-bin" log="$TEST_HOME/launchctl.log" state="$TEST_HOME/launchctl.state"
    mkdir -p "$fake_bin"
    printf loaded > "$state"
    cat > "$fake_bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
case "$1" in
    print)
        if [[ -s "$LAUNCHCTL_STATE" ]]; then
            if [[ "$(cat "$LAUNCHCTL_STATE")" == pending ]]; then
                : > "$LAUNCHCTL_STATE"
            fi
            exit 0
        fi
        exit 1
        ;;
    bootout) printf pending > "$LAUNCHCTL_STATE" ;;
    bootstrap)
        attempt="$(cat "$LAUNCHCTL_BOOTSTRAPS" 2>/dev/null || printf 0)"
        attempt=$((attempt + 1))
        printf '%s\n' "$attempt" > "$LAUNCHCTL_BOOTSTRAPS"
        (( attempt >= 2 )) || exit 5
        ;;
esac
EOF
    chmod +x "$fake_bin/launchctl"
    # shellcheck disable=SC2016
    run env PATH="$fake_bin:$PATH" LAUNCHCTL_LOG="$log" LAUNCHCTL_STATE="$state" \
        LAUNCHCTL_BOOTSTRAPS="$TEST_HOME/bootstraps" bash -c \
        'source <(sed -n "/^restart_launchd_service()/,/^}/p" "$1"); restart_launchd_service fixture /tmp/fixture.plist' _ "$INSTALLER"
    assert_success
    [[ "$(grep -c '^bootout' "$log")" -eq 1 ]]
    [[ "$(grep -c '^bootstrap' "$log")" -eq 2 ]]

    : > "$log"
    : > "$state"
    rm -f "$TEST_HOME/bootstraps"
    # shellcheck disable=SC2016
    run env PATH="$fake_bin:$PATH" LAUNCHCTL_LOG="$log" LAUNCHCTL_STATE="$state" \
        LAUNCHCTL_BOOTSTRAPS="$TEST_HOME/bootstraps" bash -c \
        'source <(sed -n "/^restart_launchd_service()/,/^}/p" "$1"); restart_launchd_service fixture /tmp/fixture.plist' _ "$INSTALLER"
    assert_success
    [[ "$(grep -c '^bootstrap' "$log")" -eq 2 ]]
    run grep -q '^bootout' "$log"
    [ "$status" -ne 0 ]
}
