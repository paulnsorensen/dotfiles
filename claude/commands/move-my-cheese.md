---
name: move-my-cheese
description: Take over a PR — rebase/merge main, diagnose CI failures, fix tests and conflicts, push fixes. The cheese has moved; go get it.
argument-hint: <PR number>
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch
---

Take over and rescue PR **#$ARGUMENTS** — the cheese has moved, time to find it.

This command automates the "PR rescue" workflow: fetch context, diagnose failures, merge main, fix issues, push.

---

## Phase 1 — Recon

Gather all context about the PR in parallel:

1. **PR metadata**: `gh pr view $ARGUMENTS --json title,body,headRefName,baseRefName,state,mergeable,mergeStateStatus,url`
2. **CI status**: `gh pr checks $ARGUMENTS` — identify failing checks
3. **PR diff**: `gh pr diff $ARGUMENTS` — understand what changed
4. **Failed logs**: For each failing check, fetch logs with `gh run view <run-id> --log-failed`

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

### Conflict Resolution

If merge conflicts occur:
1. List conflicting files
2. For each conflict, read the file and resolve intelligently:
   - Prefer the PR's intent over main's formatting changes
   - Keep both sides when they're additive (new features on both sides)
   - Ask the user for ambiguous conflicts (logic changes on both sides)
3. Stage resolved files and commit the merge

If no conflicts: report clean merge and move on.

---

## Phase 3 — Diagnose & Fix

### CI Failure Analysis

Categorize each CI failure:

| Category | Action |
|---|---|
| **Infra flake** (503, timeout, OOM) | Note it — will resolve on re-run |
| **Test failure** (assertion error) | Fix the code or test |
| **Lint/format** (shellcheck, prettier) | Auto-fix |
| **Merge artifact** (conflict markers) | Should have been caught in Phase 2 |

### Run Tests Locally

Run the project's test suite to verify:
- Use the test runner from the project (bats, pytest, jest, etc.)
- If tests pass, the CI failure was likely infra
- If tests fail, diagnose and fix

### Fix Strategy

For real failures:
1. Read the failing test to understand what's expected
2. Read the code under test
3. Fix the minimal change needed
4. Re-run tests to verify

Use `whey-drainer` agent for running tests (keeps verbose output out of context):
```
Task(subagent_type="whey-drainer", model="haiku", prompt="Run all tests and report pass/fail summary.")
```

---

## Phase 4 — Push & Report

1. Commit any fixes with a conventional commit message via `/commit`
2. Push to the PR branch: `git push origin HEAD:<pr-branch>`
3. Report summary:
   - What was wrong (conflicts, test failures, infra flakes)
   - What was fixed
   - What will resolve on CI re-run
   - Link to the PR

If the CI failure was purely infrastructure, offer to re-run: `gh run rerun <run-id> --failed`

---

## Error Recovery

- If the PR branch can't be fetched, check if it was force-pushed or deleted
- If merge produces too many conflicts (>5 files), ask the user before proceeding
- If tests fail after fixes, run the wrecker-drainer feedback loop (up to 3 rounds)
- Never force-push to the PR branch without asking
