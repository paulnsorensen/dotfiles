# https://routley.io/tech/2017/11/23/logbook.html
function lb() {
    vim ~/logbook/$(date '+%Y-%m-%d').md
}

alias uuidgen="/usr/bin/uuidgen | tr 'A-Z' 'a-z' | tee /dev/stderr | tr -d '\n' | pbcopy"

alias cdd="cd ~/Dev"
