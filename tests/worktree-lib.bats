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

# ── wt_repo_name / wt_regen_select / wt_path_under ──────────────────────────

@test "wt_repo_name: reads the name from ssh, https, and path origins" {
  local url
  mkdir -p "$SCAN/clone"
  git -C "$SCAN/clone" init -q
  for url in git@github.com:o/easy-cheese.git https://github.com/o/easy-cheese \
             https://github.com/o/easy-cheese.git/ /srv/git/easy-cheese.git; do
    git -C "$SCAN/clone" remote remove origin 2>/dev/null || true
    git -C "$SCAN/clone" remote add origin "$url"
    run wt_repo_name "$SCAN/clone"
    [[ "$output" == "easy-cheese" ]] || { echo "$url -> $output"; return 1; }
  done
}

@test "wt_repo_name: falls back to the checkout dir name without an origin" {
  mkdir -p "$SCAN/local-only"
  git -C "$SCAN/local-only" init -q
  run wt_repo_name "$SCAN/local-only"
  [[ "$output" == "local-only" ]] || { echo "got: $output"; return 1; }
}

@test "wt_regen_select: splits names and anchored paths and keeps only this repo's entries" {
  run wt_regen_select tdbr target '*.pyz' .claude/workflows tdbr:/reports tdbr:.godot \
    easy-cheese:/vendor easy-cheese:website/content/docs /
  [[ "$output" == $'name\ttarget\nname\t*.pyz\npath\t.claude/workflows\npath\treports\nname\t.godot' ]] || {
    echo "got: $output"; return 1; }
}

@test "wt_path_under: matches the glob and paths below it, not name prefixes" {
  wt_path_under website/content/docs website/content/docs
  wt_path_under website/content/docs/skills/cook.md website/content/docs
  wt_path_under frontend/mold-review/test-results/r.json 'frontend/*/test-results'
  run wt_path_under website/content/docsx website/content/docs
  [[ $status -eq 1 ]] || { echo "name prefix matched"; return 1; }
  run wt_path_under sub/reports/x reports
  [[ $status -eq 1 ]] || { echo "nested path matched an anchored glob"; return 1; }
}

@test "wt_path_inside: resolves the nearest existing ancestor, not name prefixes" {
  mkdir -p "$SCAN/wt/sub" "$SCAN/wtx"
  ln -s "$SCAN/wt/sub" "$SCAN/link"
  wt_path_inside "$SCAN/wt" "$SCAN/wt"
  wt_path_inside "$SCAN/wt/new/deeper" "$SCAN/wt"
  wt_path_inside "$SCAN/link/new" "$SCAN/wt"
  run wt_path_inside "$SCAN/wtx/new" "$SCAN/wt"
  [[ $status -eq 1 ]] || { echo "name prefix matched"; return 1; }
  run wt_path_inside "$SCAN/other/new" "$SCAN/wt"
  [[ $status -eq 1 ]] || { echo "outside path matched"; return 1; }
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

@test "wt_child_blocks_removal: gitignored .cheese/ notes block" {
  create_repo "$SCAN/repo"
  echo ".cheese/" > "$SCAN/repo/.gitignore"
  git -C "$SCAN/repo" add .gitignore
  git -C "$SCAN/repo" commit -m "gitignore" --quiet
  git -C "$SCAN/repo" push --quiet origin main
  add_worktree "$SCAN/repo" "noted"
  mkdir -p "$SCAN/repo/.worktrees/noted/.cheese/notes"
  echo "handoff" > "$SCAN/repo/.worktrees/noted/.cheese/notes/slug.md"
  run wt_child_blocks_removal "$SCAN/repo/.worktrees/noted"
  [[ $status -eq 0 ]]
}

# ── wt_cheese_class / wt_cheese_archive_dir ────────────────────────────────

@test "wt_cheese_class: review, cut, and scratch dirs and loose files are throwaway" {
  local rel
  for rel in age/r.md plate/state.json affinage/x cure/y.md reviews/a/b.md cut/c.json \
             cut/deep/c.json press-history/1.json press-decisions/d.md scratch/probe.sh \
             tmp/t notes.md state.json; do
    run wt_cheese_class "$rel"
    [[ $status -eq 1 ]] || { echo "not throwaway ($status): $rel"; return 1; }
  done
}

@test "wt_cheese_class: cook and press reports depend on the merge state" {
  local rel
  for rel in cook/c.md cook/slug/receipt.json press/p.json press/run/p.md; do
    run wt_cheese_class "$rel"
    [[ $status -eq 2 ]] || { echo "not merge-dependent ($status): $rel"; return 1; }
  done
}

@test "wt_cheese_class: work dirs, wheypoint records, and unknown dirs are keep-worthy" {
  local rel
  for rel in specs/s.md plans/p.md research/r.md notes/n.md issues/i.md glossary/g.md \
             mold/m.json durable/d.md build-optimize/b.md \
             wheypoint.json wheypoint-slug.md wp-intent.json unknown-dir/x \
             age-notes/x scratchpad/x cooking/x cut-notes/x; do
    run wt_cheese_class "$rel"
    [[ $status -eq 0 ]] || { echo "not keep-worthy ($status): $rel"; return 1; }
  done
}

@test "wt_cheese_archive_dir: uses the slug, then the short sha, then a counter" {
  local base="$SCAN/arch" sha=0123456789abcdef0123456789abcdef01234567
  run wt_cheese_archive_dir "$base" repo feat "$sha"
  [[ "$output" == "$base/repo/feat" ]] || { echo "got: $output"; return 1; }
  mkdir -p "$base/repo/feat"
  run wt_cheese_archive_dir "$base" repo feat "$sha"
  [[ "$output" == "$base/repo/feat-01234567" ]] || { echo "got: $output"; return 1; }
  mkdir -p "$base/repo/feat-01234567"
  run wt_cheese_archive_dir "$base" repo feat "$sha"
  [[ "$output" == "$base/repo/feat-01234567-2" ]] || { echo "got: $output"; return 1; }
}

@test "wt_cheese_tracked_changed: counts changed and staged files, not clean or deleted ones" {
  create_repo "$SCAN/repo"
  local r="$SCAN/repo"
  mkdir -p "$r/.cheese/specs"
  echo v1 > "$r/.cheese/specs/a.md"
  echo v1 > "$r/.cheese/specs/b.md"
  git -C "$r" add .cheese
  git -C "$r" commit -m cheese --quiet
  run wt_cheese_tracked_changed "$r"
  [[ $status -eq 1 ]] || { echo "clean tracked files counted"; return 1; }
  rm "$r/.cheese/specs/b.md"
  run wt_cheese_tracked_changed "$r"
  [[ $status -eq 1 ]] || { echo "a deleted file counted"; return 1; }
  echo v2 >> "$r/.cheese/specs/a.md"
  run wt_cheese_tracked_changed "$r"
  [[ $status -eq 0 ]] || { echo "a modified file missed"; return 1; }
  git -C "$r" checkout --quiet -- .cheese/specs/a.md
  echo new > "$r/.cheese/specs/c.md"
  git -C "$r" add .cheese/specs/c.md
  run wt_cheese_tracked_changed "$r"
  [[ $status -eq 0 ]] || { echo "a staged new file missed"; return 1; }
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

# ── wt_main_checkout / wt_is_locked / wt_archive_tag ─────────────────────────────

@test "wt_main_checkout prints the main checkout for a linked worktree" {
  create_repo "$SCAN/repo"
  git -C "$SCAN/repo" worktree add --quiet "$SCAN/far/wt" -b far
  run wt_main_checkout "$SCAN/far/wt"
  [[ $status -eq 0 ]]
  [[ "$output" == "$SCAN/repo" ]]
}

@test "wt_main_checkout prints the bare repo dir for a worktree of a bare repo" {
  create_repo "$SCAN/repo"
  git clone --quiet --bare "$SCAN/repo" "$SCAN/bare.git"
  git -C "$SCAN/bare.git" worktree add --quiet "$SCAN/bare-wt" -b wt
  run wt_main_checkout "$SCAN/bare-wt"
  [[ $status -eq 0 ]]
  [[ "$output" == "$SCAN/bare.git" ]]
}

@test "wt_main_checkout fails outside a git repo" {
  mkdir -p "$SCAN/plain"
  run wt_main_checkout "$SCAN/plain"
  [[ $status -eq 1 ]]
  [[ -z "$output" ]]
}

@test "wt_is_locked follows git worktree lock and unlock" {
  create_repo "$SCAN/repo"
  add_worktree "$SCAN/repo" "wt"
  run wt_is_locked "$SCAN/repo/.worktrees/wt"
  [[ $status -eq 1 ]]
  git -C "$SCAN/repo" worktree lock "$SCAN/repo/.worktrees/wt"
  run wt_is_locked "$SCAN/repo/.worktrees/wt"
  [[ $status -eq 0 ]]
  git -C "$SCAN/repo" worktree unlock "$SCAN/repo/.worktrees/wt"
  run wt_is_locked "$SCAN/repo/.worktrees/wt"
  [[ $status -eq 1 ]]
}

@test "wt_archive_tag picks archive/<slug>, reuses a tag at HEAD, and suffixes on a collision" {
  create_repo "$SCAN/repo"
  local first second
  first="$(git -C "$SCAN/repo" rev-parse HEAD)"
  run wt_archive_tag "$SCAN/repo" "alpha" "$first"
  [[ "$output" == "archive/alpha" ]]

  git -C "$SCAN/repo" tag archive/alpha "$first"
  run wt_archive_tag "$SCAN/repo" "alpha" "$first"
  [[ "$output" == "archive/alpha" ]]

  git -C "$SCAN/repo" commit --quiet --allow-empty -m second
  second="$(git -C "$SCAN/repo" rev-parse HEAD)"
  run wt_archive_tag "$SCAN/repo" "alpha" "$second"
  [[ $status -eq 0 ]]
  [[ "$output" == "archive/alpha-${second:0:8}" ]]
}

@test "wt_archive_tag falls back to archive/wt-<sha12> for an invalid slug" {
  create_repo "$SCAN/repo"
  local head
  head="$(git -C "$SCAN/repo" rev-parse HEAD)"
  run wt_archive_tag "$SCAN/repo" "bad..slug" "$head"
  [[ $status -eq 0 ]]
  [[ "$output" == "archive/wt-${head:0:12}" ]]
}
