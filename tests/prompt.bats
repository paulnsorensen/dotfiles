#!/usr/bin/env bats
# Tests for both prompt systems: zsh powerline (prompt.zsh) and starship

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# ── zsh powerline prompt (prompt.zsh) ─────────────────────────────────────────

@test "prompt.zsh has valid zsh syntax" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -n "$DOTFILES_DIR/zsh/prompt.zsh"
    [[ $status -eq 0 ]]
}

@test "prompt.zsh defines time_since_commit function" {
    grep -q "^time_since_commit()" "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "prompt.zsh defines render_prompt function" {
    grep -q "^render_prompt()" "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "time_since_commit: minutes only for <1h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 1800"
    [[ "$output" == "30m" ]]
}

@test "time_since_commit: hours and minutes for 1-24h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 5400"
    [[ "$output" == "1h30m" ]]
}

@test "time_since_commit: days and hours for 24-48h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 90000"
    [[ "$output" == "1d1h" ]]
}

@test "time_since_commit: days only for >48h" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 259200"
    [[ "$output" == "3d" ]]
}

@test "time_since_commit: zero seconds shows 0m" {
    run bash -c "$(sed -n '/^time_since_commit()/,/^}/p' "$DOTFILES_DIR/zsh/prompt.zsh"); time_since_commit 0"
    [[ "$output" == "0m" ]]
}

@test "prompt.zsh uses colors from colors.zsh" {
    # Verify it references the color variables, not hardcoded values
    grep -q '__SDW_' "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "prompt.zsh sets up vcs_info for git" {
    grep -q "enable git" "$DOTFILES_DIR/zsh/prompt.zsh"
}

@test "prompt.zsh registers precmd hook" {
    grep -q "add-zsh-hook precmd" "$DOTFILES_DIR/zsh/prompt.zsh"
}
