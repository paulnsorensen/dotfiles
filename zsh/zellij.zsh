# zellij.zsh — Zellij integration (coexists with tmux)

# Aliases
alias zj='zellij'
alias zjl='zellij list-sessions'
alias zja='zellij attach'
alias zjk='zellij kill-session'

# Attach or create named session
zjs() {
    local name="${1:-main}"
    zellij attach --create "$name"
}

# Launch with dev layout
zjdev() {
    local session="${1:-dev}"
    zellij --new-session-with-layout dev --session "$session"
}

# Launch with Claude monitor layout (generates layout with cwd baked in)
zjclaude() {
    local session="${1:-claude}"

    # Don't nest inside existing zellij
    if [[ -n "$ZELLIJ" ]]; then
        echo "Already inside zellij — use zjclaude from an outside terminal" >&2
        return 1
    fi

    # Kill stale session with same name (dead sessions block --session)
    if zellij list-sessions 2>/dev/null | grep -q "^${session} "; then
        zellij kill-session "$session" 2>/dev/null
    fi

    local tmpdir="${TMPDIR:-/tmp}"
    local layout="${tmpdir}/zjclaude-layout.kdl"
    cat > "$layout" <<EOF
layout {
    pane size=1 borderless=true {
        plugin location="zellij:compact-bar"
    }
    pane focus=true cwd="$PWD" {
        command "claude"
    }
    pane size=2 borderless=true name="monitor" cwd="$PWD" {
        command "claude-monitor"
        args "--cwd" "$PWD"
    }
}
EOF
    if [[ ! -f "$layout" ]]; then
        echo "Failed to write layout to $layout" >&2
        return 1
    fi

    zellij --new-session-with-layout "$layout" --session "$session"
}

# Auto-attach guard (opt-in — uncomment in ~/.zshrc.local)
# Prevents nesting: checks for existing tmux/zellij
zellij_auto_attach() {
    [[ -n "$TMUX" ]]   && return
    [[ -n "$ZELLIJ" ]] && return
    [[ ! -t 1 ]]       && return
    [[ "$TERM" == "dumb" ]] && return
    [[ -n "$CI" ]]     && return
    exec zellij attach --create "main"
}
