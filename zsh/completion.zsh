##
# Stolen from https://github.com/natebosch/dotfiles/blob/master/zshrc.d/completion.zsh
# because he is my friend
##

setopt COMPLETE_IN_WORD     # Allow tab completion in the middle of a word
setopt CORRECT              # Spell check commands
setopt ALWAYS_TO_END        # Push cursor on completions.

setopt histignorealldups sharehistory
setopt HIST_VERIFY           # Show command with history expansion to user before running it
setopt HIST_IGNORE_SPACE     # Don't save commands that start with space

# Keep 1000 lines of history within the shell and save it to ~/.zsh_history:
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=~/.zsh_history

# Use modern completion system
autoload -Uz compinit

# Ensure cache directory exists
[[ ! -d $HOME/.zsh/cache ]] && mkdir -p $HOME/.zsh/cache

compinit

# cache completions
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path $HOME/.zsh/cache

# case insensitive completion when typing with lowercase
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# ignore completion functions for missing commands
zstyle ':completion:*:functions' ignored-patterns '_*'

zstyle ':completion:*' menu select
zstyle ':completion:*' verbose true
zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*:descriptions' format '%B%d%b'
zstyle ':completion:*:messages' format '%d'
zstyle ':completion:*:warnings' format 'No matches for: %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' completer _oldlist _expand _complete _correct _approximate
# Have the newer files last so I see them first
zstyle ':completion:*' file-sort modification reverse

zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

zstyle ':completion::complete:git-checkout:*' matcher 'm:{a-z-_}={A-Z_-}' 'r:|=*' 'l:|=* r:|=*'

zstyle ':completion:*' menu select=2
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' menu select=long
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false

zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'
