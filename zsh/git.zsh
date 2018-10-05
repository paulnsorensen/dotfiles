# generally this is a subset from here: https://github.com/robbyrussell/oh-my-zsh/wiki/Plugin:git

alias ga='git add'
alias gb='git branch'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gc='git commit -v'
alias gcm='git commit -m'
alias gd='git diff'
alias gdn='git diff --name-only'
alias gf='git fetch'
alias gl='git pull'
alias gp='git push'
alias gst='git status'

# remove files that match .gitignore
alias gri='git rm --cached `git ls-files -i -X .gitignore`'
