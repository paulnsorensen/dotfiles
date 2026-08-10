#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

@test "prefers /usr/bin/python3 over a PATH-resolved interpreter" {
    [[ -x /usr/bin/python3 ]] || skip "/usr/bin/python3 is required"
    run bash -c 'source "$0/bin/lib/agent-secret-python.sh"; agent_secret_python_path' "$REAL_DOTFILES_DIR"
    assert_success
    [[ "$output" == /usr/bin/python3 ]]
}

@test "falls back to PATH python3 when /usr/bin/python3 is absent" {
    [[ ! -x /usr/bin/python3 ]] || skip "/usr/bin/python3 present; fallback branch not exercised"
    local fake_root="$TEST_HOME/fake-bin"
    mkdir -p "$fake_root"
    cat > "$fake_root/python3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_root/python3"
    # shellcheck disable=SC2016  # literal $0 form for bash -c positional arg, not for expansion
    run env PATH="$fake_root:$PATH" bash -c 'source "$0/bin/lib/agent-secret-python.sh"; agent_secret_python_path' "$REAL_DOTFILES_DIR"
    assert_success
    [[ "$output" == "$fake_root/python3" ]]
}

@test "every agent-secret wrapper resolves its interpreter through the shared library, never bare python3" {
    local wrapper
    for wrapper in agent-secret-broker agent-secret-proxy agent-secretctl; do
        run grep -n 'exec python3 ' "$REAL_DOTFILES_DIR/bin/$wrapper"
        assert_failure
        run grep -q 'agent_secret_python_path' "$REAL_DOTFILES_DIR/bin/$wrapper"
        assert_success
    done
}

@test "agent-secret-install reuses the shared python resolution library" {
    # shellcheck disable=SC2016  # literal string to match in the file, not for expansion
    run grep -q 'source "$DOTFILES_DIR/bin/lib/agent-secret-python.sh"' "$REAL_DOTFILES_DIR/bin/agent-secret-install"
    assert_success
}
