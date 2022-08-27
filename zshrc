# dotfiles by @paulnsorensen (with a lot of copying from others)


if [[ $OSTYPE == darwin* ]]; then
  path=(
    /opt/homebrew/bin
    $path
    )
    export PATH=$(brew --prefix openssl)/bin:$PATH
fi

fpath=(
  ~/.nix-profile/share/zsh/site-functions
  $fpath
)

setopt ZLE          # ZSH line editor
setopt VI

# VI editing mode is a pain to use if you have to wait for <ESC> to register.
# This times out multi-char key combos as fast as possible. (1/100th of a
# second.)
KEYTIMEOUT=1

# nix
if [ -e ~/.nix-profile/etc/profile.d/nix.sh ]; then
  source ~/.nix-profile/etc/profile.d/nix.sh
fi
if [ -e ~/.nix-profile/etc/profile.d/hm-session-vars.sh ]; then
  source ~/.nix-profile/etc/profile.d/hm-session-vars.sh
fi


## Source all zsh customizations
if [ -d $HOME/.zsh ]
then
    for config_file ($HOME/.zsh/*) source $config_file
fi

[ -f $HOME/.zshrc.local ] && source .zshrc.local


bindkey -v
autoload -U edit-command-line
zle -N edit-command-line
bindkey -M vicmd v edit-command-line


setopt NO_BEEP      # Never ever beep. Ever
MAILCHECK=0         # disable mail checking

export EDITOR=$(which vim)
export VISUAL=$EDITOR   # some programs use this instead of EDITOR
export PAGER=less       # less is more :)
export LESS='-i -M -R'  # case insensitive searching, status line, and colors

# init pyenv if it exists
if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init -)"
fi

# reload this script
alias zrl="source ${(%):-%N}"

clear

[ -f $HOME/.iterm2_shell_integration.zsh ] && source $HOME/.iterm2_shell_integration.zsh

# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/opt/homebrew/Caskroom/miniforge/base/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/opt/homebrew/Caskroom/miniforge/base/etc/profile.d/conda.sh" ]; then
        . "/opt/homebrew/Caskroom/miniforge/base/etc/profile.d/conda.sh"
    else
        export PATH="/opt/homebrew/Caskroom/miniforge/base/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<
