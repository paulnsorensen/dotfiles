# https://routley.io/tech/2017/11/23/logbook.html
function lb() {
    local logbook_dir="$HOME/logbook"
    local logbook_file="$logbook_dir/$(date '+%Y-%m-%d').md"
    
    # Create logbook directory if it doesn't exist
    [[ ! -d "$logbook_dir" ]] && mkdir -p "$logbook_dir"
    
    vim "$logbook_file"
}

alias uuidg="/usr/bin/uuidgen | tr 'A-Z' 'a-z' | tee /dev/stderr | tr -d '\n' | pbcopy"

alias cdd="cd ~/Dev"

# for nix
alias hms="home-manager switch"
