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
| Understand | **lookup** | Route to LSP/Context7 for symbol types, cross-refs, API docs |
| Diagnose | **diff** | Smoke-test the merged state for obvious issues |
| Fix | **chisel** | Edit conflict markers, patch test assertions |
| Build | **make** | Build/check with output isolation (forked subagent) |
| Test | **make test** | Run tests with output isolation (forked subagent) |
| Assertion check | **tdd-assertions** | Strengthen weak test assertions after fixing tests |
| Quality sweep | **age**, **ricotta-reducer**, **respond** | Parallel review agents (see Phase 3b) |
| Commit | **commit** | Stage and commit fixes (conventional format) |
| Push | **gh** | Push to PR branch, re-run failed CI |

## Parallel LSP Strategy

Two tiers of LSP usage — one for move-my-cheese itself, one for the sub-agents it always spawns:

### move-my-cheese (Phase 3a diagnosis)

| Context | LSP approach |
|---|---|
| Running standalone (user invoked `/move-my-cheese`) | Direct LSP via `/lookup` — single session, no contention |
| Running in a worktree (dispatched by cheese-convoy) | **lsp-probe** — batch queries, release server, stay lightweight |

**How to detect worktree context**: Working directory is under a `.worktrees/` path, or the prompt mentions "worktree" or "parallel agents".

**lsp-probe pattern** for diagnosis (Phase 3a):

```
Agent(subagent_type="lsp-probe", prompt="queries:\n  1. hover <file>:<line>\n  2. findReferences <file>:<line> symbol=<name>\n  3. documentSymbol <file>")
```

Batch all LSP queries for a diagnosis pass into one probe invocation.

### Quality sweep sub-agents (Phase 3b)

**Always use lsp-probe** — regardless of whether move-my-cheese is running standalone or in a worktree. The sweep agents (age sub-agents, ricotta-reducer) are spawned as concurrent sub-agents doing read-only analysis. They should never hold a persistent LSP server. The Phase 3b agent prompts signal this explicitly.

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
- Unresolved review comments (yes/no — needed to decide if Phase 3b launches `fromage-fort`)

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

If build fails, understand the failing symbols before fixing with **chisel**:

- **Standalone**: Use `/lookup` — routes to LSP for types/cross-refs, Context7 for external APIs
- **Worktree context** (dispatched by cheese-convoy): Batch failing symbols into a single **lsp-probe** call — hover for types, findReferences for cross-refs — then fix with chisel

Never grep dependency caches.

### Run Tests (make test)

Run `/make test` to execute the test suite with output isolation:

```
Skill(skill="make", args="test")
```

If tests pass: the CI failure was likely infra. Move to Phase 3b.

### Fix Strategy (lookup/lsp-probe + scout + chisel skills)

For real test/build failures:

1. Understand the failing symbol — type mismatches, missing methods, changed APIs:
   - **Standalone**: `/lookup` (routes to direct LSP or Context7)
   - **Worktree context**: Batch all failing symbols into one `lsp-probe` call (hover + findReferences)
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

After Phase 3a fixes are stable (build passes, tests pass), invoke the `age` skill and launch parallel review agents:

```
# Invoke the age skill inline — it spawns 6 review sub-agents directly (no nesting).
# Pass lsp-probe hint so sub-agents batch LSP queries.
# Follow the age skill protocol: identify scope, launch 6 agents, merge findings.
# Scope: changes on this branch vs origin/main. Surface findings >= 50.
# LSP strategy: use lsp-probe for batched queries.

# In parallel with the age skill's sub-agents, also launch:
Agent(subagent_type="ricotta-reducer", prompt="Review the changed files on this branch vs origin/main. Strip genAI bloat, speculative abstractions, unnecessary docs. Categorize by DELETE/INLINE/UNDOCUMENT/DECOUPLE. Only surface findings >= 50 confidence. LSP strategy: use lsp-probe for batched queries (findReferences to verify dead code, hover for coupling checks) — batch your LSP needs into one probe call rather than holding a server for the session.")

# Only if Phase 1 recon found unresolved review comments:
Agent(subagent_type="fromage-fort", prompt="Triage unresolved review comments on PR #$ARGUMENTS. Score each 0-100, fix >= 50, push back < 30, report 30-49 for user decision.")
```

| Agent/Skill | What it catches |
|---|---|
| **age skill** (6 sub-agents) | Safety, complexity, encapsulation, YAGNI, spec adherence, history/risk modifiers |
| **ricotta-reducer** | AI slop + de-slop patterns, over-abstraction, comment pollution, dead code |
| **fromage-fort** | Unresolved reviewer comments — triages and fixes >= 50 confidence |

### Apply Sweep Findings

After all three agents return:

1. **Collect findings >= 50 confidence** from age and de-slop reports
2. **Apply fixes** using chisel — these are typically:
   - Removing unnecessary abstractions or dead code (de-slop)
   - Fixing complexity budget violations (age)
   - Addressing reviewer comments that fromage-fort auto-fixed
3. **Re-run `/make test`** to verify fixes didn't break anything
4. If fromage-fort fixed code, those changes are already in the working tree — just verify and commit together

If any finding is < 50 confidence, **ask the user** before acting on it.

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
