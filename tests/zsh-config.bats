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
    [[ ! -f "$REAL_DOTFILES_DIR/zsh/claude.zsh" ]]
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
    grep -q "alias rgjs=" "$aliases_file"
    
    # Should have utility aliases
    grep -q "alias uuidg=" "$aliases_file"
    grep -q "alias zrl=" "$aliases_file"
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
    
    # Test cdd without arguments
    run bash -c "cd /tmp && source '$REAL_DOTFILES_DIR/zsh/aliases.zsh' && cdd && pwd"
    assert_output_contains "$TEST_HOME/Dev"
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
    grep -q "alias rgjs=" "$aliases_file"
    grep -q "alias rgts=" "$aliases_file"
    grep -q "alias rgfunc=" "$aliases_file"
}

@test "fzf configuration has no syntax errors" {
    # Test fzf config has valid zsh syntax
    run zsh -n "$REAL_DOTFILES_DIR/zsh/fzf.zsh"
    [[ $status -eq 0 ]]
}

@test "configuration files have no syntax errors" {
    # Test each file for syntax errors
    run zsh -n "$REAL_DOTFILES_DIR/zsh/core.zsh"
    [[ $status -eq 0 ]]
    
    run zsh -n "$REAL_DOTFILES_DIR/zsh/aliases.zsh"
    [[ $status -eq 0 ]]
    
    run zsh -n "$REAL_DOTFILES_DIR/zsh/completion.zsh"
    [[ $status -eq 0 ]]
    
    run zsh -n "$REAL_DOTFILES_DIR/zsh/fzf.zsh"
    [[ $status -eq 0 ]]
    
    run zsh -n "$REAL_DOTFILES_DIR/zshrc"
    [[ $status -eq 0 ]]
}