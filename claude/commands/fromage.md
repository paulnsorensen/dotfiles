---
name: fromage
description: Complete Fromage Development Platform — intelligent cheese-making pipeline that adapts to task complexity. Replaces /cheese and /curdle.
argument-hint: <what you want to build or fix>
---

Execute the Fromage development pipeline for: **$ARGUMENTS**

Full cheese-making process — raw milk to packaged wheel. Assesses complexity and skips phases that don't add value.

### When to use `/fromage` vs `/fromagerie`

- **`/fromage`**: Single coherent feature or fix — spec → explore → plan → implement → test → review → PR
- **`/fromagerie`**: Feature that decomposes into 5-30 independent work units — front-loads exploration, splits into non-overlapping atoms, executes foundation work sequentially, dispatches parallel worktree agents, then triggers `/cheese-convoy`. Requires a spec from `/spec`.

Rule of thumb: if the work is sequential and interrelated, use `/fromage`. If the spec spans many independent files/slices, use `/fromagerie`.

## Context Passing

Each phase builds on prior phases. When launching agents, always include:
- **Slug**: kebab-case task identifier derived in Phase 0 (used for spec files, branch names)
- **Spec summary**: from Phase 2, or the original request if spec was skipped
- **Exploration findings**: from Phase 3, if it ran (entry points, blast radius, key files)
- **Plan steps**: from Phase 4, scoped to the agent's chunk
- **Changed files**: accumulated list, updated after each Cook/Press cycle
- **Design skill**: from Phase 4 plan or `--skill` flag (skill file content injected into Cook)

## Orchestrator Token Discipline

"Orchestrator" means the Claude session executing this `/fromage` command — not a separate agent. It has full tool access.

The orchestrator reads ONE thing: the spec. Everything else is delegated.

The orchestrator MUST NOT:
- Use Read, Grep, or Glob on codebase files (delegate to Culture/Cook agents)
- Run build/test commands directly (delegate to whey-drainer)
- Read subagent full reports (work from their returned summaries)

The orchestrator SHOULD:
- Read the spec (`.claude/specs/<slug>.md`) — this is the contract that drives all phase decisions. One read, justified.
- Work from subagent summaries, not full reports
- Keep its own context focused on phase orchestration decisions

EXCEPTION: Reading small config files (<2K chars) for phase gating decisions is acceptable (e.g., checking if a test framework exists).

## Spec Distribution

After exiting plan mode and reading the spec, the orchestrator pre-digests it for downstream agents:

1. Extract a **spec summary** (<2K chars): what's being built (bullets), constraints, scope boundaries (what's OUT)
2. For specs >5K chars, write the full spec to `$TMPDIR/fromage-spec-<slug>.md` using the Write tool (TMPDIR is sandbox-allowed, no permission prompt)

Distribution — **prefer inline** to avoid temp file overhead:
- **Curdle**: spec inline if <5K, otherwise temp file path (Curdle reads it itself). Curdle is the planner; it needs every constraint and boundary.
- **Culture**: spec summary inline in prompt (enough to scope exploration)
- **Cook**: relevant plan steps + spec summary inline (plan is the primary input)
- **Press/Age**: spec summary + changed files list inline (enough to evaluate against)

## Agent Turn Limits

Always set `max_turns` when spawning Task agents:

| Agent | max_turns | Rationale |
|-------|-----------|-----------|
| fromage-culture | 40 | Exploration, bounded |
| fromage-curdle | 30 | Planning, should be decisive |
| fromage-cook | 80 | Implementation, largest scope |
| fromage-press | 50 | Testing + feedback loops |
| fromage-age | 30 | Review, read-only |
| whey-drainer | 15 | Just runs tests |
| roquefort-wrecker | 25 | Writes + runs tests |
| research (any) | 15 | Should find answer fast or bail |

If an agent hits its limit, it returns partial results. The orchestrator decides whether to spawn a continuation agent or proceed with what it has.

## Agent Permission Modes

After exiting plan mode, spawn implementation agents with `mode: "acceptEdits"` for uninterrupted execution:

| Agent | Mode | Rationale |
|-------|------|-----------|
| fromage-culture | default | Read-only exploration |
| fromage-curdle | plan | Planning, needs approval |
| fromage-cook | **acceptEdits** | Implementation, writes freely |
| fromage-press | **acceptEdits** | Testing, writes test files |
| fromage-age | default | Read-only review |
| whey-drainer | default | Runs tests only |
| roquefort-wrecker | **acceptEdits** | Writes + runs tests |
| research (any) | default | Read-only research |

## Phase 0 — Assess

### Hard Gate: Worktree Check

Check if you are in a git worktree: run `git rev-parse --git-dir` — if output contains `/worktrees/`, you're in one. If NOT:

1. **Stop.** Do not proceed.
2. Ask: "You're on the main branch. Want me to create a worktree with `/worktree <slug>`?"
3. Only proceed after user is on a worktree OR explicitly says "continue on main".

This gate is **never skipped**.

### Derive Slug

Generate a kebab-case slug from the request (<30 chars). Examples:
- "add dark mode support" → `add-dark-mode`
- "fix login timeout bug" → `fix-login-timeout`

The slug is used for: spec file (`.claude/specs/<slug>.md`), worktree branch, PR title context.

### Parse Flags

If `$ARGUMENTS` contains `--skill <name>`:
1. Extract the skill name and remove the flag from the arguments
2. Verify `claude/skills/<name>/SKILL.md` exists (error if not found)
3. Carry the skill name through all subsequent phases
4. This overrides any skill detected by Curdle

### Classify Complexity

| Level | Signals | Examples |
|---|---|---|
| **Trivial** | Typo, config tweak, single obvious line | Fix README typo, update env var |
| **Small** | Single-file fix, clear scope | Bug fix, add alias, small refactor |
| **Medium** | Multi-file feature, some design needed | New command, API endpoint, component |
| **Large** | Architecture change, many files, design decisions | New system, major refactor, cross-cutting concern |

Announce complexity and show which phases run vs skip:

| Phase | Trivial | Small | Medium | Large |
|---|---|---|---|---|
| 2. Pasteurize | skip | skip | run | run |
| 3. Culture | skip | skip | run | run |
| 4. Curdle | skip | skip | run | run |
| 5. Cut | skip | run | run | run |
| 6. Cook | run | run | run | run |
| 7. Press | skip | ask | run | run |
| 8. Age | skip | skip | run | run |
| 9. Package | run | run | run | run |

**ask** = ask user before running. User can also override any skip → run.

### Plan Mode Gate (Medium/Large only)

For **medium** and **large** tasks, call `EnterPlanMode` after displaying the phase matrix. This puts the orchestrator into read-only mode for Phases 1-4:

- Spec writes are delegated to sub-agents (orchestrator cannot write files)
- Exploration and planning happen without risk of accidental edits
- `ExitPlanMode` at Checkpoint 2 transitions to implementation with pre-approved permissions

For **trivial** and **small** tasks, skip plan mode — proceed directly to implementation phases.

---

## Phase 2 — Pasteurize (Opus, interactive)

### Spec Detection Gate

Before starting interactive requirements, check if a spec already exists:

1. **Spec exists** (`.claude/specs/<slug>.md`): Read it, summarize key constraints and quality gates, then confirm with user ("This spec covers X, Y, Z — still current? Proceed to exploration?"). Skip the full Pasteurize dialogue but **do not skip the approval checkpoint**. Proceed to Culture after confirmation.
2. **No spec + medium/large complexity**: Suggest `/spec` first: "This looks like a medium+ feature. Want to run `/spec` to shape requirements before we build? Or should I gather requirements inline?"
3. **No spec + trivial/small**: Proceed with inline Pasteurize (below).

### Interactive Requirements (when Pasteurize runs)

Interactive requirements gathering — a conversation, not an interrogation.

1. Parse the request: what's clear vs ambiguous
2. Ask clarifying questions naturally (don't dump a list)
3. Invoke `/research` when external research is needed
4. **Library discovery**: Search for existing libraries/packages that could accelerate implementation. Use octocode (`packageSearch`) and Context7 (`resolve-library-id` → `query-docs`) to find candidates. Evaluate: maturity, maintenance activity, API fit, **license compatibility** (see below).
5. **Quality gates** (mandatory when this phase runs): Before writing the spec, ask with lettered options:

```
What commands must pass for this to be considered done?
   A. cargo test && cargo clippy
   B. npm test && npm run typecheck
   C. pytest && mypy
   D. Other: [specify — e.g., just test, dots test, make check]

Should we include integration/E2E verification?
   A. Yes, specific paths: [specify]
   B. Unit tests are sufficient
   C. Manual verification checklist
```

Capture the answer in the spec under a `## Quality Gates` section. These commands become the contract for Phase 9 (Package) — whey-drainer runs exactly these commands.

6. Write spec to `.claude/specs/<slug>.md` — include quality gates and any recommended libraries with justification

**Plan mode note**: The orchestrator is in plan mode and cannot write files directly. Delegate spec writing to a haiku agent — pass the spec content in the prompt, the agent writes to `.claude/specs/<slug>.md` and returns confirmation. Similarly, delegate `gh repo view` license checks to a research agent.

### License Awareness

Check repo visibility (`gh repo view --json isPrivate -q '.isPrivate'`). For **private repos**: avoid copyleft licenses (GPL, AGPL, LGPL, MPL) — prefer MIT, Apache-2.0, BSD, ISC, or Unlicense. For **public/open-source repos**: any OSI-approved license is acceptable, but note copyleft obligations in the spec.

**>>> CHECKPOINT 1: Requirements <<<**

Present a structured summary, then ask with lettered approval options:

1. **What's being built** (2-3 bullets), constraints, scope boundaries (what's OUT)
2. **Quality gates** — the commands that must pass (from step 5)
3. **Red/Green paths** — end-to-end verification scenarios:
   - **Green:** User does X → system responds with Y → state becomes Z
   - **Red:** User does X incorrectly → system returns error → no state change

AskUserQuestion with options:
```
   A. Approve — proceed to exploration
   B. Edit — I want to change scope
   C. Add constraint — something's missing
   D. Pause — need to think
```

Do NOT proceed without approval — the spec is the contract.

**Skip**: Self-evident task or user provides a complete spec.

---

## Phase 3 — Culture (Sonnet, parallel)

Launch Culture agents (sonnet), each targeting a different aspect. Every agent applies the full trace checklist (data transformations, state changes, cross-cutting concerns, configuration) to their assigned scope.

### Agent Count by Complexity

| Complexity | Agents | Aspects |
|---|---|---|
| **Medium** | 2-3 | A, B, (C) |
| **Large** | 4-5 | A, B, C, D, (E) |

### Aspects

**`fromage-culture` agents (codebase exploration):**
- **Aspect A**: Entry points and existing patterns relevant to the change
- **Aspect B**: Blast radius — what existing code will be affected
- **Aspect C** (medium+): Architecture boundaries and integration points

**Separate research subagents (large only, run in parallel with Culture):**
- **Aspect D**: **External prior art** — spawn a `/research` agent (not `fromage-culture`) to scan how other projects solved similar problems. Use octocode for GitHub examples, Context7 for library docs, WebSearch for blog posts and design rationale. Write findings to `$TMPDIR/fromage-culture-<slug>-prior-art.md`.
- **Aspect E**: **Dependency and API landscape** — spawn a `/fetch` agent to assess external libraries, APIs, or services this change interacts with. Are there newer/better options? Version constraints? Write to `$TMPDIR/fromage-culture-<slug>-deps.md`.

After agents return:
1. **Synthesize cross-agent patterns** — what do 2+ agents agree on? Where do they contradict?
2. Pass summaries and full report temp file paths to Curdle
3. The planner can read the full reports if it needs deeper context

**Skip**: Single-file change, config tweak, obvious modification path.

---

## Phase 4 — Curdle (Opus)

Launch `fromage-curdle` (opus, permissionMode: plan) with exploration results, spec, and any library candidates from Phase 2 discovery. Produces a numbered implementation checklist.

If library candidates were identified, include them in Curdle's prompt with: package name, license, what it solves, and a note to adopt or justify building in-house. Curdle makes the final call.

**>>> CHECKPOINT 2: Plan <<<**

Present the plan as visible text output: architecture decision (one line), files to modify/create, build steps (parallel vs sequential), YAGNI boundaries, adopted libraries (if any).

Then AskUserQuestion with lettered options:
```
   A. Approve — start implementation
   B. Modify plan — adjust steps
   C. Re-explore — need more context
   D. Pause — hold off
```

Do NOT proceed without approval.

After user approves, call `ExitPlanMode` (with `allowedPrompts` below) to unlock edit mode. The user already approved the plan — this is a mechanical unlock, not a second review:

```json
{
  "allowedPrompts": [
    {"tool": "Bash", "prompt": "run tests and test frameworks"},
    {"tool": "Bash", "prompt": "file discovery with fd"},
    {"tool": "Bash", "prompt": "install dependencies"},
    {"tool": "Bash", "prompt": "run build commands"},
    {"tool": "Bash", "prompt": "write temp files for agent distribution"},
    {"tool": "Bash", "prompt": "git operations for commit and PR"}
  ]
}
```

After exiting plan mode, implementation agents spawn with `mode: "acceptEdits"` (see Agent Permission Modes table).

**Skip**: Obvious single-step change (trivial/small).

---

## Phase 5 — Cut (Sonnet, delegated)

Launch `roquefort-wrecker` (sonnet, `max_turns: 25`) to write failing smoke tests **before** implementation. This is TDD scaffolding, not adversarial testing (Phase 7).

### What Cut Produces

Skeleton tests that define the **contract** — function signatures, expected inputs/outputs, error cases. Tests MUST fail when first written (no implementation yet).

| Complexity | Scope | Example |
|---|---|---|
| **Small** | 1 test file, 3-6 test cases | `test_new_alias_defined`, `test_alias_runs_without_error` |
| **Medium** | 1-2 test files, 5-12 test cases | Unit tests for new functions + basic integration |
| **Large** | 2-4 test files, 10-20 test cases | Unit + integration skeletons + key edge cases |

### Orchestrator Prep (before spawning agent)

The orchestrator gathers context for the agent prompt — without reading source code:

1. **Spec summary** — from Phase 2 (or original request for small tasks)
2. **Plan steps** — from Phase 4, if it ran
3. **Test discovery** — run `fd -e test.sh -e bats -e test.py -e spec.ts -e test.ts --max-depth 3` to find existing tests. Pick 1-2 example paths for the prompt.
4. **Test location** — infer from discovery results (e.g., `tests/`, `__tests__/`, alongside source)

### Agent Prompt

Include all of the above in the `roquefort-wrecker` prompt:

```
MODE: TDD scaffold (not adversarial). Write failing smoke tests that define
the contract Cook agents will implement against.

**What's being built**: {spec_summary}
**Plan steps**: {plan_steps_or_request_summary}
**Test framework**: {detected_framework} (see examples: {example_test_paths})
**Test location**: {test_directory}

Write tests that:
- Assert expected function signatures exist (import succeeds)
- Assert expected outputs for core happy-path inputs
- Assert error handling for 1-2 obvious invalid inputs
- Use descriptive names: test_{feature}_{scenario}_{expected}

Do NOT write:
- Adversarial chaos tests (Phase 7 handles that)
- Tests for implementation details (only public API)
- Mocks for things that don't exist yet (stub minimally)

Every test MUST fail right now. If a test passes, it's testing the wrong thing.
Run tests after writing to confirm all fail.
```

### After Agent Returns

1. Collect test file paths from agent summary → add to `changed_files`
2. If agent reports any tests passed, flag for review (test is wrong or testing existing code)

**Skip**: No test framework detected, or trivial complexity.

---

## Phase 6 — Cook (Sonnet, inline + parallel)

Implementation. **Never skipped.**

### TDD Target

If Phase 5 (Cut) ran, Cook agents receive the test file paths in their prompt. Their job: **make those tests pass**. Include in each Cook prompt:
- Test file paths from Cut (in `changed_files`)
- Instruction: "Run these tests after implementation. All must pass before you're done."

**Small/trivial**: Implement directly inline. If Cut wrote tests, run them at the end.

**Medium/large**: Launch parallel `fromage-cook` agents (sonnet), split by independent modules. Each gets their chunk, relevant test files, and engineering principles.

### Wave Splitting

When dispatching Cook agents for medium/large tasks:
- Count the files each plan step touches
- If a single Cook agent would need to touch roughly 8+ files, split into multiple Cook agents (one per independent group) — this is a heuristic, not a hard limit; adjust based on file sizes and complexity
- Each Cook agent gets a fresh context window — this is the primary mechanism for preventing token accumulation
- Set `max_turns: 80` on each Cook Task invocation
- If a Cook agent hits max_turns, spawn a continuation agent for remaining items with the completed items noted in its prompt

### Research Discipline

When a Cook or Culture agent encounters an unfamiliar library/API:

1. **Codebase first**: Grep the codebase for existing usage patterns, or use `/trace` (ast-grep) for structural matches
2. **Context7 second**: Query library docs via Context7 MCP
3. **Package README third**: Use octocode to read the package README
4. **NEVER**: Read library source code. If the answer isn't in steps 1-3, return what you have and flag it as needing research.

Research agents spawned during Cook get `max_turns: 15`.

### Design Skill Injection

If a design skill was specified (via Curdle plan's "Design Skill" section or `--skill` flag):
1. Read `claude/skills/<skill-name>/SKILL.md`
2. Include the skill's markdown body in each Cook agent's prompt
3. Prefix with: "Apply the following design skill guidelines to your implementation:"

If no design skill applies, skip this step.

After cooks return, **verify plan completion** before proceeding:

1. Cross-check each Cook's "Plan Step Completion" table against the plan from Phase 4
2. If ANY steps are `partial` or `skipped`:
   - Decide: spawn a continuation Cook for remaining steps, OR ask the user
   - NEVER proceed to Press/Age with known incomplete work
3. Run `whey-drainer` (haiku) for regression check. Fix failures before moving on.

**Anti-pattern**: Do NOT accept a Cook report that shows all steps "done" but the whey-drainer reveals missing functionality. Re-check the Cook's claims against test results.

**Engineering principles**: Input validation at boundaries, fail fast and loud, loose coupling, YAGNI, real-world naming, immutable patterns, complexity budget (40 lines/fn, 300 lines/file, 4 params, 3 nesting).

**LSP integration**: All 7 LSP plugins are enabled globally. Cook agents get auto-diagnostics after edits and can use the `LSP` tool (`hover`, `findReferences`, etc.) for quick type verification — reduces the need for `cargo check` / `npm test` loops.

### Post-Cook Simplify Pass

After Cook completion is verified and whey-drainer passes, run the built-in `/simplify` as a hygiene sweep before Press/Age. This catches genAI bloat, redundant imports, and copy-paste artifacts that Cook agents leave behind.

- **Trivial/small**: skip (not enough code to warrant it)
- **Medium/large**: run `/simplify` targeting changed files
- If `/simplify` makes changes, re-run `whey-drainer` to confirm nothing broke

This is distinct from `/simplifier` (ricotta-reducer), which runs during Phase 8 as a scored architecture audit. `/simplify` is a fixer; `/simplifier` is an auditor.

---

## Phase 7 — Press (Sonnet)

Launch `fromage-press` (sonnet) for adversarial testing — chaos inputs, boundary assault, dependency failures, then happy path. All findings scored 0-100, >= 70 highlighted.

**Optional**: For tasks with external inputs, also launch `fromage-pasteurize` (sonnet) in parallel for security scanning.

### Wrecker-Drainer Feedback Loop

1. **Drain**: `whey-drainer` (haiku) runs all tests, classifies failures as test bugs vs code bugs
2. **Wreck** (if failures): `roquefort-wrecker` (haiku) investigates — fixes test bugs, scores code bugs
3. **Re-drain**: `whey-drainer` verifies fixes
4. **Iterate** up to 3 rounds. After 3: code bugs >= 70 get fixed or escalated, test bugs escalated if stuck, ambiguous (50-74) presented to user.

**Skip**: Cut phase had sufficient coverage, no test framework, or trivial change.

---

## Phase 8 — Age (Opus)

Launch two parallel reviews:

1. **`fromage-age`** (focused mode) — Include changed file paths. Orchestrates six parallel sub-agents:
   - **fromage-age-safety** — bugs, security, silent failures
   - **fromage-age-arch** — complexity budgets, nesting, file structure
   - **fromage-age-encap** — encapsulation, leaky abstractions, boundary violations
   - **fromage-age-yagni** — unjustified dead code, speculative abstractions, AI noise
   - **fromage-age-history** — git blame risk signals → per-file score modifiers
   - **fromage-age-spec** — spec drift, monkey patches, missing implementations

2. **`/simplifier`** (ricotta-reducer) — Architecture compliance audit against Sliced Bread. Produces scored DELETE/INLINE/UNDOCUMENT/DECOUPLE report. Complements Age: Age covers correctness and safety; ricotta-reducer specifically hunts structural bloat.

All findings scored 0-100, only >= 70 surfaced.

**Validation pass** (medium/large): For Age findings scored 75-89, launch a haiku agent to verify against actual code context. Discard findings that don't survive scrutiny. Findings >= 90 skip validation.

Present combined findings to user. Fix agreed issues inline.

**Skip**: Trivial change, single-line fix. For small tasks, run Age only (skip ricotta-reducer).

---

## Phase 9 — Package (inline)

### Hard Gate: Tests Must Pass (never skipped)

1. Use quality gates captured during Phase 2 spec read — pass those commands to `whey-drainer` (haiku). If no spec exists (trivial/small tasks), fall back to auto-detected test commands.
2. Failures: fix your changes, re-run (up to 3 iterations). Pre-existing failures: report and ask user.
3. **Do NOT commit with failing tests** unless user explicitly approves.

### Commit and PR (default: always)

1. `/commit` to stage and commit with conventional commit message
2. `/gh` to push and open a PR — **this is the default**. Do not ask "do you want a PR?" — just create it.

**Skip commit/PR only if**: User explicitly said "don't commit", "WIP", "no PR", or "manual control" earlier in the session. Test gate still runs regardless.

---

## Phase Transitions

One-line status between phases:
```
--- Phase 3 complete --- 7 key files, moderate blast radius. Moving to Curdle...
```

---

## Error Recovery

- Agent fails: retry once with refined prompt
- Unexpected results: pause and ask user
- Test failures in Press: wrecker-drainer loop (3 rounds max)
- Never proceed past a user approval gate without explicit approval
