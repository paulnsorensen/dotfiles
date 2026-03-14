---
name: move-my-cheese
description: Take over a PR — rebase/merge main, diagnose CI failures, fix tests and conflicts, push fixes. The cheese has moved; go get it.
argument-hint: <PR number>
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch
---

Take over and rescue PR **#$ARGUMENTS** — the cheese has moved, time to find it.

This command automates the "PR rescue" workflow: fetch context, diagnose failures, merge main, fix issues, run a quality sweep, push.

## Skills Used

This command orchestrates across multiple skills:

| Phase | Skill | Why |
|---|---|---|
| Recon | **gh** | PR metadata, CI checks, failed run logs, diff |
| Explore | **scout** | Search codebase for test files, CI config, related code |
| Understand | **lookup** | Route to LSP/Serena/Context7 for symbol types, cross-refs, API docs |
| Diagnose | **diff** | Smoke-test the merged state for obvious issues |
| Fix | **chisel** | Edit conflict markers, patch test assertions |
| Build | **make** | Build/check with output isolation (forked subagent) |
| Test | **make test** | Run tests with output isolation (forked subagent) |
| Assertion check | **tdd-assertions** | Strengthen weak test assertions after fixing tests |
| Quality sweep | **age**, **ricotta-reducer**, **respond** | Parallel review agents (see Phase 3b) |
| Commit | **commit** | Stage and commit fixes (conventional format) |
| Push | **gh** | Push to PR branch, re-run failed CI |

## Progress Tracking

At command start, call `TaskCreate` for all 5 phases. Mark `in_progress` at phase start, `completed` at phase end.

| Phase | Subject | activeForm |
|---|---|---|
| 1 | Recon PR state | Gathering PR context |
| 2 | Checkout and merge main | Merging main into PR |
| 3a | Diagnose and fix failures | Diagnosing and fixing failures |
| 3b | Quality sweep | Running parallel review agents |
| 4 | Push fixes and report | Pushing fixes |

---

## Phase 1 — Recon (gh skill)

Use the `/gh` skill to gather PR context. MCP tools are preferred (sandbox-safe):

```
# MCP — get PR metadata
pull_request_read(pullNumber=$ARGUMENTS)

# CLI fallback — diff and CI checks (no MCP equivalent)
gh pr diff $ARGUMENTS --stat
gh pr checks $ARGUMENTS
```

For any failing checks, fetch logs (CLI-only):
```bash
gh run view <run-id> --log-failed
```

Summarize findings:
- PR title and branch
- Merge status (clean, conflicts, or blocked)
- CI failures (infra flake vs real test failure)
- Scope of changes (files touched, lines changed)
- Unresolved review comments (yes/no — needed to decide if Phase 3b runs `/respond`)

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

## Phase 3a — Diagnose & Fix

### CI Failure Analysis

Categorize each CI failure from Phase 1 recon:

| Category | Action |
|---|---|
| **Infra flake** (503, timeout, OOM) | Note it — will resolve on re-run |
| **Test failure** (assertion error) | Fix the code or test |
| **Lint/format** (shellcheck, prettier) | Auto-fix with chisel |
| **Build failure** (compile error, type error) | Fix with lookup + chisel |
| **Merge artifact** (conflict markers) | Should have been caught in Phase 2 |

### Smoke Check (diff skill)

Run `/diff` first — catch obvious merge artifacts before wasting a build/test cycle:
- Conflict markers left behind
- Debug statements
- Silent failures in merged code

### Build Check (make skill)

Run `/make` to verify the merged code compiles. This forks a subagent that absorbs verbose output and returns structured errors:

```
Skill(skill="make")
```

If build fails, use `/lookup` to understand the failing symbols (types, signatures, cross-refs) before fixing with **chisel**. `/lookup` routes to the right tool — LSP for types, Serena for cross-refs, Context7 for external API docs. Never grep dependency caches.

### Run Tests (make test)

Run `/make test` to execute the test suite with output isolation:

```
Skill(skill="make", args="test")
```

If tests pass: the CI failure was likely infra. Move to Phase 3b.

### Fix Strategy (lookup + scout + chisel skills)

For real test/build failures:
1. Use `/lookup` to understand the failing symbol — type mismatches, missing methods, changed APIs
2. Use **scout** (`rg` for error messages, `fd` for test files) to locate the failing test
3. Read the failing test and the code under test
4. Fix with **chisel** — minimal change, `sd` for pattern fixes, Edit for precise patches
5. Re-run via `/make test` to verify

After fixing any tests, apply `/tdd-assertions` to strengthen weak assertions — existence checks, catch-all errors, length-only checks, and no-crash-as-success patterns. AI-generated test fixes are especially prone to these.

If tests fail after fixes, run the fix-and-verify loop (up to 3 rounds):
```
Agent(subagent_type="roquefort-wrecker", prompt="Investigate test failures: <details>. Fix test bugs, score code bugs 0-100.")
```
Then apply `/tdd-assertions` to the wrecker's output and re-run `/make test` to verify.

---

## Phase 3b — Quality Sweep (parallel agents)

After Phase 3a fixes are stable (build passes, tests pass), launch three review agents **in parallel**:

```
# Launch in a SINGLE message — all as Agent tool calls for true parallelism:

Agent(subagent_type="fromage-age", prompt="Review the changes on this branch vs origin/main. Staff Engineer review against Sliced Bread architecture, engineering principles, and complexity budgets. Only surface findings >= 75 confidence.")

Agent(subagent_type="ricotta-reducer", prompt="Review the changed files on this branch vs origin/main. Strip genAI bloat, speculative abstractions, unnecessary docs. Categorize by DELETE/INLINE/UNDOCUMENT/DECOUPLE. Only surface findings >= 75 confidence.")

# Only if Phase 1 recon found unresolved review comments:
Agent(subagent_type="cheese-responder", prompt="Triage unresolved review comments on PR #$ARGUMENTS. Score each 0-100, fix >= 75, push back < 50, report 50-74 for user decision.")
```

| Agent | What it catches |
|---|---|
| **fromage-age** | Architecture violations, complexity budget breaches, principle violations |
| **ricotta-reducer** | AI slop + de-slop patterns, over-abstraction, comment pollution, dead code |
| **cheese-responder** | Unresolved reviewer comments — triages and fixes >= 75 confidence |

### Apply Sweep Findings

After all three agents return:

1. **Collect findings >= 75 confidence** from age and de-slop reports
2. **Apply fixes** using chisel — these are typically:
   - Removing unnecessary abstractions or dead code (de-slop)
   - Fixing complexity budget violations (age)
   - Addressing reviewer comments that /respond auto-fixed
3. **Re-run `/make test`** to verify fixes didn't break anything
4. If respond fixed code, those changes are already in the working tree — just verify and commit together

If any finding is < 75 confidence, **ask the user** before acting on it.

---

## Phase 4 — Push & Report (commit + gh skills)

1. **Commit** all fixes via the `/commit` skill (conventional format, never --no-verify)
   - Merge conflict resolution gets its own commit (from Phase 2)
   - CI/test fixes get a commit (from Phase 3a)
   - Quality sweep fixes get a commit (from Phase 3b) — only if there were changes
2. **Push** to the PR branch via `/gh`: use MCP `push_files` or `git push origin HEAD:<pr-branch>`
3. If CI failure was purely infrastructure, offer to re-run: `gh run rerun <run-id> --failed` (CLI-only)

Report summary:
- What was wrong (conflicts, test failures, infra flakes)
- What was fixed (including quality sweep findings)
- Sweep scores: age report summary + de-slop fix count + respond triage table
- What will resolve on CI re-run
- Link to the PR

---

## Error Recovery

- If the PR branch can't be fetched, check if it was force-pushed or deleted
- If merge produces too many conflicts (>5 files), ask the user before proceeding
- If tests fail after 3 fix rounds, surface remaining failures to the user
- If quality sweep agents fail or timeout, report partial results and continue to Phase 4
- Never force-push to the PR branch without asking
