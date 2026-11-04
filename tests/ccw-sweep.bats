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

  # Fixture worktrees are seconds old; the existing cases expect --auto to
  # remove them, so drop the SAFE idle threshold for every test by default.
  export CCW_SWEEP_SAFE_IDLE_DAYS=0
  unset CCW_SWEEP_ARCHIVE_IDLE_DAYS CCW_SWEEP_RECLAIM_IDLE_DAYS CCW_SWEEP_NOW \
    CCW_SWEEP_REGENERABLE CCW_SWEEP_T3_ROOT CCW_SWEEP_CHEESE_ARCHIVE FAKE_GH_TSV
  # T3 state DB inside the temp HOME: absent unless a test creates it.
  export CCW_SWEEP_T3_DB="$HOME/.t3/userdata/state.sqlite"
  # Stub gh: fails (no PR info) unless FAKE_GH_TSV names a TSV file to print.
  mkdir -p "$HOME/stub-bin"
  # shellcheck disable=SC2016  # the stub expands FAKE_GH_TSV when it runs, not now
  printf '#!/usr/bin/env bash\n[[ -n "${FAKE_GH_TSV:-}" ]] || exit 1\ncat "$FAKE_GH_TSV"\n' > "$HOME/stub-bin/gh"
  chmod +x "$HOME/stub-bin/gh"
  export PATH="$HOME/stub-bin:$PATH"
  BG_PID=""
}

teardown() {
  [[ -n "${BG_PID:-}" ]] && kill "$BG_PID" 2>/dev/null || true
  # bats runs teardown even if setup() errored before creating the fixtures.
  # Guard against that: without SCAN/ORIGINAL_HOME set, the rm below would
  # target the real $HOME (SCAN="") and wipe it.
  [[ -n "${SCAN:-}" && -n "${ORIGINAL_HOME:-}" ]] || return 0
  # Fixtures include read-only dirs/files (e.g. .worktrees/old/target/locked).
  chmod -R u+w "$SCAN" "$HOME" 2>/dev/null || true
  rm -rf "$SCAN" "$HOME"
  export HOME="$ORIGINAL_HOME"
}

# exclude_in <worktree> <pattern>... — gitignore patterns for the whole repo
# (info/exclude lives in the shared git dir).
exclude_in() {
  local wt="$1"; shift
  printf '%s\n' "$@" >> "$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)"
}

# days_from_now <n> — epoch seconds n days in the future (for CCW_SWEEP_NOW).
days_from_now() { echo $(( $(date +%s) + $1 * 86400 )); }

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

# ── Nested-worktree safety (item B) ───────────────────────────────────
# A parent worktree that nests an unmerged/dirty child must NOT be removed
# under --auto — that would orphan the child's unpushed work. The gate must
# fire only when the nested child actually blocks (dirty or unmerged), so a
# clean merged child leaves the parent removable.

# Exclude .worktrees/.claude in the parent so hosting a nested worktree dir
# doesn't flip the parent to WARN (untracked) — mirrors the real repos, which
# gitignore .worktrees. Keeps the parent SAFE so the nested gate is what stops
# removal, not the parent's own status.
add_nested_child() {
  local parent="$1" slug="$2"
  printf '.worktrees/\n.claude/\n' > "$(git -C "$parent" rev-parse --git-path info/exclude)"
  git -C "$parent" worktree add "$parent/.worktrees/$slug" -b "claude/$slug" --quiet 2>/dev/null
}

@test "auto refuses to remove a parent nesting a DIRTY child" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "parent"
  local parent="$SCAN/repo/.worktrees/parent"
  add_nested_child "$parent" "child"
  echo "wip" >> "$parent/.worktrees/child/README.md"   # make the child dirty

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "nests unmerged/dirty"
  assert_contains "worktree move"
  assert_contains "Skipping removal"
  [[ -d "$parent" ]] || {
    echo "parent removed despite nested dirty child — work would be orphaned"
    return 1
  }
}

@test "auto refuses to remove a parent nesting an UNMERGED child" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "parent"
  local parent="$SCAN/repo/.worktrees/parent"
  add_nested_child "$parent" "child"
  # Commit in the child so it is ahead of origin/main but otherwise clean.
  echo "feature" > "$parent/.worktrees/child/feature.txt"
  git -C "$parent/.worktrees/child" add feature.txt
  git -C "$parent/.worktrees/child" commit -m "feature" --quiet

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "nests unmerged/dirty"
  [[ -d "$parent" ]] || {
    echo "parent removed despite nested unmerged child"
    return 1
  }
}

@test "auto still removes a parent nesting a CLEAN merged child" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "parent"
  local parent="$SCAN/repo/.worktrees/parent"
  add_nested_child "$parent" "child"   # clean, 0 commits ahead

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_not_contains "nests unmerged/dirty"
  assert_contains "Removed: 1"
}

# A nested child that belongs to a DIFFERENT repo than its parent. The
# relocation hint must point at the child's OWN repo, not the parent's
# repo_root (M1 fix) — otherwise the printed `git worktree move` targets the
# wrong tree (and omits -C scoping it to the child's repo).
@test "auto hint relocates a cross-repo nested child into its own repo" {
  create_repo "$SCAN/parentrepo"
  create_repo "$SCAN/childrepo"
  add_safe_worktree "$SCAN/parentrepo" "parent"
  local parent="$SCAN/parentrepo/.worktrees/parent"
  # Keep the parent SAFE despite hosting a nested .worktrees dir.
  printf '.worktrees/\n.claude/\n' > "$(git -C "$parent" rev-parse --git-path info/exclude)"
  # Nest a worktree of childrepo (a different repo) under the parent, made
  # dirty so it blocks the parent's removal.
  git -C "$SCAN/childrepo" worktree add "$parent/.worktrees/child" -b "claude/child" --quiet 2>/dev/null
  echo "wip" >> "$parent/.worktrees/child/README.md"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "nests unmerged/dirty"
  assert_contains "worktree move"
  # Hint targets the child's own repo, not the parent's repo_root.
  assert_contains "childrepo/.worktrees/child"
  assert_not_contains "parentrepo/.worktrees/child"
}

# ── Discovery beyond <repo>/.worktrees ─────────────────────────────────────

@test "discovers a worktree that lives outside the scan root" {
  create_repo "$SCAN/repo"
  git -C "$SCAN/repo" worktree add "$HOME/elsewhere/wt" -b "claude/far" --quiet 2>/dev/null

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "repo (1 worktree(s), default: main)"
  assert_contains "[SAFE] wt"
  assert_contains "path: $HOME/elsewhere/wt"
}

# ── Squash-merged PRs (per-repo gh cache) ──────────────────────────────────

# add_squashed_worktree <repo> <slug> — one commit on the branch, and an
# equivalent (squash) commit pushed to origin main. Prints the branch HEAD.
add_squashed_worktree() {
  local repo="$1" slug="$2"
  add_diverged_worktree "$repo" "$slug"
  echo "extra" > "$repo/diverged.txt"
  git -C "$repo" add diverged.txt
  git -C "$repo" commit -m "squash: diverge" --quiet
  git -C "$repo" push --quiet origin main
  git -C "$repo/.worktrees/$slug" rev-parse HEAD
}

@test "auto removes a worktree squash-merged at the PR head" {
  create_repo "$SCAN/repo"
  local head
  head="$(add_squashed_worktree "$SCAN/repo" "sq")"
  printf 'claude/sq\tMERGED\t%s\n' "$head" > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "PR squash-merged"
  assert_contains "Removed: 1"
  [[ ! -d "$SCAN/repo/.worktrees/sq" ]] || { echo "squash-merged worktree kept"; return 1; }
}

@test "auto keeps local commits added after a squash merge" {
  create_repo "$SCAN/repo"
  local head
  head="$(add_squashed_worktree "$SCAN/repo" "sq")"
  printf 'claude/sq\tMERGED\t%s\n' "$head" > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"
  echo "later" > "$SCAN/repo/.worktrees/sq/later.txt"
  git -C "$SCAN/repo/.worktrees/sq" add later.txt
  git -C "$SCAN/repo/.worktrees/sq" commit -m "after merge" --quiet

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "[WARN] sq"
  assert_contains "commits after squash-merge"
  assert_contains "Removed: 0"
  [[ -d "$SCAN/repo/.worktrees/sq" ]] || { echo "post-merge commits were removed"; return 1; }
}

# ── Guards ────────────────────────────────────────────────────────────────

# make_t3_db <worktree-path> <archived_at SQL literal>
make_t3_db() {
  mkdir -p "$(dirname "$CCW_SWEEP_T3_DB")"
  sqlite3 "$CCW_SWEEP_T3_DB" \
    "create table projection_threads (thread_id text, worktree_path text, archived_at text, deleted_at text);
     insert into projection_threads values ('t1', '$1', $2, null);"
}

@test "auto keeps a worktree owned by an active T3 thread" {
  command -v sqlite3 >/dev/null || skip "sqlite3 CLI not installed"
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "t3-busy"
  make_t3_db "$SCAN/repo/.worktrees/t3-busy" null

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "active T3 thread"
  assert_contains "Removed: 0"
  [[ -d "$SCAN/repo/.worktrees/t3-busy" ]] || { echo "T3-owned worktree removed"; return 1; }
}

@test "auto removes a worktree whose T3 thread is archived" {
  command -v sqlite3 >/dev/null || skip "sqlite3 CLI not installed"
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "t3-done"
  make_t3_db "$SCAN/repo/.worktrees/t3-done" "'2026-10-01T00:00:00Z'"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "Removed: 1"
  [[ ! -d "$SCAN/repo/.worktrees/t3-done" ]] || { echo "archived-thread worktree kept"; return 1; }
}

@test "auto treats every T3 worktree as owned when the T3 DB is unreadable" {
  create_repo "$SCAN/repo"
  export CCW_SWEEP_T3_ROOT="$HOME/.t3/worktrees"
  git -C "$SCAN/repo" worktree add "$CCW_SWEEP_T3_ROOT/repo/t3-x" -b "t3/x" --quiet 2>/dev/null
  mkdir -p "$(dirname "$CCW_SWEEP_T3_DB")"
  echo "not a database" > "$CCW_SWEEP_T3_DB"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "cannot read T3 state DB"
  assert_contains "active T3 thread"
  [[ -d "$CCW_SWEEP_T3_ROOT/repo/t3-x" ]] || { echo "T3 worktree removed on DB failure"; return 1; }
}

@test "auto keeps a worktree with a live process in it" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "busy"
  local wt="$SCAN/repo/.worktrees/busy"
  (cd "$wt" && exec sleep 300) >/dev/null 2>&1 3>&- &
  BG_PID=$!
  local _
  for _ in $(seq 1 50); do
    [[ -e /proc/self ]] || { sleep 1; break; }
    [[ "$(readlink "/proc/$BG_PID/cwd" 2>/dev/null)" == "$wt" ]] && break
    sleep 0.1
  done

  run ccw-sweep --auto --path "$SCAN"
  kill "$BG_PID" 2>/dev/null || true
  assert_success
  assert_contains "live process in worktree"
  assert_contains "Removed: 0"
  [[ -d "$wt" ]] || { echo "worktree with a live process removed"; return 1; }
}

@test "auto keeps a locked worktree" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "agent-x"
  git -C "$SCAN/repo" worktree lock --reason "claude agent agent-x (pid 1)" "$SCAN/repo/.worktrees/agent-x"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "keep: locked"
  assert_contains "skip_live=1"
  [[ -d "$SCAN/repo/.worktrees/agent-x" ]] || { echo "locked worktree removed"; return 1; }
}

@test "auto keeps a fresh SAFE worktree under the default idle threshold" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "fresh"

  run env -u CCW_SWEEP_SAFE_IDLE_DAYS ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "keep: recent"
  assert_contains "Removed: 0"
  [[ -d "$SCAN/repo/.worktrees/fresh" ]] || { echo "fresh worktree removed"; return 1; }
}

# ── --archive ─────────────────────────────────────────────────────────────

# no_prs — gh succeeds and lists no PRs (archive needs known PR state).
no_prs() {
  : > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"
}

@test "auto --archive tags an idle unmerged worktree, then removes it and its branch" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "old-work"
  no_prs
  local head
  head="$(git -C "$SCAN/repo/.worktrees/old-work" rev-parse HEAD)"
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "action: archive as archive/old-work"
  assert_contains "Archived: 1"
  [[ "$(git -C "$SCAN/repo" rev-parse 'archive/old-work^{commit}')" == "$head" ]] || {
    echo "archive tag missing or not at the old HEAD"; return 1; }
  [[ ! -d "$SCAN/repo/.worktrees/old-work" ]] || { echo "worktree dir still exists"; return 1; }
  ! git -C "$SCAN/repo" rev-parse --verify --quiet "refs/heads/claude/old-work" >/dev/null || {
    echo "branch still exists"; return 1; }
}

@test "auto --archive keeps a worktree when the PR list is unavailable" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "old-work"
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "keep: WARN, no PR info"
  assert_contains "Archived: 0"
  [[ -d "$SCAN/repo/.worktrees/old-work" ]] || { echo "archived without PR info"; return 1; }
}

@test "auto --archive keeps a worktree with an open PR" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "old-work"
  printf 'claude/old-work\tOPEN\t%s\n' "$(git -C "$SCAN/repo/.worktrees/old-work" rev-parse HEAD)" > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "keep: open PR"
  assert_contains "Archived: 0"
  [[ -d "$SCAN/repo/.worktrees/old-work" ]] || { echo "worktree with an open PR archived"; return 1; }
  ! git -C "$SCAN/repo" rev-parse --verify --quiet "refs/tags/archive/old-work" >/dev/null
}

@test "auto --archive leaves an idle DIRTY worktree untouched" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "wip"
  echo "wip" >> "$SCAN/repo/.worktrees/wip/README.md"
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "[DIRTY] wip"
  assert_contains "Archived: 0"
  [[ "$(cat "$SCAN/repo/.worktrees/wip/README.md")" == $'init\nwip' ]] || { echo "DIRTY worktree changed"; return 1; }
  ! git -C "$SCAN/repo" rev-parse --verify --quiet "refs/tags/archive/wip" >/dev/null
}

# ── Ignored files ─────────────────────────────────────────────────────────

@test "auto keeps a worktree with a non-regenerable ignored file" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "secrets"
  exclude_in "$SCAN/repo/.worktrees/secrets" ".env"
  echo "TOKEN=x" > "$SCAN/repo/.worktrees/secrets/.env"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "[WARN] secrets"
  assert_contains "ignored files: .env"
  [[ -f "$SCAN/repo/.worktrees/secrets/.env" ]] || { echo "worktree with .env removed"; return 1; }
}

@test "regenerable ignored dirs keep a worktree SAFE" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "built"
  local wt="$SCAN/repo/.worktrees/built"
  exclude_in "$wt" "target/" ".venv/"
  mkdir -p "$wt/target/debug" "$wt/.venv/bin"
  echo bin > "$wt/target/debug/app"
  echo py > "$wt/.venv/bin/python"
  # pytest ignores its cache with its own .gitignore, so git lists the files.
  mkdir -p "$wt/.pytest_cache/v"
  printf '# Created by pytest automatically.\n*\n' > "$wt/.pytest_cache/.gitignore"
  echo tag > "$wt/.pytest_cache/CACHEDIR.TAG"

  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "[SAFE] built"
  assert_not_contains "ignored files"
}

# add_ignored_cache <name> <ignore-pattern> <file>... — a SAFE worktree whose
# only ignored content is <file>s matched by <ignore-pattern>.
add_ignored_cache() {
  local name="$1" pattern="$2" file wt="$SCAN/repo/.worktrees/$1"
  shift 2
  [[ -d "$SCAN/repo/.git" ]] || create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "$name"
  exclude_in "$wt" "$pattern"
  for file in "$@"; do
    mkdir -p "$(dirname "$wt/$file")"
    echo generated > "$wt/$file"
  done
}

# assert_cache_safe <name> — the dry-run marks <name> SAFE with no ignored files.
assert_cache_safe() {
  run ccw-sweep --dry-run --path "$SCAN"
  assert_success
  assert_contains "[SAFE] $1"
  assert_not_contains "ignored files"
}

@test "ignored .astro keeps a worktree SAFE" {
  add_ignored_cache astro ".astro/" .astro/types.d.ts .astro/data-store.json
  assert_cache_safe astro
}

@test "ignored .venv-typing keeps a worktree SAFE" {
  add_ignored_cache typing ".venv-typing/" .venv-typing/bin/python .venv-typing/pyvenv.cfg
  assert_cache_safe typing
}

@test "ignored .import_linter_cache keeps a worktree SAFE" {
  add_ignored_cache linter ".import_linter_cache/" .import_linter_cache/pkg.meta.json
  assert_cache_safe linter
}

@test "ignored .hypothesis keeps a worktree SAFE" {
  add_ignored_cache hypo ".hypothesis/" .hypothesis/examples/ab12/cd34 .hypothesis/unicode_data/14.0.0/charmap.json.gz
  assert_cache_safe hypo
}

@test "ignored built .pyz next to a tracked file keeps a worktree SAFE" {
  # A tracked file in the dir makes git list the .pyz itself, not the dir.
  create_repo "$SCAN/repo"
  mkdir -p "$SCAN/repo/skills/mold/scripts"
  echo graph > "$SCAN/repo/skills/mold/scripts/mold.dot"
  git -C "$SCAN/repo" add skills/mold/scripts/mold.dot
  git -C "$SCAN/repo" commit -q -m "track mold.dot"
  git -C "$SCAN/repo" push -q origin main
  add_ignored_cache zipapp "skills/*/scripts/*.pyz" skills/mold/scripts/mold.pyz
  assert_cache_safe zipapp
}

@test "a whole ignored dir that holds only built .pyz files keeps a worktree SAFE" {
  # git lists skills/affinage/scripts/ as one dir entry, not the .pyz inside.
  add_ignored_cache zipdir "skills/*/scripts/*.pyz" skills/affinage/scripts/affinage.pyz skills/age/scripts/age.pyz
  assert_cache_safe zipdir
}

@test "a whole ignored dir with a source file next to a .pyz still WARNs" {
  add_ignored_cache mixed "skills/*/scripts/*" skills/affinage/scripts/affinage.pyz skills/affinage/scripts/helper.py

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "[WARN] mixed"
  assert_contains "ignored files: "
  assert_contains "skills/affinage/scripts"
  [[ -f "$SCAN/repo/.worktrees/mixed/skills/affinage/scripts/helper.py" ]] || { echo "ignored source removed"; return 1; }
}

@test "an ignored file outside the regenerable list still WARNs" {
  add_ignored_cache unlisted ".tool-cache/" .tool-cache/state.json

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "[WARN] unlisted"
  assert_contains "ignored files: .tool-cache"
  [[ -f "$SCAN/repo/.worktrees/unlisted/.tool-cache/state.json" ]] || { echo "unlisted ignored file removed"; return 1; }
}

@test "auto --archive archives an idle unmerged worktree whose ignored files are regenerable" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "old-work"
  local wt="$SCAN/repo/.worktrees/old-work"
  exclude_in "$wt" ".hypothesis/" "skills/*/scripts/*.pyz"
  mkdir -p "$wt/.hypothesis/examples" "$wt/skills/cook/scripts"
  echo ex > "$wt/.hypothesis/examples/one"
  echo zip > "$wt/skills/cook/scripts/cook.pyz"
  no_prs
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "action: archive as archive/old-work"
  assert_contains "Archived: 1"
  [[ ! -d "$wt" ]] || { echo "worktree dir still exists"; return 1; }
}

# ── .cheese/ ─────────────────────────────────────────────────────────────────

# add_cheese <worktree> <relative-path>... — gitignore .cheese/ and write each
# file under <worktree>/.cheese with its own path as content.
add_cheese() {
  local wt="$1" rel
  shift
  exclude_in "$wt" ".cheese/"
  for rel in "$@"; do
    mkdir -p "$(dirname "$wt/.cheese/$rel")"
    echo "$rel" > "$wt/.cheese/$rel"
  done
}

CHEESE_DEFAULT_REL=".local/share/ccw-sweep/cheese"

@test "auto copies a throwaway-only .cheese/ out, then removes the merged worktree" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "tidy"
  add_cheese "$SCAN/repo/.worktrees/tidy" age/review.md scratch/probe.sh plate/state.json loose.md

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "[SAFE] tidy"
  assert_contains "throwaway .cheese/ (4 file(s))"
  assert_contains "Cheese archived: 1"
  assert_contains "removed=1 "
  assert_contains "cheese_archived=1 skip_cheese=0"
  local copy="$HOME/$CHEESE_DEFAULT_REL/repo/tidy" rel
  for rel in age/review.md scratch/probe.sh plate/state.json loose.md; do
    [[ "$(cat "$copy/$rel")" == "$rel" ]] || { echo "copy of $rel missing or wrong"; return 1; }
  done
  [[ ! -d "$SCAN/repo/.worktrees/tidy" ]] || { echo "worktree dir still exists"; return 1; }
}

@test "a keep-worthy .cheese/ file keeps the worktree DIRTY and lists its dirs" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "spec"
  add_cheese "$SCAN/repo/.worktrees/spec" age/review.md specs/plan.md wheypoint.json

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "[DIRTY] spec"
  assert_contains "uncommitted .cheese/ notes: specs wheypoint.json"
  assert_contains "action: keep: DIRTY, keep-worthy .cheese/ notes"
  assert_contains "skip_dirty=0 "
  assert_contains "cheese_archived=0 skip_cheese=1"
  [[ -f "$SCAN/repo/.worktrees/spec/.cheese/specs/plan.md" ]] || { echo "keep-worthy note removed"; return 1; }
  [[ ! -e "$HOME/$CHEESE_DEFAULT_REL" ]] || { echo "copied a kept worktree"; return 1; }
}

@test "a failed .cheese/ copy keeps the worktree" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "tidy"
  add_cheese "$SCAN/repo/.worktrees/tidy" age/review.md
  echo file > "$HOME/blocker"   # a file where the archive dir must go
  export CCW_SWEEP_CHEESE_ARCHIVE="$HOME/blocker/cheese"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "could not copy .cheese/"
  assert_contains "action: keep: .cheese/ copy failed"
  assert_contains "removed=0 "
  assert_contains "cheese_archived=0 skip_cheese=1"
  [[ -f "$SCAN/repo/.worktrees/tidy/.cheese/age/review.md" ]] || { echo "worktree removed after a failed copy"; return 1; }
}

@test "dry run reports the .cheese/ copy but copies nothing" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "tidy"
  add_cheese "$SCAN/repo/.worktrees/tidy" age/review.md

  run ccw-sweep --dry-run --auto --path "$SCAN"
  assert_success
  assert_contains "action: copy .cheese/ to $HOME/$CHEESE_DEFAULT_REL/repo/tidy"
  assert_contains "cheese_archived=1 skip_cheese=0 dry_run=1"
  [[ ! -e "$HOME/$CHEESE_DEFAULT_REL" ]] || { echo "dry run copied .cheese/"; return 1; }
  [[ -f "$SCAN/repo/.worktrees/tidy/.cheese/age/review.md" ]] || { echo "dry run removed the worktree"; return 1; }
}

@test "auto --archive copies a throwaway .cheese/ to a short-sha dir on a slug collision" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "old-work"
  local wt="$SCAN/repo/.worktrees/old-work" head
  add_cheese "$wt" reviews/r1.md tmp/t
  head="$(git -C "$wt" rev-parse HEAD)"
  export CCW_SWEEP_CHEESE_ARCHIVE="$HOME/arch"
  mkdir -p "$HOME/arch/repo/old-work"
  no_prs
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "action: archive as archive/old-work"
  assert_contains "Archived: 1"
  [[ "$(cat "$HOME/arch/repo/old-work-${head:0:8}/reviews/r1.md")" == "reviews/r1.md" ]] || {
    echo "collision copy missing"; return 1; }
  [[ -z "$(ls -A "$HOME/arch/repo/old-work")" ]] || { echo "wrote into the existing dir"; return 1; }
  [[ ! -d "$wt" ]] || { echo "worktree dir still exists"; return 1; }
}

@test "cook/, press/, and cut/ reports of a merged branch are throwaway" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "done"
  add_cheese "$SCAN/repo/.worktrees/done" cook/slug.md cook/slug/receipt.json press/p.json cut/c.json

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "[SAFE] done"
  assert_contains "throwaway .cheese/ (4 file(s))"
  assert_contains "cheese_archived=1 skip_cheese=0"
  [[ "$(cat "$HOME/$CHEESE_DEFAULT_REL/repo/done/cook/slug/receipt.json")" == "cook/slug/receipt.json" ]] || {
    echo "cook receipt not copied"; return 1; }
  [[ ! -d "$SCAN/repo/.worktrees/done" ]] || { echo "worktree dir still exists"; return 1; }
}

@test "a cook/ report keeps an unmerged branch DIRTY under --archive" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "old-work"
  add_cheese "$SCAN/repo/.worktrees/old-work" cook/slug.md cut/c.json
  no_prs
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "[DIRTY] old-work"
  assert_contains "uncommitted .cheese/ notes: cook"
  assert_contains "Archived: 0"
  assert_contains "cheese_archived=0 skip_cheese=1"
  [[ -f "$SCAN/repo/.worktrees/old-work/.cheese/cook/slug.md" ]] || { echo "unmerged cook report removed"; return 1; }
}

@test "a press/ report keeps a branch with commits after its squash-merge DIRTY" {
  create_repo "$SCAN/repo"
  local wt="$SCAN/repo/.worktrees/more" head
  head="$(add_squashed_worktree "$SCAN/repo" "more")"
  printf 'claude/more\tMERGED\t%s\n' "$head" > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"
  echo extra > "$wt/extra.txt"
  git -C "$wt" add extra.txt
  git -C "$wt" commit -q -m extra
  add_cheese "$wt" press/p.json

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "commits after squash-merge"
  assert_contains "uncommitted .cheese/ notes: press"
  [[ -f "$wt/.cheese/press/p.json" ]] || { echo "press report removed"; return 1; }
}

@test "auto --archive archives an unmerged branch whose .cheese/ holds only cut/" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "old-work"
  add_cheese "$SCAN/repo/.worktrees/old-work" cut/c.json
  no_prs
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --archive --path "$SCAN"
  assert_success
  assert_contains "action: archive as archive/old-work"
  assert_contains "cheese_archived=1 skip_cheese=0"
  [[ "$(cat "$HOME/$CHEESE_DEFAULT_REL/repo/old-work/cut/c.json")" == "cut/c.json" ]] || {
    echo "cut file not copied"; return 1; }
}

@test "a cook/ report does not hide a squash-merge found by patch match" {
  create_repo "$SCAN/repo"
  add_two_commit_worktree "$SCAN/repo" "sq"
  squash_onto_main "$SCAN/repo" "sq"
  add_cheese "$SCAN/repo/.worktrees/sq" cook/slug.md

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "squash-merged (patch match)"
  assert_contains "Removed: 1"
  [[ "$(cat "$HOME/$CHEESE_DEFAULT_REL/repo/sq/cook/slug.md")" == "cook/slug.md" ]] || {
    echo "cook report not copied"; return 1; }
}

# ── --reclaim ─────────────────────────────────────────────────────────────

@test "auto --reclaim deletes target/ in an idle kept worktree and nothing else" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "keepme"
  local wt="$SCAN/repo/.worktrees/keepme"
  exclude_in "$wt" "target/" ".env"
  mkdir -p "$wt/target/debug"
  head -c 65536 /dev/zero > "$wt/target/debug/app"
  echo "TOKEN=x" > "$wt/.env"
  CCW_SWEEP_NOW="$(days_from_now 8)"
  export CCW_SWEEP_NOW

  run ccw-sweep --auto --reclaim --path "$SCAN"
  assert_success
  assert_contains "action: reclaim"
  assert_not_contains "Reclaimed: 0 KiB"
  [[ ! -e "$wt/target" ]] || { echo "target/ not reclaimed"; return 1; }
  [[ -f "$wt/.env" && -f "$wt/diverged.txt" && -f "$wt/README.md" ]] || {
    echo "reclaim deleted a file it must keep"; return 1; }
}

@test "dry-run with --archive --reclaim changes nothing on disk" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "archivable"
  add_diverged_worktree "$SCAN/repo" "dirty-built"
  no_prs
  local wt="$SCAN/repo/.worktrees/dirty-built"
  exclude_in "$wt" "target/"
  mkdir -p "$wt/target"
  echo bin > "$wt/target/app"
  echo "wip" >> "$wt/README.md"
  CCW_SWEEP_NOW="$(days_from_now 40)"
  export CCW_SWEEP_NOW

  run ccw-sweep --dry-run --archive --reclaim --path "$SCAN"
  assert_success
  assert_contains "action: archive as archive/archivable"
  assert_contains "action: reclaim"
  assert_contains "dry_run=1"
  [[ -d "$SCAN/repo/.worktrees/archivable" && -f "$wt/target/app" ]] || { echo "dry-run changed files"; return 1; }
  ! git -C "$SCAN/repo" rev-parse --verify --quiet "refs/tags/archive/archivable" >/dev/null || {
    echo "dry-run created a tag"; return 1; }
  git -C "$SCAN/repo" rev-parse --verify --quiet "refs/heads/claude/archivable" >/dev/null
}

# ── Summary line and flag validation ───────────────────────────────────────

@test "prints a machine-readable SUMMARY line with correct counts" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "clean"
  add_diverged_worktree "$SCAN/repo" "diverged"
  add_safe_worktree "$SCAN/repo" "dirty"
  echo "wip" >> "$SCAN/repo/.worktrees/dirty/README.md"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "SUMMARY ccw-sweep: total=3 safe=1 removed=1 archived=0 reclaimed_kib=0 skipped=2 skip_recent=0 skip_live=0 skip_t3=0 skip_open_pr=0 skip_dirty=1 skip_warn=1 skip_nested=0 cheese_archived=0 skip_cheese=0 dry_run=0"
  [[ "${lines[${#lines[@]}-1]}" == "SUMMARY ccw-sweep: "* ]] || { echo "SUMMARY is not the last line"; return 1; }
}

@test "--archive without --auto or --dry-run is an error" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "wt"

  run ccw-sweep --archive --path "$SCAN"
  [[ $status -ne 0 ]]
  assert_contains "need --auto or --dry-run"
  [[ -d "$SCAN/repo/.worktrees/wt" ]]
}

@test "rejects a non-numeric idle threshold" {
  run env CCW_SWEEP_ARCHIVE_IDLE_DAYS=soon ccw-sweep --dry-run --path "$SCAN"
  [[ $status -ne 0 ]]
  assert_contains "CCW_SWEEP_ARCHIVE_IDLE_DAYS must be a whole number"
}

# ── Targeted fetch of merged-PR heads ─────────────────────────────────────────

# add_pr_head_only_on_origin <repo> <slug> <n> — a second clone pushes a child
# of the worktree HEAD to the bare origin only as refs/pull/<n>/head, and the
# branch is then deleted, as GitHub does after a merge. Prints the PR head oid.
add_pr_head_only_on_origin() {
  local repo="$1" slug="$2" n="$3" clone="$HOME/clone2"
  git -C "$repo" push --quiet origin "claude/$slug"
  git clone --quiet "${repo}.origin.git" "$clone"
  git -C "$clone" config user.email "test@test.com"
  git -C "$clone" config user.name "Test"
  git -C "$clone" checkout --quiet "claude/$slug"
  echo "review fix" > "$clone/review.txt"
  git -C "$clone" add review.txt
  git -C "$clone" commit -m "review fix" --quiet
  git -C "$clone" push --quiet origin "HEAD:refs/pull/$n/head"
  git -C "$repo" push --quiet origin --delete "claude/$slug" 2>/dev/null
  git -C "$clone" rev-parse HEAD
}

@test "auto fetches a missing merged-PR head and removes the worktree behind it" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "sq"
  local pr_head
  pr_head="$(add_pr_head_only_on_origin "$SCAN/repo" "sq" 7)"
  run git -C "$SCAN/repo" cat-file -e "${pr_head}^{commit}"
  [[ $status -ne 0 ]] || { echo "PR head is already local; the fixture proves nothing"; return 1; }
  printf 'claude/sq\tMERGED\t%s\t7\n' "$pr_head" > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "fetched 1 merged-PR head(s)"
  assert_contains "PR squash-merged"
  assert_contains "Removed: 1"
  [[ ! -d "$SCAN/repo/.worktrees/sq" ]] || { echo "worktree behind the PR head kept"; return 1; }
  [[ -z "$(git -C "$SCAN/repo" for-each-ref refs/ccw-sweep/)" ]] || { echo "refs/ccw-sweep/ not cleaned"; return 1; }
}

@test "CCW_SWEEP_FETCH_PR_HEADS=0 keeps a worktree whose PR head is missing" {
  create_repo "$SCAN/repo"
  add_diverged_worktree "$SCAN/repo" "sq"
  local pr_head
  pr_head="$(add_pr_head_only_on_origin "$SCAN/repo" "sq" 7)"
  printf 'claude/sq\tMERGED\t%s\t7\n' "$pr_head" > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"

  run env CCW_SWEEP_FETCH_PR_HEADS=0 ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "commits after squash-merge"
  assert_contains "Removed: 0"
  [[ -d "$SCAN/repo/.worktrees/sq" ]] || { echo "worktree removed without the PR head"; return 1; }
  [[ -z "$(git -C "$SCAN/repo" for-each-ref refs/ccw-sweep/)" ]]
}

# ── Offline squash check (git cherry) ───────────────────────────────────────────

# squash_onto_main <repo> <slug> — apply the branch's net diff to origin main
# as one commit (a squash merge that GitHub did not report).
squash_onto_main() {
  local repo="$1" slug="$2"
  git -C "$repo" checkout --quiet "claude/$slug" -- .
  git -C "$repo" commit -m "squash: $slug" --quiet
  git -C "$repo" push --quiet origin main
}

# add_two_commit_worktree <repo> <slug> — a branch with two commits.
add_two_commit_worktree() {
  local repo="$1" slug="$2"
  add_diverged_worktree "$repo" "$slug"
  echo "second" > "$repo/.worktrees/$slug/second.txt"
  git -C "$repo/.worktrees/$slug" add second.txt
  git -C "$repo/.worktrees/$slug" commit -m "second" --quiet
}

@test "auto removes a squash-merged branch by patch match when gh fails" {
  create_repo "$SCAN/repo"
  add_two_commit_worktree "$SCAN/repo" "sq"
  squash_onto_main "$SCAN/repo" "sq"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "squash-merged (patch match)"
  assert_contains "Removed: 1"
  [[ ! -d "$SCAN/repo/.worktrees/sq" ]] || { echo "patch-equal branch kept"; return 1; }
}

@test "auto keeps an unmerged branch when gh fails" {
  create_repo "$SCAN/repo"
  add_two_commit_worktree "$SCAN/repo" "open-work"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_not_contains "patch match"
  assert_contains "NOT merged into main"
  assert_contains "Removed: 0"
  [[ -d "$SCAN/repo/.worktrees/open-work" ]] || { echo "unmerged branch removed"; return 1; }
}

@test "CCW_SWEEP_CHERRY_MAX caps the offline patch check" {
  create_repo "$SCAN/repo"
  add_two_commit_worktree "$SCAN/repo" "sq"
  squash_onto_main "$SCAN/repo" "sq"

  run env CCW_SWEEP_CHERRY_MAX=0 ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "patch check skipped: 1 commits on main since fork"
  assert_contains "Removed: 0"
  [[ -d "$SCAN/repo/.worktrees/sq" ]] || { echo "worktree removed past the cap"; return 1; }
}

@test "a CLOSED PR row wins over a patch match" {
  create_repo "$SCAN/repo"
  add_two_commit_worktree "$SCAN/repo" "sq"
  squash_onto_main "$SCAN/repo" "sq"
  printf 'claude/sq\tCLOSED\t%s\t9\n' "$(git -C "$SCAN/repo/.worktrees/sq" rev-parse HEAD)" > "$HOME/prs.tsv"
  export FAKE_GH_TSV="$HOME/prs.tsv"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "PR closed without merge"
  assert_not_contains "patch match"
  [[ -d "$SCAN/repo/.worktrees/sq" ]] || { echo "fallback removed a branch with a CLOSED PR"; return 1; }
}

@test "rejects invalid CCW_SWEEP_CHERRY_MAX and CCW_SWEEP_FETCH_PR_HEADS" {
  run env CCW_SWEEP_CHERRY_MAX=lots ccw-sweep --dry-run --path "$SCAN"
  [[ $status -ne 0 ]]
  assert_contains "CCW_SWEEP_CHERRY_MAX must be a whole number"
  run env CCW_SWEEP_FETCH_PR_HEADS=yes ccw-sweep --dry-run --path "$SCAN"
  [[ $status -ne 0 ]]
  assert_contains "CCW_SWEEP_FETCH_PR_HEADS must be 0 or 1"
}

@test "rejects an idle threshold with a leading zero (bash reads it as octal)" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "fresh"

  run env CCW_SWEEP_SAFE_IDLE_DAYS=08 ccw-sweep --auto --path "$SCAN"
  [[ $status -ne 0 ]]
  assert_contains "CCW_SWEEP_SAFE_IDLE_DAYS must be a whole number without leading zeros, got: '08'"
  [[ -d "$SCAN/repo/.worktrees/fresh" ]] || { echo "worktree removed despite a rejected threshold"; return 1; }
}

# ── Nested-child guards beyond dirty/unmerged ────────────────────────────────────

@test "auto refuses to remove a parent nesting a locked clean child" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "parent"
  local parent="$SCAN/repo/.worktrees/parent"
  add_nested_child "$parent" "child"
  git -C "$SCAN/repo" worktree lock --reason "claude agent child (pid 1)" "$parent/.worktrees/child"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "nests unmerged/dirty/guarded"
  assert_contains "Skipping removal"
  assert_contains "Removed: 0"
  [[ -d "$parent/.worktrees/child" ]] || { echo "locked nested child deleted with its parent"; return 1; }
}

@test "auto refuses to remove a parent nesting a child with a non-regenerable ignored file" {
  create_repo "$SCAN/repo"
  add_safe_worktree "$SCAN/repo" "parent"
  local parent="$SCAN/repo/.worktrees/parent"
  add_nested_child "$parent" "child"
  exclude_in "$parent" ".env"
  echo "TOKEN=x" > "$parent/.worktrees/child/.env"

  run ccw-sweep --auto --path "$SCAN"
  assert_success
  assert_contains "nests unmerged/dirty/guarded"
  [[ -f "$parent/.worktrees/child/.env" ]] || { echo "nested .env deleted with its parent"; return 1; }
}
