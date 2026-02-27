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

# ── Starship prompt ───────────────────────────────────────────────────────────

@test "starship config parses without errors" {
    command -v starship &>/dev/null || skip "starship not installed"
    run env STARSHIP_CONFIG="$DOTFILES_DIR/starship/starship.toml" starship print-config
    [[ $status -eq 0 ]]
}

@test "starship uses chocolate donut palette" {
    grep -q 'palette = "chocolate_donut"' "$DOTFILES_DIR/starship/starship.toml"
    grep -q '\[palettes.chocolate_donut\]' "$DOTFILES_DIR/starship/starship.toml"
}

@test "starship custom git_time module matches prompt.zsh logic" {
    # Both prompts should have the same time-since-commit breakpoints
    local starship="$DOTFILES_DIR/starship/starship.toml"
    local zsh_prompt="$DOTFILES_DIR/zsh/prompt.zsh"

    # Both should use 48h as the "days only" threshold
    grep -q '48' "$starship"
    grep -q '48' "$zsh_prompt"

    # Both should use 24h as the "days+hours" threshold
    grep -q '24' "$starship"
    grep -q '24' "$zsh_prompt"
}

@test "starship has vi mode indicators" {
    local config="$DOTFILES_DIR/starship/starship.toml"
    grep -q 'vimcmd_symbol' "$config"
    grep -q 'vimcmd_replace_symbol' "$config"
    grep -q 'vimcmd_visual_symbol' "$config"
}

@test "starship disables noisy modules" {
    local config="$DOTFILES_DIR/starship/starship.toml"
    # Package version is noise in a prompt
    grep -q '^\[package\]' "$config"
    grep -A1 '^\[package\]' "$config" | grep -q 'disabled = true'
}

@test "starship git modules are enabled" {
    local config="$DOTFILES_DIR/starship/starship.toml"
    for mod in git_branch git_status git_state git_metrics git_commit; do
        grep -q "^\[$mod\]" "$config" || {
            echo "Missing module: $mod" >&2
            return 1
        }
    done
}
