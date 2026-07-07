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

@test "documents the Ctrl+Space prefix" {
    run tmux-cheatsheet
    assert_section "Ctrl+Space"
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

@test "documents the shell-prompt sesh picker" {
    run tmux-cheatsheet
    assert_section "Alt+s (shell)"
}

@test "prints the zsh tmux & remote shortcuts section" {
    run tmux-cheatsheet
    assert_section "zsh tmux & remote shortcuts"
}

@test "lists the zsh tmux session shortcuts" {
    run tmux-cheatsheet
    assert_section "tls"
    assert_section "ta [name]"
    assert_section "tn <name>"
    assert_section "tk <name>"
    assert_section "tsw"
}

@test "lists the mosh/tailscale remote shortcuts" {
    run tmux-cheatsheet
    assert_section "mtmux <host>"
    assert_section "trl"
    assert_section "tss"
    assert_section "tsip"
}


@test "documents the extrakto fuzzy text picker" {
    run tmux-cheatsheet
    assert_section "prefix Tab"
    assert_section "extrakto"
}

@test "documents resurrect save/restore bindings" {
    run tmux-cheatsheet
    assert_section "prefix Ctrl+s"
    assert_section "prefix Ctrl+r"
    assert_section "resurrect"
}

@test "shows live bindings section when inside tmux" {
    MOCK_BIN="$(mktemp -d)"
    cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list-keys" && "$2" == "-N" ]]; then
    printf 'C-Space |       split vertically (keeps cwd)\nC-Space M-1     jump to window N\n'
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/tmux"
    PATH="$MOCK_BIN:$PATH" TMUX=fake run tmux-cheatsheet
    rm -rf "$MOCK_BIN"
    [[ "$status" -eq 0 ]]
    assert_section "Live bindings"
    assert_section "split vertically (keeps cwd)"
    assert_section "jump to window N"
}

@test "omits live bindings section when TMUX is unset" {
    MOCK_BIN="$(mktemp -d)"
    cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'C-Space |       split vertically (keeps cwd)\n'
exit 0
EOF
    chmod +x "$MOCK_BIN/tmux"
    unset TMUX
    PATH="$MOCK_BIN:$PATH" run tmux-cheatsheet
    rm -rf "$MOCK_BIN"
    [[ "$status" -eq 0 ]]
    clean=$(strip_ansi "$output")
    [[ "$clean" != *"Live bindings"* ]]
}

@test "still exits 0 when the tmux list-keys call fails inside tmux" {
    MOCK_BIN="$(mktemp -d)"
    cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$MOCK_BIN/tmux"
    PATH="$MOCK_BIN:$PATH" TMUX=fake run tmux-cheatsheet
    rm -rf "$MOCK_BIN"
    [[ "$status" -eq 0 ]]
}
