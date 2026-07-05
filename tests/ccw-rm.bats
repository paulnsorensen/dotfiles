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
    git -C "$REPO" worktree add -q "$REPO/.worktrees/feat" -b claude/feat

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
    run git -C "$REPO" show-ref --verify --quiet refs/heads/claude/feat
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
