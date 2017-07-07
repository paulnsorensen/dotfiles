# dotfiles by @paulnsorensen (with a lot of copying from others)

setopt ZLE          # ZSH line editor
setopt VI

# VI editing mode is a pain to use if you have to wait for <ESC> to register.
# This times out multi-char key combos as fast as possible. (1/100th of a
# second.)
KEYTIMEOUT=1

## Source all zsh customizations
if [ -d $HOME/.zsh ]
then
    for config_file ($HOME/.zsh/*) source $config_file
fi

[ $HOME/.zshrc.local ] && source .zshrc.local


bindkey -v
autoload -U edit-command-line
zle -N edit-command-line
bindkey -M vicmd v edit-command-line
bindkey '^r' history-incremental-search-backward


setopt NO_BEEP      # Never ever beep. Ever
MAILCHECK=0         # disable mail checking

export EDITOR=$(which vim)
export VISUAL=$EDITOR   # some programs use this instead of EDITOR
export PAGER=less       # less is more :)
export LESS='-i -M -R'  # case insensitive searching, status line, and colors

clear
