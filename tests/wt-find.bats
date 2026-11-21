#!/usr/bin/env bats
# Tests for bin/wt-find — the thin CLI over wt_find (bin/lib/worktree.sh).
# Covers flag parsing, the no-criteria error, and that each criterion
# (slug / branch / repo / stale) reaches the search.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"

setup() {
  SCAN=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ccwfind.XXXXXX")" && pwd)
}

teardown() {
  [[ -n "${SCAN:-}" ]] || return 0
  rm -rf "$SCAN"
}

create_repo() {
  local dir="$1" default="${2:-main}"
  mkdir -p "$dir"
  git -C "$dir" init -b "$default" --quiet
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  echo "init" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -m "initial" --quiet
  local origin="${dir}.origin.git"
  git init --bare -b "$default" --quiet "$origin"
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push --quiet origin "$default"
  git -C "$dir" remote set-head origin "$default"
}

add_worktree() {
  local repo="$1" slug="$2" branch="${3:-claude/$2}"
  mkdir -p "$repo/.worktrees"
  git -C "$repo" worktree add "$repo/.worktrees/$slug" -b "$branch" --quiet 2>/dev/null
}

@test "wt-find with no criteria exits non-zero" {
  run wt-find
  [[ $status -ne 0 ]]
  [[ "$output" == *"no criteria"* ]]
}

@test "wt-find --help prints usage" {
  run wt-find --help
  [[ $status -eq 0 ]]
  [[ "$output" == *"locate worktrees"* ]]
}

@test "wt-find --slug returns the matching path" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "alpha-feature"
  add_worktree "$SCAN/repo" "beta-fix"

  run wt-find --root "$SCAN" --slug alpha
  [[ $status -eq 0 ]]
  [[ "$output" == *"alpha-feature"* ]]
  [[ "$output" != *"beta-fix"* ]]
}

@test "wt-find --branch matches the worktree HEAD branch" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "wt1" "feat/login"
  add_worktree "$SCAN/repo" "wt2" "fix/logout"

  run wt-find --root "$SCAN" --branch login
  [[ "$output" == *"wt1"* ]]
  [[ "$output" != *"wt2"* ]]
}

@test "wt-find --repo restricts to that repo" {
  create_repo "$SCAN/alpha"
  create_repo "$SCAN/bravo"
  add_worktree "$SCAN/alpha" "a-wt"
  add_worktree "$SCAN/bravo" "b-wt"

  run wt-find --root "$SCAN" --repo bravo
  [[ "$output" == *"b-wt"* ]]
  [[ "$output" != *"a-wt"* ]]
}

@test "wt-find emits path TAB status" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "wt1" "claude/wt1"

  run wt-find --root "$SCAN" --slug wt1
  [[ "$output" == *"$SCAN/repo/.worktrees/wt1	claude/wt1 ("* ]]
}

@test "wt-find rejects an unknown flag" {
  run wt-find --bogus x
  [[ $status -ne 0 ]]
}
