#!/usr/bin/env bats
# tmux.conf picks zsh for new panes when the login shell is bash (cloud
# devbox images reset the login shell to bash on every boot). Each test runs
# the real tmux.conf on a private server socket.

load test_helper

setup() {
    command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
    [[ -x /bin/zsh ]] || skip "/bin/zsh not present"
    setup_test_env
    SOCK="$TEST_HOME/tmux.sock"
}

teardown() {
    tmux -S "$SOCK" kill-server 2>/dev/null || true
    teardown_test_env
}

# Start a detached server under the given login shell, print default-shell.
default_shell_under() {
    env -u TMUX HOME="$TEST_HOME" SHELL="$1" \
        tmux -S "$SOCK" -f "$REAL_DOTFILES_DIR/tmux.conf" new-session -d 'sleep 30'
    tmux -S "$SOCK" show -gv default-shell
}

@test "tmux.conf: a bash login shell gets zsh panes" {
    run default_shell_under /bin/bash
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = /bin/zsh ]
}

@test "tmux.conf: a zsh login shell keeps its own zsh path" {
    local zsh_path
    zsh_path=$(command -v zsh)
    run default_shell_under "$zsh_path"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "$zsh_path" ]
}
