#!/usr/bin/env bats
# Tests for install_tpm (.sync-lib.sh) — TPM (tmux plugin manager) bootstrap +
# idempotent plugin install. Regression coverage for the bug where an
# already-present ~/.tmux/plugins/tpm dir short-circuited install_plugins
# forever (blank status bar / dead C-hjkl nav on machines with older tpm
# clones, or plugins added to tmux.conf after the first install).

load test_helper

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export TPM_DIR="$TEST_HOME/.tmux/plugins/tpm"
    export INSTALL_CALLS="$TEST_HOME/install-plugins-calls.log"
    export CLONE_CALLS="$TEST_HOME/git-clone-calls.log"
}

teardown() { teardown_test_env; }

mock_tmux() {
    cat > "$MOCK_BIN/tmux" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$MOCK_BIN/tmux"
}

# install_plugins stub that records each invocation.
write_install_plugins_stub() {
    local dest="$1"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" <<SH
#!/bin/bash
printf 'ran\n' >> "$INSTALL_CALLS"
exit 0
SH
    chmod +x "$dest"
}

# Mocks `git clone` to record the call and materialize the target dir instead
# of hitting the network. drop_stub=true also seeds a working install_plugins
# inside the cloned dir, simulating a real tpm checkout.
mock_git() {
    local drop_stub="${1:-false}"
    write_install_plugins_stub "$MOCK_BIN/install_plugins_stub"
    cat > "$MOCK_BIN/git" <<GITEOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CLONE_CALLS"
if [[ "\$1" == "clone" ]]; then
    mkdir -p "\$3"
    if [[ "$drop_stub" == true ]]; then
        mkdir -p "\$3/bin"
        cp "$MOCK_BIN/install_plugins_stub" "\$3/bin/install_plugins"
    fi
fi
exit 0
GITEOF
    chmod +x "$MOCK_BIN/git"
}

run_install_tpm() {
    local path="${1:-$MOCK_BIN:/usr/bin:/bin}"
    PATH="$path" run /bin/bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && install_tpm"
}

@test "install_tpm no-ops when tmux is not on PATH" {
    mock_git

    # Hermetic PATH (mock bin only) so `command -v tmux` can't resolve a system
    # tmux such as /usr/bin/tmux on CI runners; install_tpm returns at the guard
    # before needing any external tool.
    run_install_tpm "$MOCK_BIN"
    assert_success
    [[ ! -f "$CLONE_CALLS" ]]
    [[ ! -d "$TPM_DIR" ]]
}

@test "install_tpm clones tpm and runs install_plugins on a fresh machine" {
    mock_tmux
    mock_git true

    run_install_tpm
    assert_success
    assert_file_exists "$CLONE_CALLS"
    grep -q '^clone ' "$CLONE_CALLS"
    assert_file_exists "$INSTALL_CALLS"
}

@test "REGRESSION: install_tpm still runs install_plugins when the tpm dir already exists" {
    mock_tmux
    write_install_plugins_stub "$TPM_DIR/bin/install_plugins"

    run_install_tpm
    assert_success
    [[ ! -f "$CLONE_CALLS" ]]
    assert_file_exists "$INSTALL_CALLS"
}

@test "install_tpm no-ops without error when tpm dir exists but install_plugins is missing" {
    mock_tmux
    mkdir -p "$TPM_DIR"

    run_install_tpm
    assert_success
    [[ ! -f "$CLONE_CALLS" ]]
    [[ ! -f "$INSTALL_CALLS" ]]
}
