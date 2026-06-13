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

# Create a git repo with the given default branch (default: main), an
# initial commit, and a bare origin. ccw-sweep resolves the default branch
# from refs/remotes/origin/HEAD and checks merge state against
# origin/<default>; a remote-less repo is (correctly) skipped, so the
# fixtures MUST be origin-backed to exercise the worktree-checking path.
# The bare origin is a sibling dir with no .worktrees, so ccw-sweep's
# discovery never treats it as a scannable repo.
create_repo() {
  local dir="$1" default="${2:-main}"
  mkdir -p "$dir"
  git -C "$dir" init -b "$default" --quiet 2>/dev/null || {
    git -C "$dir" init --quiet
    git -C "$dir" checkout -b "$default" --quiet 2>/dev/null || true
  }
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  echo "init" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -m "initial" --quiet

  local origin="${dir}.origin.git"
  git init --bare -b "$default" --quiet "$origin"
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push --quiet origin "$default"   # updates refs/remotes/origin/<default>
  git -C "$dir" remote set-head origin "$default" # writes refs/remotes/origin/HEAD
}

# Create a git repo + worktree with NO origin remote, to prove ccw-sweep
# skips repos whose default branch cannot be resolved rather than running
# merge checks against a nonexistent ref (the false-positive-deletion guard).
create_repo_no_origin() {
  local dir="$1" slug="$2"
  mkdir -p "$dir"
  git -C "$dir" init -b main --quiet
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  echo "init" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -m "initial" --quiet
  mkdir -p "$dir/.worktrees"
  git -C "$dir" worktree add "$dir/.worktrees/$slug" -b "claude/$slug" --quiet 2>/dev/null
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
  # Fixtures are now origin-backed (create_repo provisions a bare origin and
  # sets origin/HEAD), so the default-branch resolution that ccw-sweep relies
  # on works without network or repo-specific config — the tests run in CI.
  #
  # SCAN/HOME must be ABSOLUTE: every helper uses `git -C "$repo" …` with a
  # path derived from SCAN, and a relative remote/worktree URL resolves
  # against $repo (not the CWD), which silently breaks. CI has no TMPDIR, so
  # mktemp's "." fallback would yield relative paths — pwd-resolve to absolute.
  SCAN=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ccw-scan.XXXXXX")" && pwd)
  # Isolate HOME so remove_worktree doesn't touch real ~/.claude
  ORIGINAL_HOME="$HOME"
  HOME=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ccw-home.XXXXXX")" && pwd)
  export HOME
}

teardown() {
  # bats runs teardown even if setup() errored before creating the fixtures.
  # Guard against that: without SCAN/ORIGINAL_HOME set, the rm below would
  # target the real $HOME (SCAN="") and wipe it.
  [[ -n "${SCAN:-}" && -n "${ORIGINAL_HOME:-}" ]] || return 0
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

# ── Default-branch resolution (false-positive-deletion guard) ─────────
# These exercise resolve_default_branch via the "default: <branch>" log
# line and the skip banner. The merge logic now keys off origin/<default>,
# so getting the default wrong (or running against a missing ref) is the
# exact failure mode that previously caused false-positive deletions.

@test "resolves default branch from origin/HEAD" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "wt"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "default: main"
  assert_contains "[SAFE]"
}

@test "resolves a non-main default branch" {
  create_repo "$SCAN/repo" "master"
  add_safe_worktree "$SCAN/repo" "wt"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "default: master"
  # Merged against origin/master — must read SAFE, not a false NOT-merged.
  assert_contains "[SAFE]"
  assert_not_contains "NOT merged"
}

@test "falls back to probing origin/<branch> when origin/HEAD is unset" {
  create_repo "$SCAN/repo" "master"
  add_safe_worktree "$SCAN/repo" "wt"
  # Drop origin/HEAD so resolution must fall through to the main/master/… probe.
  git -C "$SCAN/repo" symbolic-ref -d refs/remotes/origin/HEAD

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "default: master"
  assert_contains "[SAFE]"
}

@test "skips a repo whose default branch cannot be resolved" {
  create_repo_no_origin "$SCAN/repo" "orphan"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "could not resolve a remote default branch"
  # The worktree must NOT be evaluated — skipping protects unmerged work.
  assert_not_contains "[SAFE]"
  assert_not_contains "[WARN]"
}

# ── Regression: --auto must never prompt ──────────────────────────────
# --auto used to fall through to `read … </dev/tty` for WARN/DIRTY
# worktrees, crashing in non-interactive sessions (no TTY → unbound
# variable under set -u) before any later SAFE worktree was reached.
# --auto now skips non-SAFE worktrees outright.

@test "auto skips WARN worktrees without prompting" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "diverged"
  add_safe_worktree "$SCAN/repo" "clean"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "Removed: 1"
  assert_contains "Skipped: 1"
  [[ -d "$SCAN/repo/.worktrees/diverged" ]] || {
    echo "WARN worktree was removed under --auto"
    return 1
  }
}

@test "auto skips DIRTY worktrees without prompting" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "dirty"
  echo "wip" >> "$SCAN/repo/.worktrees/dirty/README.md"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "Skipped: 1"
  [[ -d "$SCAN/repo/.worktrees/dirty" ]] || {
    echo "DIRTY worktree was removed under --auto"
    return 1
  }
}

# ── Regression: branch read from worktree HEAD, not dir name ──────────
# The branch used to be guessed as claude/<dir-name>, so a worktree on a
# differently-named branch was flagged "branch not found" and its
# branch-based checks (merged-list, PR lookup) ran against a nonexistent ref.

@test "reads worktree branch from HEAD when dir name differs" {
  create_repo "$SCAN/repo"
  mkdir -p "$SCAN/repo/.worktrees"
  git -C "$SCAN/repo" worktree add "$SCAN/repo/.worktrees/short-name" \
    -b "feat/completely-different" --quiet 2>/dev/null

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_not_contains "branch not found"
  assert_contains "[SAFE]"
}

@test "flags detached-HEAD worktree as such" {
  create_repo "$SCAN/repo"
  mkdir -p "$SCAN/repo/.worktrees"
  git -C "$SCAN/repo" worktree add --detach "$SCAN/repo/.worktrees/loose" --quiet 2>/dev/null

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "detached HEAD"
  assert_not_contains "branch not found"
}
