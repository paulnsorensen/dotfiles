#!/usr/bin/env bats
# Tests for ccw-sweep — worktree scanning and cleanup
#
# Bug fixes validated:
# 1. stdin hijacking: read prompts inside while-read loop consumed find output,
#    causing repos to be silently skipped. Fix: fd3 for loop, /dev/tty for prompts.
# 2. ((0++)) with set -e: post-increment of zero returns exit 1, killing script.
#    Fix: var=$((var + 1)) instead.
#
# Note: the stdin regression (WARN/DIRTY prompts eating loop data) can't be
# directly tested in bats because read </dev/tty blocks in interactive sessions.
# It's validated by code inspection and by the multi-repo discovery tests below
# (which prove the fd3 loop iterates correctly).

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"

# ── Helpers ───────────────────────────────────────────────────────────

strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

assert_success() {
  [[ $status -eq 0 ]] || {
    echo "Expected success (status=$status)"
    echo "Output: $output"
    return 1
  }
}

assert_contains() {
  local clean
  clean=$(strip_ansi "${2:-$output}")
  [[ "$clean" == *"$1"* ]] || {
    echo "Missing: $1"
    echo "Got: $clean"
    return 1
  }
}

assert_not_contains() {
  local clean
  clean=$(strip_ansi "${2:-$output}")
  [[ "$clean" != *"$1"* ]] || {
    echo "Unwanted: $1"
    echo "Got: $clean"
    return 1
  }
}

# Create a git repo with main branch and initial commit
create_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -b main --quiet 2>/dev/null || {
    git -C "$dir" init --quiet
    git -C "$dir" checkout -b main --quiet 2>/dev/null || true
  }
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  echo "init" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -m "initial" --quiet
}

# Add a SAFE worktree (identical to main)
add_safe_worktree() {
  local repo="$1" slug="$2"
  mkdir -p "$repo/.worktrees"
  git -C "$repo" worktree add "$repo/.worktrees/$slug" -b "claude/$slug" --quiet 2>/dev/null
}

# Add a WARN worktree (has commits not merged into main)
add_diverged_worktree() {
  local repo="$1" slug="$2"
  mkdir -p "$repo/.worktrees"
  git -C "$repo" worktree add "$repo/.worktrees/$slug" -b "claude/$slug" --quiet 2>/dev/null
  echo "extra" > "$repo/.worktrees/$slug/diverged.txt"
  git -C "$repo/.worktrees/$slug" add diverged.txt
  git -C "$repo/.worktrees/$slug" commit -m "diverge" --quiet
}

setup() {
  SCAN=$(mktemp -d)
  # Isolate HOME so remove_worktree doesn't touch real ~/.claude
  ORIGINAL_HOME="$HOME"
  HOME=$(mktemp -d)
  export HOME
}

teardown() {
  rm -rf "$SCAN" "$HOME"
  export HOME="$ORIGINAL_HOME"
}

# ── Discovery (dry-run) ──────────────────────────────────────────────

@test "discovers worktrees across multiple repos" {
  create_repo "$SCAN/alpha"
  create_repo "$SCAN/bravo"
  create_repo "$SCAN/charlie"
  add_safe_worktree "$SCAN/alpha" "task-a"
  add_safe_worktree "$SCAN/bravo" "task-b"
  add_safe_worktree "$SCAN/charlie" "task-c"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "alpha"
  assert_contains "bravo"
  assert_contains "charlie"
  assert_contains "task-a"
  assert_contains "task-b"
  assert_contains "task-c"
}

@test "shows correct total in summary" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "wt1"
  add_safe_worktree "$SCAN/repo" "wt2"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "Total:   2"
}

@test "labels SAFE and WARN correctly" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "merged"
  add_diverged_worktree "$SCAN/repo" "diverged"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "[SAFE]"
  assert_contains "[WARN]"
}

@test "discovers mixed-status worktrees across repos" {
  create_repo "$SCAN/repo1"
  create_repo "$SCAN/repo2"
  add_diverged_worktree "$SCAN/repo1" "unmerged"
  add_safe_worktree "$SCAN/repo2" "clean"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "repo1"
  assert_contains "repo2"
  assert_contains "unmerged"
  assert_contains "clean"
}

# ── Auto-clean ────────────────────────────────────────────────────────

@test "auto removes SAFE worktrees across multiple repos" {
  create_repo "$SCAN/repo1"
  create_repo "$SCAN/repo2"
  create_repo "$SCAN/repo3"
  add_safe_worktree "$SCAN/repo1" "t1"
  add_safe_worktree "$SCAN/repo2" "t2"
  add_safe_worktree "$SCAN/repo3" "t3"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "Removed: 3"
}

@test "auto removes worktree directory and branch" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "doomed"

  [[ -d "$SCAN/repo/.worktrees/doomed" ]]
  git -C "$SCAN/repo" rev-parse --verify "claude/doomed" &>/dev/null

  run ccw-sweep --auto --path "$SCAN"
  assert_success

  [[ ! -d "$SCAN/repo/.worktrees/doomed" ]] || {
    echo "worktree dir still exists"
    return 1
  }
  ! git -C "$SCAN/repo" rev-parse --verify "claude/doomed" &>/dev/null || {
    echo "branch still exists"
    return 1
  }
}

@test "dry-run does not remove anything" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "keep-me"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success

  [[ -d "$SCAN/repo/.worktrees/keep-me" ]] || {
    echo "removed during dry-run!"
    return 1
  }
}

# ── Regression: arithmetic with set -e ────────────────────────────────
# ((FOUND_REPOS++)) when 0 evaluates to ((0)) -> exit 1.
# With set -e this kills the script on the very first repo.

@test "does not crash on first repo (arithmetic regression)" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "first"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "repo"
  assert_contains "first"
}

@test "processes many worktrees in one repo" {
  create_repo "$SCAN/repo"
  for i in $(seq 1 5); do
    add_safe_worktree "$SCAN/repo" "wt-$i"
  done

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "Removed: 5"
}

# ── Edge cases ────────────────────────────────────────────────────────

@test "no worktrees found exits cleanly" {
  mkdir -p "$SCAN"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "No worktrees found"
}

@test "missing path exits with error" {
  run ccw-sweep --path "/nonexistent/$$"
  [[ $status -ne 0 ]]
  assert_contains "Directory not found"
}

@test "skips non-git directories with .worktrees" {
  mkdir -p "$SCAN/not-a-repo/.worktrees/fake"
  touch "$SCAN/not-a-repo/.worktrees/fake/.git"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "No worktrees found"
}

@test "skips empty .worktrees directory" {
  create_repo "$SCAN/repo"
  mkdir -p "$SCAN/repo/.worktrees"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "No worktrees found"
}

@test "runs git worktree prune after removals" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "prunable"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "worktree prune"
}
