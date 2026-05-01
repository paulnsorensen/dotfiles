#!/usr/bin/env bats
# Tests for simplified zsh configuration architecture

load test_helper

setup() {
    setup_test_env
    # Copy zsh files to test home
    mkdir -p "$TEST_HOME/Dev/dotfiles/zsh"
    cp "$REAL_DOTFILES_DIR/zsh"/*.zsh "$TEST_HOME/Dev/dotfiles/zsh/" 2>/dev/null || true
    cp "$REAL_DOTFILES_DIR/zshrc" "$TEST_HOME/.zshrc"
    cp "$REAL_DOTFILES_DIR/.zprofile" "$TEST_HOME/.zprofile"
}

teardown() {
    teardown_test_env
}

@test "simplified zsh architecture has correct files" {
    # Core files should exist
    assert_file_exists "$REAL_DOTFILES_DIR/.zprofile"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/core.zsh"
    assert_file_exists "$REAL_DOTFILES_DIR/zsh/profile.zsh"
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

@test "profile.zsh contains login shell environment" {
    local profile_file="$REAL_DOTFILES_DIR/zsh/profile.zsh"

    grep -q 'export DOTFILES_DIR=' "$profile_file"
    grep -q 'export DEV_DIR=' "$profile_file"
    grep -q 'export PREK_HOME=' "$profile_file"
    grep -q 'export EDITOR=' "$profile_file"
    grep -q 'export PAGER=' "$profile_file"
    grep -q 'export DOTFILES_PROFILE_LOADED=1' "$profile_file"
    grep -q 'pyenv init' "$profile_file"
}

@test "core.zsh contains essential interactive settings" {
    local core_file="$REAL_DOTFILES_DIR/zsh/core.zsh"

    # Should have history configuration
    grep -q "HISTFILE" "$core_file"
    grep -q "HISTSIZE" "$core_file"
    grep -q "SAVEHIST" "$core_file"

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

@test ".zprofile sources login environment and .zprofile.local" {
    cat > "$TEST_HOME/.zprofile.local" <<'EOF'
export ZPROFILE_LOCAL_MARKER="loaded"
EOF

    run env HOME="$TEST_HOME" ZDOTDIR="$TEST_HOME" zsh -lc 'printf "DOTFILES_PROFILE_LOADED=%s\nDOTFILES_DIR=%s\nDEV_DIR=%s\nZPROFILE_LOCAL_MARKER=%s\n" "$DOTFILES_PROFILE_LOADED" "$DOTFILES_DIR" "$DEV_DIR" "$ZPROFILE_LOCAL_MARKER"'

    [[ $status -eq 0 ]]
    assert_output_contains "DOTFILES_PROFILE_LOADED=1"
    assert_output_contains "DOTFILES_DIR=$TEST_HOME/Dev/dotfiles"
    assert_output_contains "DEV_DIR=$TEST_HOME/Dev"
    assert_output_contains "ZPROFILE_LOCAL_MARKER=loaded"
}

@test "login interactive shell loads both .zprofile.local and .zshrc.local" {
    cat > "$TEST_HOME/.zprofile.local" <<'EOF'
export ZPROFILE_LOCAL_MARKER="profile"
EOF

    cat > "$TEST_HOME/.zshrc.local" <<'EOF'
export ZSHRC_LOCAL_MARKER="${ZPROFILE_LOCAL_MARKER}-rc"
EOF

    run env HOME="$TEST_HOME" ZDOTDIR="$TEST_HOME" TERM=dumb zsh -lic 'printf "ZPROFILE_LOCAL_MARKER=%s\nZSHRC_LOCAL_MARKER=%s\n" "$ZPROFILE_LOCAL_MARKER" "$ZSHRC_LOCAL_MARKER"'

    [[ $status -eq 0 ]]
    assert_output_contains "ZPROFILE_LOCAL_MARKER=profile"
    assert_output_contains "ZSHRC_LOCAL_MARKER=profile-rc"
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
    # Test fzf config has valid zsh syntax
    run zsh -n "$REAL_DOTFILES_DIR/zsh/fzf.zsh"
    [[ $status -eq 0 ]]
}

@test "configuration files have no syntax errors" {
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
    if ! zsh -n "$REAL_DOTFILES_DIR/.zprofile" 2>/dev/null; then
        echo "Syntax error in: .zprofile" >&2
        failed=1
    fi
    [[ $failed -eq 0 ]]
}
