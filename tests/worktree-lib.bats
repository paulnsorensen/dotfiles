#!/usr/bin/env bats
# Tests for bin/lib/worktree.sh — the shared worktree helpers used by
# ccw-sweep (nested detection) and ccw-find (cross-repo search).
#
# WHY these matter: wt_child_blocks_removal is the predicate that stops
# ccw-sweep from deleting a parent worktree that nests unmerged/dirty work.
# A false "doesn't block" here means real, unpushed work gets destroyed —
# so every blocking condition (dirty / staged / untracked / unmerged) gets
# a test, plus the clean-and-merged negative case.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
  source "$DOTFILES_DIR/bin/lib/worktree.sh"
  SCAN=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wtlib.XXXXXX")" && pwd)
}

teardown() {
  [[ -n "${SCAN:-}" ]] || return 0
  rm -rf "$SCAN"
}

# Origin-backed repo so origin/HEAD resolves (resolve_default_branch +
# the unmerged check both key off origin/<default>).
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

# ── resolve_default_branch ───────────────────────────────────────────

@test "resolve_default_branch reads origin/HEAD" {
  create_repo "$SCAN/repo"
  run resolve_default_branch "$SCAN/repo"
  [[ $status -eq 0 ]]
  [[ "$output" == "main" ]]
}

@test "resolve_default_branch resolves a non-main default" {
  create_repo "$SCAN/repo" "master"
  run resolve_default_branch "$SCAN/repo"
  [[ "$output" == "master" ]]
}

@test "resolve_default_branch fails when no remote default resolves" {
  mkdir -p "$SCAN/bare"
  git -C "$SCAN/bare" init -b main --quiet
  git -C "$SCAN/bare" config user.email t@t.com
  git -C "$SCAN/bare" config user.name T
  echo x > "$SCAN/bare/f"; git -C "$SCAN/bare" add f; git -C "$SCAN/bare" commit -m i --quiet
  run resolve_default_branch "$SCAN/bare"
  [[ $status -eq 1 ]]
  [[ -z "$output" ]]
}

# ── wt_list_nested ───────────────────────────────────────────────────

@test "wt_list_nested finds children under .worktrees" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "parent"
  local parent="$SCAN/repo/.worktrees/parent"
  git -C "$parent" worktree add "$parent/.worktrees/childA" -b claude/childA --quiet 2>/dev/null

  run wt_list_nested "$parent"
  [[ $status -eq 0 ]]
  [[ "$output" == *".worktrees/childA"* ]]
}

@test "wt_list_nested emits nothing when there are no nested worktrees" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "lonely"
  run wt_list_nested "$SCAN/repo/.worktrees/lonely"
  [[ $status -eq 0 ]]
  [[ -z "$output" ]]
}

@test "wt_list_nested ignores a non-worktree dir without .git" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "parent"
  mkdir -p "$SCAN/repo/.worktrees/parent/.worktrees/notawt"
  run wt_list_nested "$SCAN/repo/.worktrees/parent"
  [[ -z "$output" ]]
}

# ── wt_child_blocks_removal ──────────────────────────────────────────

@test "wt_child_blocks_removal: clean merged child does NOT block" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "clean"
  run wt_child_blocks_removal "$SCAN/repo/.worktrees/clean"
  [[ $status -eq 1 ]]
}

@test "wt_child_blocks_removal: uncommitted changes block" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "dirty"
  echo "wip" >> "$SCAN/repo/.worktrees/dirty/README.md"
  run wt_child_blocks_removal "$SCAN/repo/.worktrees/dirty"
  [[ $status -eq 0 ]]
}

@test "wt_child_blocks_removal: staged changes block" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "staged"
  echo "new" > "$SCAN/repo/.worktrees/staged/new.txt"
  git -C "$SCAN/repo/.worktrees/staged" add new.txt
  run wt_child_blocks_removal "$SCAN/repo/.worktrees/staged"
  [[ $status -eq 0 ]]
}

@test "wt_child_blocks_removal: untracked files block" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "untracked"
  echo "scratch" > "$SCAN/repo/.worktrees/untracked/scratch.txt"
  run wt_child_blocks_removal "$SCAN/repo/.worktrees/untracked"
  [[ $status -eq 0 ]]
}

@test "wt_child_blocks_removal: unmerged commits block" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "ahead"
  echo "feature" > "$SCAN/repo/.worktrees/ahead/feature.txt"
  git -C "$SCAN/repo/.worktrees/ahead" add feature.txt
  git -C "$SCAN/repo/.worktrees/ahead" commit -m "feature" --quiet
  run wt_child_blocks_removal "$SCAN/repo/.worktrees/ahead"
  [[ $status -eq 0 ]]
}

# ── wt_find ──────────────────────────────────────────────────────────

@test "wt_find by slug substring returns the matching worktree path" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "alpha-feature"
  add_worktree "$SCAN/repo" "beta-fix"
  run wt_find --root "$SCAN" --slug alpha
  [[ $status -eq 0 ]]
  [[ "$output" == *"alpha-feature"* ]]
  [[ "$output" != *"beta-fix"* ]]
}

@test "wt_find by branch substring matches the worktree HEAD branch" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "wt1" "feat/login"
  add_worktree "$SCAN/repo" "wt2" "fix/logout"
  run wt_find --root "$SCAN" --branch login
  [[ "$output" == *"wt1"* ]]
  [[ "$output" != *"wt2"* ]]
}

@test "wt_find by repo name restricts to that repo" {
  create_repo "$SCAN/alpha"
  create_repo "$SCAN/bravo"
  add_worktree "$SCAN/alpha" "a-wt"
  add_worktree "$SCAN/bravo" "b-wt"
  run wt_find --root "$SCAN" --repo bravo
  [[ "$output" == *"b-wt"* ]]
  [[ "$output" != *"a-wt"* ]]
}

@test "wt_find emits path TAB status with branch and age" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "wt1" "claude/wt1"
  run wt_find --root "$SCAN" --slug wt1
  [[ "$output" == *"$SCAN/repo/.worktrees/wt1	claude/wt1 ("* ]]
}

@test "wt_find --stale excludes fresh worktrees" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "fresh"
  # Just committed, so 1-day staleness window must exclude it.
  run wt_find --root "$SCAN" --stale 1
  [[ -z "$output" ]]
}

# Positive complement to the exclude case above: a worktree whose last commit
# is older than the window MUST be returned. Without this, a --stale filter
# that always emitted nothing would still pass "excludes fresh".
@test "wt_find --stale includes a worktree older than the window" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "ancient"
  local old_epoch=$(( $(date +%s) - 30 * 86400 ))
  GIT_AUTHOR_DATE="@${old_epoch} +0000" GIT_COMMITTER_DATE="@${old_epoch} +0000" \
    git -C "$SCAN/repo/.worktrees/ancient" commit --allow-empty -m "old" --quiet
  run wt_find --root "$SCAN" --stale 7
  [[ $status -eq 0 ]]
  [[ "$output" == *"ancient"* ]]
}

# Criteria AND together (spec: "criteria AND together"). --slug matches both
# worktrees by substring; --branch narrows to one. An OR would return both —
# this locks the intersection.
@test "wt_find ANDs criteria: slug matches two, branch narrows to one" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "alpha-one" "feat/login"
  add_worktree "$SCAN/repo" "alpha-two" "fix/logout"
  run wt_find --root "$SCAN" --slug alpha --branch login
  [[ $status -eq 0 ]]
  [[ "$output" == *"alpha-one"* ]]
  [[ "$output" != *"alpha-two"* ]]
}

@test "wt_find returns nothing for a missing root" {
  run wt_find --root "/nonexistent/$$"
  [[ $status -eq 0 ]]
  [[ -z "$output" ]]
}

# A non-numeric --stale must fail loud, not be silently coerced to 0 (which
# would disable the stale filter and quietly return every worktree).
@test "wt_find --stale rejects a non-numeric value" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "alpha"
  run wt_find --root "$SCAN" --stale soon
  [[ $status -eq 2 ]]
  [[ "$output" == *"--stale expects a number"* ]]
  [[ "$output" != *"alpha"* ]]
}
