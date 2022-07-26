# https://routley.io/tech/2017/11/23/logbook.html
function lb() {
    vim ~/logbook/$(date '+%Y-%m-%d').md
}

alias uuidg="/usr/bin/uuidgen | tr 'A-Z' 'a-z' | tee /dev/stderr | tr -d '\n' | pbcopy"

alias cdd="cd ~/Dev"

# for nix
alias hms="home-manager switch"
