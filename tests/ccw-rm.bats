#!/usr/bin/env bats
# Tests for bin/ccw-rm — one-step worktree teardown.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
    TMPROOT="$(mktemp -d)"
    REPO="$TMPROOT/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@t.test
    git -C "$REPO" config user.name tester
    git -C "$REPO" commit --allow-empty -q -m init
    git -C "$REPO" worktree add -q "$REPO/.worktrees/feat" -b worktree/feat

    # Deterministic tmux stub: report no session so no kill is attempted.
    STUB="$TMPROOT/stub"
    mkdir -p "$STUB"
    cat >"$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$STUB/tmux"
    export PATH="$STUB:$DOTFILES_DIR/bin:$PATH"
}

teardown() {
    rm -rf "$TMPROOT"
}

@test "usage error with no slug" {
    run ccw-rm
    [ "$status" -ne 0 ]
    [[ "$output" == *Usage* ]]
}

@test "errors when the worktree does not exist" {
    cd "$REPO"
    run ccw-rm nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no worktree"* ]]
}

@test "removes the worktree and its branch" {
    cd "$REPO"
    run ccw-rm feat
    [ "$status" -eq 0 ]
    [ ! -d "$REPO/.worktrees/feat" ]
    run git -C "$REPO" show-ref --verify --quiet refs/heads/worktree/feat
    [ "$status" -ne 0 ]
}

@test "refuses a dirty worktree without --force" {
    cd "$REPO"
    echo dirty >"$REPO/.worktrees/feat/untracked.txt"
    run ccw-rm feat
    [ "$status" -ne 0 ]
    [ -d "$REPO/.worktrees/feat" ]
}

@test "--force discards a dirty worktree" {
    cd "$REPO"
    echo dirty >"$REPO/.worktrees/feat/untracked.txt"
    run ccw-rm feat --force
    [ "$status" -eq 0 ]
    [ ! -d "$REPO/.worktrees/feat" ]
}

@test "refuses a parent worktree with a nested child, even with --force" {
    printf '.worktrees/\n' >>"$REPO/.git/info/exclude"
    git -C "$REPO/.worktrees/feat" worktree add -q "$REPO/.worktrees/feat/.worktrees/child" -b worktree/child
    touch "$REPO/.worktrees/feat/.worktrees/child/precious"
    cd "$REPO"
    run ccw-rm feat --force
    [ "$status" -ne 0 ]
    [[ "$output" == *"nested worktrees"* ]]
    [[ "$output" == *"ccw-rm child"* ]]
    [ -f "$REPO/.worktrees/feat/.worktrees/child/precious" ]
    run git -C "$REPO" show-ref --verify --quiet refs/heads/worktree/feat
    [ "$status" -eq 0 ]
}

@test "removes a nested worktree from inside its parent" {
    git -C "$REPO/.worktrees/feat" worktree add -q "$REPO/.worktrees/feat/.worktrees/child" -b worktree/child
    cd "$REPO/.worktrees/feat"
    run ccw-rm child
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed worktree: $(cd -P "$REPO" && pwd)/.worktrees/feat/.worktrees/child"* ]]
    [ ! -d "$REPO/.worktrees/feat/.worktrees/child" ]
    run git -C "$REPO" show-ref --verify --quiet refs/heads/worktree/child
    [ "$status" -ne 0 ]
}

@test "refuses a nested child registered outside .worktrees, with and without --force" {
    local child="$REPO/.worktrees/feat/.claude/worktrees/odd"
    git -C "$REPO/.worktrees/feat" worktree add -q "$child" -b worktree/odd
    touch "$child/precious"
    cd "$REPO"
    run ccw-rm feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"nested worktrees"* ]]
    run ccw-rm feat --force
    [ "$status" -ne 0 ]
    [[ "$output" == *"nested worktrees"* ]]
    [ -f "$child/precious" ]
    [ -d "$REPO/.worktrees/feat" ]
}

@test "nested hint quotes paths that contain spaces" {
    git -C "$REPO" worktree add -q "$REPO/.worktrees/my feat" -b worktree/myfeat
    git -C "$REPO/.worktrees/my feat" worktree add -q "$REPO/.worktrees/my feat/.worktrees/child" -b worktree/child
    cd "$REPO"
    run ccw-rm "my feat"
    [ "$status" -ne 0 ]
    [[ "$output" == *'my\ feat'* ]]
}
