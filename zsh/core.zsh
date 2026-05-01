# core.zsh - Essential environment and settings
# This file sets up the foundation for the shell environment

# Shell behavior
setopt VI                    # Vi editing mode
setopt NO_BEEP              # Never ever beep. Ever
KEYTIMEOUT=1                # Fast escape key timeout for vi mode (1/100th of a second)
MAILCHECK=0                 # disable mail checking

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_ALL_DUPS # Remove older duplicate entries
setopt HIST_IGNORE_SPACE    # Don't record commands starting with space
setopt SHARE_HISTORY        # Share history between sessions
setopt HIST_VERIFY          # Show command with history expansion before running

# Key bindings for vi mode
bindkey -v
autoload -U edit-command-line
zle -N edit-command-line
bindkey -M vicmd v edit-command-line

# Vi mode cursor shapes (orthogonal to prompt choice — works with any prompt)
function zle-line-init zle-keymap-select {
  if [[ $KEYMAP == vicmd ]]; then
    echo -ne '\e[2 q' # Solid block — normal mode
  elif [[ $KEYMAP == main ]] \
    || [[ $KEYMAP == viins ]] \
    || [[ $KEYMAP = '' ]]; then
    echo -ne '\e[5 q' # Blinking beam — insert mode (matches native vim)
  fi
  zle reset-prompt
  zle -R
}
zle -N zle-line-init
zle -N zle-keymap-select
