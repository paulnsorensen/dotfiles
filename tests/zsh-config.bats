#!/usr/bin/env bats
# Tests for simplified zsh configuration architecture

load test_helper

setup() {
    setup_test_env
    # Copy zsh files to test home
    mkdir -p "$TEST_HOME/Dev/dotfiles/zsh"
    cp "$REAL_DOTFILES_DIR/zsh"/*.zsh "$TEST_HOME/Dev/dotfiles/zsh/" 2>/dev/null || true
    cp "$REAL_DOTFILES_DIR/zshrc" "$TEST_HOME/.zshrc"
}

teardown() {
    teardown_test_env
}

@test "simplified zsh architecture has correct files" {
    # Core files should exist
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/core.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/aliases.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/completion.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/prompt.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/fzf.zsh"

    # Old over-engineered files should be gone
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/environment.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/git.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/navigation.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/misc.zsh" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/updates.zsh" ]]
    [[ ! -d "$REAL_DOTFILES_DIR/zsh/cache" ]]
}

@test "core.zsh contains essential settings" {
    local core_file="$REAL_DOTFILES_DIR/zsh/core.zsh"

    # Should have DEV_DIR export
    grep -q "export DEV_DIR" "$core_file"

    # Should have history configuration
    grep -q "HISTFILE" "$core_file"
    grep -q "HISTSIZE" "$core_file"
    grep -q "SAVEHIST" "$core_file"

    # Should have editor configuration
    grep -q "export EDITOR" "$core_file"

    # Should have vi mode setup
    grep -q "setopt VI" "$core_file"
    grep -q "KEYTIMEOUT" "$core_file"
}

@test "aliases.zsh contains consolidated aliases" {
    local aliases_file="$REAL_DOTFILES_DIR/zsh/aliases.zsh"

    # Should have git aliases
    grep -q "alias ga=" "$aliases_file"
    grep -q "alias gst=" "$aliases_file"

    # Should have cdd function
    grep -q "cdd()" "$aliases_file"

    # Should have ripgrep aliases
    grep -q "alias todos=" "$aliases_file"
    grep -q "alias rga=" "$aliases_file"

    # Should have utility aliases
    grep -q "alias uuidg=" "$aliases_file"
    grep -q "alias zrl=" "$aliases_file"
}

@test "codex profile shortcuts launch tight profiles" {
    local claude_file="$REAL_DOTFILES_DIR/zsh/claude.zsh"

    grep -Fxq 'cxp() { dots profile launch codex codex-plan "$@"; }' "$claude_file"
    grep -Fxq 'cxc() { dots profile launch codex codex-code "$@"; }' "$claude_file"
}

@test "codex profile shortcuts pass through arguments" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -c "dots() { print -r -- \"\$*\"; }; source '$REAL_DOTFILES_DIR/zsh/claude.zsh'; cxp --sandbox workspace; cxc --model gpt-5"

    assert_success
    [[ "$output" == $'profile launch codex codex-plan --sandbox workspace\nprofile launch codex codex-code --model gpt-5' ]]
}

@test "omp wrapper appends the default-profile system prompt" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fakebin="$TEST_HOME/bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/omp" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
SH
    chmod +x "$fakebin/omp"
    # The wrapper only passes --append-system-prompt when the addendum exists.
    mkdir -p "$TEST_HOME/.omp/agent"
    printf 'addendum\n' > "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md"

    run zsh -c "PATH='$fakebin':\$PATH; HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; omp --model gpt-5"

    assert_success
    [ "${lines[0]}" = "--append-system-prompt" ]
    [ "${lines[1]}" = "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md" ]
    [ "${lines[2]}" = "--model" ]
    [ "${lines[3]}" = "gpt-5" ]
}

@test "ompt wrapper appends the tight-profile system prompt, not the default" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fakebin="$TEST_HOME/bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/omp" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
SH
    chmod +x "$fakebin/omp"
    # Both addenda exist; the derivation must pick the PI_CONFIG_DIR one.
    mkdir -p "$TEST_HOME/.omp/agent" "$TEST_HOME/.omp-tight/agent"
    printf 'default\n' > "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md"
    printf 'tight\n'   > "$TEST_HOME/.omp-tight/agent/APPEND_SYSTEM.md"

    run zsh -c "PATH='$fakebin':\$PATH; HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; ompt --model gpt-5"

    assert_success
    [ "${lines[0]}" = "--append-system-prompt" ]
    # Derives from PI_CONFIG_DIR=.omp-tight — NOT the default .omp path.
    [ "${lines[1]}" = "$TEST_HOME/.omp-tight/agent/APPEND_SYSTEM.md" ]
    [ "${lines[1]}" != "$TEST_HOME/.omp/agent/APPEND_SYSTEM.md" ]
    [ "${lines[2]}" = "--model" ]
    [ "${lines[3]}" = "gpt-5" ]
}

@test "omp wrapper omits --append-system-prompt when the addendum is absent" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local fakebin="$TEST_HOME/bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/omp" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
SH
    chmod +x "$fakebin/omp"
    # No addendum on disk (e.g. tight profile with no APPEND_SYSTEM.md): the
    # wrapper must not pass a nonexistent path to omp.
    run zsh -c "PATH='$fakebin':\$PATH; HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/aliases.zsh'; ompt --model gpt-5"

    assert_success
    [ "${lines[0]}" = "--model" ]
    [ "${lines[1]}" = "gpt-5" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "completion.zsh has cdd completion" {
    local completion_file="$REAL_DOTFILES_DIR/zsh/completion.zsh"

    # Should have cdd completion function
    grep -q "_cdd()" "$completion_file"
    grep -q "compdef _cdd cdd" "$completion_file"

    # Should NOT have history config (moved to core.zsh)
    ! grep -q "HISTFILE" "$completion_file"
    ! grep -q "HISTSIZE" "$completion_file"
}

@test "zshrc sources files in correct order" {
    local zshrc_file="$REAL_DOTFILES_DIR/zshrc"

    # Should source our simplified files
    grep -q "source.*core.zsh" "$zshrc_file"
    grep -q "source.*aliases.zsh" "$zshrc_file"
    grep -q "source.*completion.zsh" "$zshrc_file"
    grep -q "source.*fzf.zsh" "$zshrc_file"
    grep -q "source.*prompt.zsh" "$zshrc_file"

    # Should NOT have old complex sourcing loop
    ! grep -q "for config_file" "$zshrc_file"
}

@test "cdd function works with DEV_DIR" {
    # Create mock Dev directory
    mkdir -p "$TEST_HOME/Dev/project1"
    mkdir -p "$TEST_HOME/Dev/project2"

    export DEV_DIR="$TEST_HOME/Dev"

    # Source the function
    source "$REAL_DOTFILES_DIR/zsh/aliases.zsh"

    # Test cdd without arguments - use basename to avoid path normalization issues
    run bash -c "cd /tmp && source '$REAL_DOTFILES_DIR/zsh/aliases.zsh' && cdd && pwd | xargs basename"
    assert_output_contains "Dev"
}

@test "cdd completion lists directories" {
    # Create mock Dev directory with projects
    mkdir -p "$TEST_HOME/Dev/project-a"
    mkdir -p "$TEST_HOME/Dev/project-b"

    export DEV_DIR="$TEST_HOME/Dev"

    # Test that _cdd function is defined in the file (can't source zsh in bash)
    grep -q "_cdd()" "$REAL_DOTFILES_DIR/zsh/completion.zsh"
}

@test "ripgrep aliases are defined" {
    local aliases_file="$REAL_DOTFILES_DIR/zsh/aliases.zsh"

    # Test some key ripgrep aliases exist in the file (can't source zsh in bash)
    grep -q "alias todos=" "$aliases_file"
    grep -q "alias rga=" "$aliases_file"
    grep -q "alias rgf=" "$aliases_file"
    grep -q "alias rgc=" "$aliases_file"
}

@test "fzf configuration has no syntax errors" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    # Test fzf config has valid zsh syntax
    run zsh -n "$REAL_DOTFILES_DIR/zsh/fzf.zsh"
    [[ $status -eq 0 ]]
}

@test "tmux.zsh parses cleanly" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -n "$REAL_DOTFILES_DIR/zsh/tmux.zsh"
    [[ $status -eq 0 ]]
}

@test "configuration files have no syntax errors" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local failed=0
    for f in core.zsh aliases.zsh completion.zsh fzf.zsh; do
        if ! zsh -n "$REAL_DOTFILES_DIR/zsh/$f" 2>/dev/null; then
            echo "Syntax error in: $f" >&2
            failed=1
        fi
    done
    if ! zsh -n "$REAL_DOTFILES_DIR/zshrc" 2>/dev/null; then
        echo "Syntax error in: zshrc" >&2
        failed=1
    fi
    [[ $failed -eq 0 ]]
}
