#!/usr/bin/env bats
# Tests for bin/cc-session-name — collision-safe tmux session naming.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"

@test "worktree path -> <repo>-<slug>" {
    run cc-session-name "/home/u/Dev/myrepo/.worktrees/add-auth"
    [ "$status" -eq 0 ]
    [ "$output" = "myrepo-add-auth" ]
}

@test "dots and colons in the name become hyphens" {
    run cc-session-name "/home/u/Dev/repo.js/.worktrees/fix"
    [ "$output" = "repo-js-fix" ]
}

@test "nested worktree uses the immediate parent worktree + slug" {
    run cc-session-name "/home/u/Dev/dotfiles/.worktrees/workflows/.worktrees/shortcuts"
    [ "$output" = "workflows-shortcuts" ]
}

@test "trailing slash is ignored" {
    run cc-session-name "/home/u/Dev/myrepo/.worktrees/add-auth/"
    [ "$output" = "myrepo-add-auth" ]
}

@test "git repo dir -> toplevel basename" {
    local parent repo
    parent="$(mktemp -d)"
    repo="$parent/cleanrepo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    run cc-session-name "$repo"
    [ "$output" = "cleanrepo" ]
    rm -rf "$parent"
}

@test "subdir of a repo collapses to the repo name" {
    local parent repo
    parent="$(mktemp -d)"
    repo="$parent/cleanrepo"
    mkdir -p "$repo/src/deep"
    git -C "$repo" init -q
    run cc-session-name "$repo/src/deep"
    [ "$output" = "cleanrepo" ]
    rm -rf "$parent"
}

@test "subdir of a worktree collapses to <repo>-<slug>" {
    local parent repo
    parent="$(mktemp -d)"
    repo="$parent/cleanrepo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email t@t.test
    git -C "$repo" config user.name tester
    git -C "$repo" commit --allow-empty -q -m init
    git -C "$repo" worktree add -q "$repo/.worktrees/add-auth" -b claude/add-auth
    mkdir -p "$repo/.worktrees/add-auth/src/deep"
    run cc-session-name "$repo/.worktrees/add-auth/src/deep"
    [ "$output" = "cleanrepo-add-auth" ]
    rm -rf "$parent"
}

@test "non-git dir -> basename" {
    local parent dir
    parent="$(mktemp -d)"
    dir="$parent/plain-dir"
    mkdir -p "$dir"
    run cc-session-name "$dir"
    [ "$output" = "plain-dir" ]
    rm -rf "$parent"
}

@test "--unique returns the base name when no session owns it" {
    local bindir parent repo
    bindir="$(mktemp -d)"
    cat > "$bindir/tmux" <<'EOF'
#!/usr/bin/env bash
# has-session always fails -> nothing is taken
exit 1
EOF
    chmod +x "$bindir/tmux"
    parent="$(mktemp -d)"; repo="$parent/cleanrepo"
    mkdir -p "$repo"; git -C "$repo" init -q
    PATH="$bindir:$PATH" run cc-session-name --unique "$repo"
    [ "$status" -eq 0 ]
    [ "$output" = "cleanrepo" ]
    rm -rf "$parent" "$bindir"
}

@test "--unique appends the lowest free -N suffix when sessions are taken" {
    local bindir parent repo
    bindir="$(mktemp -d)"
    cat > "$bindir/tmux" <<'EOF'
#!/usr/bin/env bash
# "cleanrepo" and "cleanrepo-2" are taken; "cleanrepo-3" is free.
[[ "$1" == has-session ]] || exit 0
case "$3" in
  "=cleanrepo"|"=cleanrepo-2") exit 0 ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "$bindir/tmux"
    parent="$(mktemp -d)"; repo="$parent/cleanrepo"
    mkdir -p "$repo"; git -C "$repo" init -q
    PATH="$bindir:$PATH" run cc-session-name --unique "$repo"
    [ "$status" -eq 0 ]
    [ "$output" = "cleanrepo-3" ]
    rm -rf "$parent" "$bindir"
}
