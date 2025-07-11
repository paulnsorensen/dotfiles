
export FZF_DEFAULT_OPTS="--exact --inline-info"

# Check if find_files command exists, fallback to find
if command -v find_files >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND="find_files"
  export FZF_CTRL_T_COMMAND="find_files"
else
  export FZF_DEFAULT_COMMAND="find . -type f"
  export FZF_CTRL_T_COMMAND="find . -type f"
fi

# Check if preview command exists
if command -v preview >/dev/null 2>&1; then
  export FZF_CTRL_T_OPTS="--preview 'preview {}'"
  export FZF_PREVIEW_COMMAND="preview {}"
else
  export FZF_CTRL_T_OPTS="--preview 'cat {}'"
  export FZF_PREVIEW_COMMAND="cat {}"
fi

# Fallbacks if fzf isn't available
if [ ! -f ~/.fzf.zsh ]
then
  bindkey "^r" history-incremental-search-backward
fi
