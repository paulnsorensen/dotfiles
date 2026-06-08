#!/usr/bin/env bats
# Tests for bin/tmux-cheatsheet

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"

strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

assert_section() {
    local clean
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"$1"* ]] || {
        echo "Missing section: $1"
        echo "Output (stripped): $clean"
        return 1
    }
}

@test "exits 0" {
    run tmux-cheatsheet
    [[ $status -eq 0 ]]
}

@test "documents the Ctrl+a prefix" {
    run tmux-cheatsheet
    assert_section "Ctrl+a"
}

@test "prints Panes section" {
    run tmux-cheatsheet
    assert_section "Panes"
}

@test "prints Windows section" {
    run tmux-cheatsheet
    assert_section "Windows"
}

@test "prints Copy mode section" {
    run tmux-cheatsheet
    assert_section "Copy mode"
}

@test "prints in-tmux Sessions section" {
    run tmux-cheatsheet
    assert_section "Sessions (in tmux)"
}

@test "prints CLI Sessions section" {
    run tmux-cheatsheet
    assert_section "Sessions (CLI)"
}

@test "lists tmux ls" {
    run tmux-cheatsheet
    assert_section "tmux ls"
}

@test "lists tmux attach shortcut" {
    run tmux-cheatsheet
    assert_section "tmux a"
}

@test "documents the new-window-in-cwd binding" {
    run tmux-cheatsheet
    assert_section "new window (keeps cwd)"
}

@test "output is not empty" {
    run tmux-cheatsheet
    [[ ${#output} -gt 100 ]]
}
