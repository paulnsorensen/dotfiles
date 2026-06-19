#!/usr/bin/env bats
# Tests for bin/cheatsheet

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
    run cheatsheet
    [[ $status -eq 0 ]]
}

@test "prints Git section" {
    run cheatsheet
    assert_section "Git"
}

@test "prints Claude launchers section" {
    run cheatsheet
    assert_section "Claude launchers"
}

@test "prints Worktrees section" {
    run cheatsheet
    assert_section "Worktrees"
}

@test "prints MCP / Hooks / Agents section" {
    run cheatsheet
    assert_section "MCP / Hooks / Agents"
}

@test "prints tmux section" {
    run cheatsheet
    assert_section "tmux"
}

@test "prints GitHub helpers section" {
    run cheatsheet
    assert_section "GitHub helpers"
}

@test "cc launcher is listed" {
    run cheatsheet
    assert_section "cc [args]"
}

@test "ccw worktree launcher is listed" {
    run cheatsheet
    assert_section "ccw <slug>"
}

@test "dots command is listed" {
    run cheatsheet
    assert_section "dots <cmd>"
}

@test "tmux prefix binding is documented" {
    run cheatsheet
    assert_section "Ctrl+Space"
}

@test "tmux sesh session switcher is documented" {
    run cheatsheet
    assert_section "sesh"
}

@test "output is not empty" {
    run cheatsheet
    [[ ${#output} -gt 100 ]]
}
