---
name: move-my-cheese
description: Take over a PR — rebase/merge main, diagnose CI failures, fix tests and conflicts, push fixes. The cheese has moved; go get it.
argument-hint: <PR number>
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch
---

Take over and rescue PR **#$ARGUMENTS** — the cheese has moved, time to find it.

This command automates the "PR rescue" workflow: fetch context, diagnose failures, merge main, fix issues, push.

## Skills Used

This command orchestrates across multiple skills:

| Phase | Skill | Why |
|---|---|---|
| Recon | **gh** | PR metadata, CI checks, failed run logs, diff |
| Explore | **scout** | Search codebase for test files, CI config, related code |
| Diagnose | **diff** | Smoke-test the merged state for obvious issues |
| Fix | **chisel** | Edit conflict markers, patch test assertions |
| Test | **whey-drainer** agent | Run tests with output isolation |
| Commit | **commit** | Stage and commit fixes (conventional format) |
| Push | **gh** | Push to PR branch, re-run failed CI |

## Progress Tracking

At command start, call `TaskCreate` for all 4 phases. Mark `in_progress` at phase start, `completed` at phase end.

| Phase | Subject | activeForm |
|---|---|---|
| 1 | Recon PR state | Gathering PR context |
| 2 | Checkout and merge main | Merging main into PR |
| 3 | Diagnose and fix failures | Diagnosing and fixing failures |
| 4 | Push fixes and report | Pushing fixes |

---

## Phase 1 — Recon (gh skill)

Use the `/gh` skill to gather all PR context in a single batched call:

```bash
# Batch all recon into one shot
{
  echo "=== PR METADATA ==="
  gh pr view $ARGUMENTS --json title,body,headRefName,baseRefName,state,mergeable,mergeStateStatus,url,statusCheckRollup
  echo "=== DIFF ==="
  gh pr diff $ARGUMENTS --stat
  echo "=== CHECKS ==="
  gh pr checks $ARGUMENTS
}
```

For any failing checks, fetch logs:
```bash
gh run view <run-id> --log-failed
```

Summarize findings:
- PR title and branch
- Merge status (clean, conflicts, or blocked)
- CI failures (infra flake vs real test failure)
- Scope of changes (files touched, lines changed)

---

## Phase 2 — Checkout & Merge

### Worktree Check

If the PR branch is checked out in another worktree, work from the current branch:
- `git fetch origin <pr-branch> main`
- `git reset --hard origin/<pr-branch>`
- `git merge origin/main --no-edit`

If the PR branch is free:
- `git checkout <pr-branch>`
- `git merge origin/main --no-edit`

### Conflict Resolution (chisel skill)

If merge conflicts occur:
1. List conflicting files with `git diff --name-only --diff-filter=U`
2. Use **scout** (`rg '<<<<<<< ' --files-with-matches`) to confirm all conflict markers
3. For each conflict, Read the file and resolve with **chisel** (Edit tool for precise context-matched replacements)
   - Prefer the PR's intent over main's formatting changes
   - Keep both sides when they're additive (new features on both sides)
   - Ask the user for ambiguous conflicts (logic changes on both sides)
4. Verify resolution: `rg '<<<<<<< |======= |>>>>>>> ' --count` should return no matches
5. Stage resolved files and commit the merge

If no conflicts: report clean merge and move on.

---

## Phase 3 — Diagnose & Fix

### CI Failure Analysis

Categorize each CI failure from Phase 1 recon:

| Category | Action |
|---|---|
| **Infra flake** (503, timeout, OOM) | Note it — will resolve on re-run |
| **Test failure** (assertion error) | Fix the code or test |
| **Lint/format** (shellcheck, prettier) | Auto-fix with chisel |
| **Merge artifact** (conflict markers) | Should have been caught in Phase 2 |

### Run Tests Locally (whey-drainer agent)

Use the `whey-drainer` agent to run the test suite with output isolation:

```
Task(subagent_type="whey-drainer", model="haiku", prompt="Run the project test suite. Look for test runner config (bats, pytest, jest, etc.) and execute. Report pass/fail counts and failure details only.")
```

If tests pass: the CI failure was likely infra. Move to Phase 4.

### Smoke Check (diff skill)

Run `/diff` against the merged state to catch obvious issues the merge may have introduced:
- Conflict markers left behind
- Debug statements
- Silent failures in merged code

### Fix Strategy (scout + chisel skills)

For real test failures:
1. Use **scout** (`rg` for error messages, `fd` for test files) to locate the failing test
2. Read the failing test and the code under test
3. Fix with **chisel** — minimal change, `sd` for pattern fixes, Edit for precise patches
4. Re-run via **whey-drainer** to verify

If tests fail after fixes, run the wrecker-drainer feedback loop (up to 3 rounds):
```
Task(subagent_type="roquefort-wrecker", model="haiku", prompt="Investigate test failures: <details>. Fix test bugs, score code bugs 0-100.")
```
Then re-drain to verify.

---

## Phase 4 — Push & Report (commit + gh skills)

1. **Commit** fixes via the `/commit` skill (conventional format, never --no-verify)
2. **Push** to the PR branch via `/gh`: `git push origin HEAD:<pr-branch>`
3. If CI failure was purely infrastructure, offer to re-run: `gh run rerun <run-id> --failed`

Report summary:
- What was wrong (conflicts, test failures, infra flakes)
- What was fixed
- What will resolve on CI re-run
- Link to the PR

---

## Error Recovery

- If the PR branch can't be fetched, check if it was force-pushed or deleted
- If merge produces too many conflicts (>5 files), ask the user before proceeding
- If tests fail after 3 wrecker-drainer rounds, surface remaining failures to the user
- Never force-push to the PR branch without asking
