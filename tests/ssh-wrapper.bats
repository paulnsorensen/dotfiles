#!/usr/bin/env bats
# Tests for the `ssh` wrapper in zsh/ssh.zsh. A remote TUI that dies with the
# connection leaves mouse tracking and focus reporting on in the local
# terminal. The wrapper turns those modes off after ssh exits and keeps the
# ssh exit code. A mock `ssh` on $PATH stands in for the real client.

load test_helper

SSH_ZSH="$REAL_DOTFILES_DIR/zsh/ssh.zsh"
RESET=$'\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1004l'

setup() {
    command -v zsh &>/dev/null || skip "zsh not installed"
    MOCK_BIN="$(mktemp -d)"
    cat > "$MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'mock-ssh:%s\n' "$*"
exit "${MOCK_SSH_RC:-0}"
EOF
    chmod +x "$MOCK_BIN/ssh"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    [[ -n "${MOCK_BIN:-}" ]] && rm -rf "$MOCK_BIN"
}

# Run the wrapper with stdout on a pseudo-terminal; the transcript lands in $output.
_run_on_pty() {
    local cmd="source '$SSH_ZSH'; ssh edge uptime"
    if script -qec true /dev/null >/dev/null 2>&1; then
        run script -qec "zsh -fc \"$cmd\"" /dev/null
    else
        run script -q /dev/null zsh -fc "$cmd"
    fi
}

@test "zshrc sources ssh.zsh" {
    # shellcheck disable=SC2016 # match the literal $DOTFILES_DIR text in zshrc
    grep -qF 'source "$DOTFILES_DIR/zsh/ssh.zsh"' "$REAL_DOTFILES_DIR/zshrc"
}

@test "ssh passes arguments through and returns success" {
    run zsh -fc "source '$SSH_ZSH'; ssh -p 2222 edge uptime"

    assert_success
    [[ "$output" == "mock-ssh:-p 2222 edge uptime" ]]
}

@test "ssh returns the ssh exit code on failure" {
    MOCK_SSH_RC=255 run zsh -fc "source '$SSH_ZSH'; ssh edge"

    [[ "$status" -eq 255 ]]
}

@test "ssh writes no reset sequence when stdout is not a terminal" {
    run zsh -fc "source '$SSH_ZSH'; ssh edge uptime"

    assert_success
    [[ "$output" != *$'\e['* ]]
}

@test "ssh resets mouse and focus modes after exit on a terminal" {
    _run_on_pty

    assert_success
    [[ "$output" == *"mock-ssh:edge uptime"*"$RESET"* ]]
}

@test "ssh resets modes and keeps the exit code when ssh fails on a terminal" {
    export MOCK_SSH_RC=3
    _run_on_pty

    [[ "$status" -eq 3 ]]
    [[ "$output" == *"$RESET"* ]]
}
