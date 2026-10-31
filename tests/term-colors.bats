#!/usr/bin/env bats
# Tests for bin/lib/term-colors.sh and bin/lib/tagged-log.sh.

setup() {
    LIB_DIR="$BATS_TEST_DIRNAME/../bin/lib"
}

@test "term-colors defines every colour constant" {
    run bash -c 'source "$1/term-colors.sh"
        printf "%s|" "$RED" "$GREEN" "$YELLOW" "$BLUE" "$CYAN" "$DIM" "$BOLD" "$NC" "$RESET"' _ "$LIB_DIR"
    [ "$status" -eq 0 ]
    [ "$output" = '\033[0;31m|\033[0;32m|\033[1;33m|\033[0;34m|\033[0;36m|\033[2m|\033[1m|\033[0m|\033[0m|' ]
}

@test "term-colors leaves the caller's shell options alone" {
    run bash -c 'before=$-; source "$1/term-colors.sh"; [[ $- == "$before" ]]' _ "$LIB_DIR"
    [ "$status" -eq 0 ]
}

@test "tagged-log log and ok write the tag to stdout only" {
    run bash -c 'LOG_TAG=demo; source "$1/tagged-log.sh"; log hello; ok done' _ "$LIB_DIR" 2>/dev/null
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'\e[0;34m[demo]\e[0m hello' ]
    [ "${lines[1]}" = $'\e[0;32m[demo]\e[0m done' ]
}

@test "tagged-log warn and err write the tag to stderr only" {
    out=$(bash -c 'LOG_TAG=demo; source "$1/tagged-log.sh"; warn careful; err broken' _ "$LIB_DIR" 2>/dev/null)
    [ -z "$out" ]
    errout=$(bash -c 'LOG_TAG=demo; source "$1/tagged-log.sh"; warn careful; err broken' _ "$LIB_DIR" 2>&1 >/dev/null)
    [ "$errout" = $'\e[1;33m[demo]\e[0m careful\n\e[0;31m[demo]\e[0m broken' ]
}

@test "tagged-log joins multiple arguments" {
    run bash -c 'LOG_TAG=t; source "$1/tagged-log.sh"; log a b c' _ "$LIB_DIR"
    [ "$output" = $'\e[0;34m[t]\e[0m a b c' ]
}

@test "tagged-log sets no shell options and loads from any cwd" {
    cd /
    run bash -c 'before=$-; LOG_TAG=t; source "$1/tagged-log.sh"; [[ $- == "$before" ]] && declare -F log ok warn err | wc -l' _ "$LIB_DIR"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}
