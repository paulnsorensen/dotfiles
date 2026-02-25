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
    zellij --layout dev --session "$session"
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
