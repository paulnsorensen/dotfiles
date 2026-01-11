# fzf configuration

# Set up fzf key bindings and fuzzy completion
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Use fd instead of find for better performance and respects .gitignore
if command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
else
    export FZF_DEFAULT_COMMAND='find . -type f'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='find . -type d'
fi

# Preview files with bat if available, fallback to cat
if command -v bat >/dev/null 2>&1; then
    export FZF_CTRL_T_OPTS="--preview 'bat --style=numbers --color=always --line-range :500 {}'"
else
    export FZF_CTRL_T_OPTS="--preview 'cat {}'"
fi

# Preview directories with tree if available
if command -v tree >/dev/null 2>&1; then
    export FZF_ALT_C_OPTS="--preview 'tree -C {} | head -200'"
fi

# Selenized Dark theme for fzf to match your setup
export FZF_DEFAULT_OPTS='
  --color=fg:#adbcbc,bg:#103c48,hl:#ad7fa8
  --color=fg+:#adbcbc,bg+:#184956,hl+:#ad7fa8
  --color=info:#8ae234,prompt:#fcaf3e,pointer:#fcaf3e
  --color=marker:#fcaf3e,spinner:#fcaf3e,header:#729fcf
  --height=50% --layout=reverse --border --inline-info'

# Fallback if fzf isn't available
if [ ! -f ~/.fzf.zsh ]; then
    bindkey "^r" history-incremental-search-backward
fi