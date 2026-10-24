#!/usr/bin/env bats
# shellcheck disable=SC2016  # Mock bodies and expected script strings stay literal.
# Tests for bin/alfred-wt, the backend of the Alfred `wt` workflow
# (bin/lib/alfred.sh, alfred/workflows/wt/info.plist). Real git worktrees feed
# the script filter; `open`, `pbcopy`, and the session shell are mocks because
# they are macOS app boundaries.

load test_helper

setup() {
    setup_test_env
    SCAN="$TEST_HOME/scan"
    export DEV_DIR="$SCAN/Dev" T3_WORKTREES_DIR="$SCAN/t3"
    export MOCK_BIN="$TEST_HOME/mockbin" CALLS="$TEST_HOME/calls.log"
    mkdir -p "$MOCK_BIN" "$DEV_DIR" "$T3_WORKTREES_DIR"
    printf '#!/bin/bash\nprintf "open %%s\\n" "$*" >> "$CALLS"\n[[ "${OPEN_FAIL_GHOSTTY:-}" == 1 && "$*" == *Ghostty* ]] && exit 1\nexit 0\n' > "$MOCK_BIN/open"
    printf '#!/bin/bash\nprintf "pbcopy %%s\\n" "$(cat)" >> "$CALLS"\n' > "$MOCK_BIN/pbcopy"
    printf '#!/bin/bash\nprintf "shell %%s in %%s\\n" "$*" "$PWD" >> "$CALLS"\n' > "$MOCK_BIN/shell"
    chmod +x "$MOCK_BIN"/*
    export PATH="$MOCK_BIN:$PATH"
}

teardown() { teardown_test_env; }

create_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -b main --quiet
    git -C "$dir" -c user.email=t@t -c user.name=T commit --allow-empty -m init --quiet
}

@test "list emits Alfred items for Dev and T3 worktrees" {
    create_repo "$DEV_DIR/alpha"
    git -C "$DEV_DIR/alpha" worktree add --quiet "$DEV_DIR/alpha/.worktrees/login" -b claude/login
    create_repo "$SCAN/src/bravo"
    git -C "$SCAN/src/bravo" worktree add --quiet "$T3_WORKTREES_DIR/bravo/t3-abc" -b t3/review

    run alfred-wt list
    assert_success
    printf '%s' "$output" | jq -e . >/dev/null

    local dev_path="$DEV_DIR/alpha/.worktrees/login" t3_path="$T3_WORKTREES_DIR/bravo/t3-abc"
    [ "$(jq -r --arg p "$dev_path" '.items[] | select(.arg == $p) | .title' <<<"$output")" = "alpha/login" ]
    [ "$(jq -r --arg p "$t3_path" '.items[] | select(.arg == $p) | .title' <<<"$output")" = "bravo/t3-abc" ]
    [ "$(jq -r --arg p "$t3_path" '.items[] | select(.arg == $p) | .match' <<<"$output")" = "bravo t3-abc t3/review" ]
    [[ "$(jq -r --arg p "$dev_path" '.items[] | select(.arg == $p) | .subtitle' <<<"$output")" == "claude/login ("*" ago) · ~/scan/Dev/alpha/.worktrees/login" ]]
    [ "$(jq -r --arg p "$dev_path" '.items[] | select(.arg == $p) | "\(.variables.wt_action) \(.mods.cmd.variables.wt_action) \(.mods.alt.variables.wt_action) \(.mods.cmd.arg)"' <<<"$output")" = "terminal zed copy $dev_path" ]
    [ "$(jq '.items | length' <<<"$output")" -eq 2 ]
    [ "$(jq -c '.cache' <<<"$output")" = '{"seconds":300,"loosereload":true}' ]
}

@test "list escapes quotes and backslashes in worktree paths" {
    create_repo "$DEV_DIR/alpha"
    local odd='q"uo\te'
    git -C "$DEV_DIR/alpha" worktree add --quiet "$DEV_DIR/alpha/.worktrees/$odd" -b feat/odd

    run alfred-wt list
    assert_success
    [ "$(jq -r '.items[0].arg' <<<"$output")" = "$DEV_DIR/alpha/.worktrees/$odd" ]
    [ "$(jq -r '.items[0].title' <<<"$output")" = "alpha/$odd" ]
}

@test "list emits one invalid item when no worktree exists" {
    run alfred-wt list
    assert_success
    [ "$(jq -r '.items[0].title' <<<"$output")" = "No worktrees found" ]
    [ "$(jq -r '.items[0].valid' <<<"$output")" = "false" ]
    [ "$(jq '.items | length' <<<"$output")" -eq 1 ]
}

@test "open terminal starts the alfred-wt session in Ghostty" {
    mkdir -p "$SCAN/wt"
    run alfred-wt open terminal "$SCAN/wt"
    assert_success
    [ "$(cat "$CALLS")" = "open -na Ghostty --args -e $REAL_DOTFILES_DIR/bin/alfred-wt session $SCAN/wt" ]
}

@test "open terminal falls back to Terminal.app when Ghostty is missing" {
    mkdir -p "$SCAN/wt"
    OPEN_FAIL_GHOSTTY=1 run alfred-wt open terminal "$SCAN/wt"
    assert_success
    [ "$(tail -n 1 "$CALLS")" = "open -a Terminal $SCAN/wt" ]
}

@test "open zed and open copy act on the worktree path" {
    mkdir -p "$SCAN/wt"
    run alfred-wt open zed "$SCAN/wt"
    assert_success
    run alfred-wt open copy "$SCAN/wt"
    assert_success
    [ "$(cat "$CALLS")" = "open -a Zed $SCAN/wt"$'\n'"pbcopy $SCAN/wt" ]
}

@test "open rejects a missing path and an unknown action" {
    run alfred-wt open zed "$SCAN/missing"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a directory"* ]]
    mkdir -p "$SCAN/wt"
    run alfred-wt open bogus "$SCAN/wt"
    [ "$status" -eq 2 ]
    [ ! -e "$CALLS" ]
}

@test "session runs cc in a login shell inside the worktree" {
    mkdir -p "$SCAN/wt"
    ALFRED_WT_SHELL="$MOCK_BIN/shell" run alfred-wt session "$SCAN/wt"
    assert_success
    [ "$(cat "$CALLS")" = "shell -lic cc in $SCAN/wt" ]
}

# Print the dotfiles_dir variable and both script strings of a packaged workflow.
read_package() {
    python3 -I -c '
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    p = plistlib.loads(z.read("info.plist"))
print(p["variables"]["dotfiles_dir"])
for o in p["objects"]:
    print(o["type"], o["config"]["script"])
' "$1"
}

@test "install packages the workflow with the dotfiles path and opens it" {
    export TMPDIR="$TEST_HOME/tmp"
    mkdir -p "$TMPDIR"
    run alfred-wt install
    assert_success
    local pkg="$TMPDIR/Worktrees.alfredworkflow"
    [ "$(cat "$CALLS")" = "open $pkg" ]
    run read_package "$pkg"
    assert_success
    [ "${lines[0]}" = "$REAL_DOTFILES_DIR" ]
    [ "${lines[1]}" = 'alfred.workflow.input.scriptfilter exec "${dotfiles_dir:-$HOME/Dev/dotfiles}/bin/alfred-wt" list' ]
    [ "${lines[2]}" = 'alfred.workflow.action.script exec "${dotfiles_dir:-$HOME/Dev/dotfiles}/bin/alfred-wt" open "${wt_action:-terminal}" "$1"' ]
}

@test "packaging keeps XML metacharacters in the dotfiles path literal" {
    # shellcheck source=bin/lib/alfred.sh
    source "$REAL_DOTFILES_DIR/bin/lib/alfred.sh"
    run alfred_package_workflow "$REAL_DOTFILES_DIR/alfred/workflows/wt" '/Users/a&b/<dots>' "$TEST_HOME/w.alfredworkflow"
    assert_success
    run read_package "$TEST_HOME/w.alfredworkflow"
    assert_success
    [ "${lines[0]}" = '/Users/a&b/<dots>' ]
}

@test "workflow connects every modifier to the action object" {
    run python3 -I -c '
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
uids = {o["type"]: o["uid"] for o in p["objects"]}
sf = uids["alfred.workflow.input.scriptfilter"]
act = uids["alfred.workflow.action.script"]
conns = p["connections"][sf]
assert {c["destinationuid"] for c in conns} == {act}
print(sorted(c["modifiers"] for c in conns))
print(p["objects"][0]["config"]["keyword"])
' "$REAL_DOTFILES_DIR/alfred/workflows/wt/info.plist"
    assert_success
    [ "${lines[0]}" = "[0, 524288, 1048576]" ]
    [ "${lines[1]}" = "wt" ]
}

# --- adversarial cases ---

@test "list skips a nested worktree dir without .git" {
    create_repo "$DEV_DIR/alpha"
    git -C "$DEV_DIR/alpha" worktree add --quiet "$DEV_DIR/alpha/.worktrees/real" -b feat/real
    mkdir -p "$DEV_DIR/alpha/.worktrees/plain/sub"

    run alfred-wt list
    assert_success
    printf '%s' "$output" | jq -e . >/dev/null
    [ "$(jq '.items | length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '.items[0].title' <<<"$output")" = "alpha/real" ]
}

@test "list shows a detached HEAD worktree as (detached)" {
    create_repo "$DEV_DIR/alpha"
    git -C "$DEV_DIR/alpha" worktree add --quiet --detach "$DEV_DIR/alpha/.worktrees/det"
    create_repo "$SCAN/src/bravo"
    git -C "$SCAN/src/bravo" worktree add --quiet --detach "$T3_WORKTREES_DIR/bravo/t3-det"

    run alfred-wt list
    assert_success
    printf '%s' "$output" | jq -e . >/dev/null
    [ "$(jq '.items | length' <<<"$output")" -eq 2 ]
    [ "$(jq -r --arg p "$DEV_DIR/alpha/.worktrees/det" '.items[] | select(.arg == $p) | .match' <<<"$output")" = "alpha det (detached)" ]
    [ "$(jq -r --arg p "$T3_WORKTREES_DIR/bravo/t3-det" '.items[] | select(.arg == $p) | .match' <<<"$output")" = "bravo t3-det (detached)" ]
}

@test "list skips T3 root entries that are plain dirs without .git" {
    mkdir -p "$T3_WORKTREES_DIR/bravo/plain/inner" "$T3_WORKTREES_DIR/lonely"
    : > "$T3_WORKTREES_DIR/bravo/stray-file"

    run alfred-wt list
    assert_success
    printf '%s' "$output" | jq -e . >/dev/null
    [ "$(jq '.items | length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '.items[0].title' <<<"$output")" = "No worktrees found" ]
}

@test "list does not abbreviate a HOME-prefix lookalike path with ~" {
    export DEV_DIR="$HOME-other/Dev"
    mkdir -p "$DEV_DIR"
    create_repo "$DEV_DIR/alpha"
    git -C "$DEV_DIR/alpha" worktree add --quiet "$DEV_DIR/alpha/.worktrees/x" -b feat/x

    run alfred-wt list
    assert_success
    printf '%s' "$output" | jq -e . >/dev/null
    local sub
    sub="$(jq -r '.items[0].subtitle' <<<"$output")"
    [[ "$sub" == *" · $HOME-other/Dev/alpha/.worktrees/x" ]]
    [[ "$sub" != *"~"* ]]
    rm -rf "$HOME-other"
}

@test "list keeps valid JSON for spaces, quotes in branch, and unicode" {
    create_repo "$DEV_DIR/al pha"
    git -C "$DEV_DIR/al pha" worktree add --quiet "$DEV_DIR/al pha/.worktrees/café ü" -b 'feat/q"x&y'

    run alfred-wt list
    assert_success
    printf '%s' "$output" | jq -e . >/dev/null
    [ "$(jq -r '.items[0].arg' <<<"$output")" = "$DEV_DIR/al pha/.worktrees/café ü" ]
    [[ "$(jq -r '.items[0].subtitle' <<<"$output")" == 'feat/q"x&y ('* ]]
}

@test "list emits valid JSON when the roots contain quotes and backslashes" {
    export DEV_DIR='/nonexistent/q"d\e' T3_WORKTREES_DIR='/nonexistent/t"3\x'
    run alfred-wt list
    assert_success
    printf '%s' "$output" | jq -e . >/dev/null
    [ "$(jq -r '.items[0].subtitle' <<<"$output")" = 'Searched /nonexistent/q"d\e and /nonexistent/t"3\x' ]
}

@test "open rejects a wrong argument count with exit 2 and no side effects" {
    mkdir -p "$SCAN/wt"
    run alfred-wt open
    [ "$status" -eq 2 ]
    run alfred-wt open zed
    [ "$status" -eq 2 ]
    run alfred-wt open zed "$SCAN/wt" extra
    [ "$status" -eq 2 ]
    [ ! -e "$CALLS" ]
}

@test "session rejects a wrong argument count with exit 2" {
    run alfred-wt session
    [ "$status" -eq 2 ]
    run alfred-wt session a b
    [ "$status" -eq 2 ]
    [ ! -e "$CALLS" ]
}

@test "no command and unknown command exit 2 with usage on stderr" {
    run alfred-wt
    [ "$status" -eq 2 ]
    run alfred-wt bogus
    [ "$status" -eq 2 ]
    run alfred-wt --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"alfred-wt"* ]]
}

@test "open copy handles a path with spaces and a non-directory file" {
    mkdir -p "$SCAN/w t"
    run alfred-wt open copy "$SCAN/w t"
    assert_success
    [ "$(cat "$CALLS")" = "pbcopy $SCAN/w t" ]
    : > "$SCAN/file"
    run alfred-wt open copy "$SCAN/file"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 1 ]
}

@test "install fails when info.plist is missing and builds nothing" {
    # shellcheck source=bin/lib/alfred.sh
    source "$REAL_DOTFILES_DIR/bin/lib/alfred.sh"
    mkdir -p "$TEST_HOME/emptysrc"
    run alfred_package_workflow "$TEST_HOME/emptysrc" /x "$TEST_HOME/w.alfredworkflow"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no info.plist"* ]]
    [ ! -e "$TEST_HOME/w.alfredworkflow" ]
}

@test "packaging keeps backslashes and ampersand sequences in the path literal" {
    # shellcheck source=bin/lib/alfred.sh
    source "$REAL_DOTFILES_DIR/bin/lib/alfred.sh"
    run alfred_package_workflow "$REAL_DOTFILES_DIR/alfred/workflows/wt" '/Users/a\n\\b/&amp;/x' "$TEST_HOME/w.alfredworkflow"
    assert_success
    run read_package "$TEST_HOME/w.alfredworkflow"
    assert_success
    [ "${lines[0]}" = '/Users/a\n\\b/&amp;/x' ]
}

@test "packaging fails and leaves no output when the output dir is missing" {
    # shellcheck source=bin/lib/alfred.sh
    source "$REAL_DOTFILES_DIR/bin/lib/alfred.sh"
    run alfred_package_workflow "$REAL_DOTFILES_DIR/alfred/workflows/wt" /x "$TEST_HOME/nodir/w.alfredworkflow"
    [ "$status" -ne 0 ]
    [ ! -e "$TEST_HOME/nodir/w.alfredworkflow" ]
}
