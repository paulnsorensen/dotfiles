#!/usr/bin/env bats

load test_helper

@test "TUI suite declares four local skills with discipline gates" {
    for skill in tui-design tui-verify tui-demo term-theme; do
        local path="$REAL_DOTFILES_DIR/skills/$skill/SKILL.md"
        assert_file_exists "$path"
        grep -Fq '**Iron Law:**' "$path"
        grep -Fq '**Red Flags**' "$path"
        grep -Fq '| Rationalization |' "$path"
    done
}

@test "TUI profile references every suite skill and required tools" {
    local profile="$REAL_DOTFILES_DIR/profiles/tui/profile.yaml"
    for skill in tui-design tui-verify tui-demo term-theme; do
        [[ "$(yq -r ".skills[] | select(.name == \"$skill\") | .name" "$profile")" == "$skill" ]]
    done
    for tool in agent-tty vhs cargo uv tmux; do
        grep -Fq "Bash($tool:*)" "$profile"
    done
}

@test "TUI verify distinguishes build edits from audit reports" {
    local skill="$REAL_DOTFILES_DIR/skills/tui-verify/SKILL.md"
    grep -Fq 'audit**: review an existing TUI and emit a severity report without edits' "$skill"
    grep -Fq 'minimum width above 40 columns' "$skill"
}

@test "TUI demo example passes VHS parser validation" {
    command -v vhs >/dev/null 2>&1 || skip "vhs not installed"
    run vhs validate "$REAL_DOTFILES_DIR/skills/tui-demo/examples/status.tape"
    assert_success
}
