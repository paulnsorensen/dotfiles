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

# ── tmux session shortcuts (shell prompt) ───────────────────────────────────
# Documented in `tmux-cheatsheet`, alongside mtmux/tss/tsip/trl.
if command -v tmux &>/dev/null; then
  alias tls='tmux ls'                       # list sessions

  # ta [name] — attach (most recent, or a named session)
  ta() { if [[ -n "$1" ]]; then tmux attach -t "$1"; else tmux attach; fi }

  # tn <name> — new named session
  tn() { tmux new -s "${1:?usage: tn <name>}"; }

  # tk <name> — kill a named session
  tk() { tmux kill-session -t "${1:?usage: tk <name>}"; }

  # tsw — fzf-pick any session and switch (inside tmux) or attach (outside)
  tsw() {
    command -v fzf &>/dev/null || { echo "tsw: fzf not installed" >&2; return 1; }
    local s
    s="$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
      | fzf --height 40% --reverse --border-label ' tmux ' --prompt '  ')"
    [[ -z "$s" ]] && return 0
    if [[ -n "$TMUX" ]]; then tmux switch-client -t "$s"; else tmux attach -t "$s"; fi
  }
fi
