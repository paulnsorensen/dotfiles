# tmux.zsh — sesh shell-prompt session picker (ZLE widget)

if command -v sesh &>/dev/null; then
  sesh-sessions() {
    exec </dev/tty
    exec <&1
    local session
    session=$(sesh list -i | fzf --height 40% --reverse --border-label ' sesh ' --prompt '⚡  ')
    zle reset-prompt 2>/dev/null
    [[ -z "$session" ]] && return 0
    sesh connect "$session"
  }
  zle -N sesh-sessions
  bindkey -M viins '\es' sesh-sessions
  bindkey -M vicmd '\es' sesh-sessions
fi
