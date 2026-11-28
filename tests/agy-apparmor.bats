#!/usr/bin/env bats
# Tests for bin/lib/agy-apparmor.sh. A fake privilege command and a mock
# apparmor_parser keep the tests away from /etc and the kernel.

load test_helper

setup() {
    setup_test_env
    export MISE_DATA_DIR="$TEST_HOME/mise"
    export AGY_APPARMOR_DIR="$TEST_HOME/apparmor.d"
    export AGY_APPARMOR_SYSCTL="$TEST_HOME/restrict_userns"
    export AGY_APPARMOR_SUDO=""
    export PARSER_LOG="$TEST_HOME/parser.log"
    MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN" "$AGY_APPARMOR_DIR"
    REAL_PARSER=$(command -v apparmor_parser || true)
    cat > "$MOCK_BIN/apparmor_parser" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$PARSER_LOG"
exit "${PARSER_EXIT:-0}"
MOCK
    chmod +x "$MOCK_BIN/apparmor_parser"
    export PATH="$MOCK_BIN:$PATH"
    echo 1 > "$AGY_APPARMOR_SYSCTL"
    # shellcheck source=bin/lib/agy-apparmor.sh
    source "$REAL_DOTFILES_DIR/bin/lib/agy-apparmor.sh"
}

teardown() { teardown_test_env; }

@test "render names every mise-installed agy binary and parses" {
    run agy_apparmor_render
    assert_success
    assert_output_contains "profile antigravity $TEST_HOME/mise/installs/aqua-google-antigravity-antigravity-cli/*/antigravity flags=(unconfined)"
    assert_output_contains "userns,"
    assert_output_not_contains "__AGY_BINARY_GLOB__"
    [[ -n "$REAL_PARSER" ]] || skip "apparmor_parser not installed"
    printf '%s\n' "$output" > "$TEST_HOME/antigravity"
    run "$REAL_PARSER" -QK "$TEST_HOME/antigravity"
    assert_success
}

@test "render refuses a binary path that could break the profile" {
    export MISE_DATA_DIR="$TEST_HOME/my mise"
    run agy_apparmor_render
    assert_failure
    assert_output_contains "unsafe binary path"
}

@test "render refuses a binary path outside the home directory" {
    export MISE_DATA_DIR="/tmp/mise"
    run agy_apparmor_render
    assert_failure
    assert_output_contains "unsafe binary path"
}

@test "render refuses every glob when HOME is empty" {
    export HOME=""
    export MISE_DATA_DIR="/tmp/mise"
    run agy_apparmor_render
    assert_failure
    assert_output_contains "unsafe binary path"
}

@test "render refuses a binary path that climbs out of the home directory" {
    export MISE_DATA_DIR="$HOME/../tmp/m"
    run agy_apparmor_render
    assert_failure
    assert_output_contains "unsafe binary path"
}

@test "install skips when the kernel does not restrict user namespaces" {
    echo 0 > "$AGY_APPARMOR_SYSCTL"
    run agy_apparmor_install
    assert_success
    assert_output_contains "no profile needed"
    [ ! -e "$AGY_APPARMOR_DIR/antigravity" ]
    [ ! -e "$PARSER_LOG" ]
}

@test "install writes and loads the profile when namespaces are restricted" {
    export AGY_APPARMOR_SUDO="$MOCK_BIN/fake-sudo"
    printf '#!/bin/bash\necho sudo >> "%s"\nexec "$@"\n' "$TEST_HOME/sudo.log" > "$AGY_APPARMOR_SUDO"
    chmod +x "$AGY_APPARMOR_SUDO"
    run agy_apparmor_install
    assert_success
    [ "$(cat "$AGY_APPARMOR_DIR/antigravity")" = "$(agy_apparmor_render)" ]
    [ "$(cat "$PARSER_LOG")" = "-r $AGY_APPARMOR_DIR/antigravity" ]
    [ "$(grep -c sudo "$TEST_HOME/sudo.log")" -eq 2 ]
}

@test "install keeps a current profile file and still loads it" {
    agy_apparmor_render > "$AGY_APPARMOR_DIR/antigravity"
    run agy_apparmor_install
    assert_success
    assert_output_contains "is current"
    [ "$(cat "$PARSER_LOG")" = "-r $AGY_APPARMOR_DIR/antigravity" ]
}

@test "install retries the parser after a failed load left the file in place" {
    PARSER_EXIT=1 run agy_apparmor_install
    assert_failure
    [ "$(wc -l < "$PARSER_LOG")" -eq 1 ]
    run agy_apparmor_install
    assert_success
    assert_output_contains "loaded"
    [ "$(wc -l < "$PARSER_LOG")" -eq 2 ]
}

@test "install fails when the current profile file does not load" {
    agy_apparmor_render > "$AGY_APPARMOR_DIR/antigravity"
    PARSER_EXIT=1 run agy_apparmor_install
    assert_failure
    assert_output_contains "could not install or load"
}

@test "install fails when apparmor_parser rejects the profile" {
    export PARSER_EXIT=1
    run agy_apparmor_install
    assert_failure
    assert_output_contains "could not install or load"
}
