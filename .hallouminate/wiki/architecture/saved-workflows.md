# Saved Claude workflows

Source of truth is `claude/workflows/*.js`. `dots sync` copies the whole dir into `chezmoi/dot_claude/exact_workflows/` (`.sync-lib.sh` → `sync_claude_chezmoi_sources`), and chezmoi applies it to `~/.claude/workflows/`, where each script becomes an invocable `/name` skill.

**Why the layering matters:**

- `chezmoi/dot_claude/exact_workflows/` is **gitignored** — it is an assembled artifact, not source. Never edit or `git add` it; commit `claude/workflows/` only.
- No registry listing needed: the whole dir syncs, unlike MCPs/hooks/agents which are selected via `chezmoi/.chezmoidata/claude.yaml`.
- Gate: `just smoke` runs `tests/workflows-test.sh`, which execs `node --test tests/workflows/*.test.mjs tests/t3-run/*.test.mjs` (skips, not fails, when `node` is off `PATH` outside CI). `tests/workflows/harness.mjs` stubs the runtime globals and drives each saved workflow's `run()` offline; `tests/workflows/all-parse.test.mjs` covers every script in `claude/workflows/`. `just check` fans `smoke` out alongside the other legs via GNU parallel. This replaced the old grep-based `tests/workflows-parse.sh` guard (PR #436, `docs/adr/workflow-test-harness-00{1,2,3}.md`); a regression test in `all-parse.test.mjs` now asserts that script and its justfile reference stay gone, so don't resurrect the name.

**Current inventory note (PR #486, restructured 2026-07-21):** `cheese-factory.js` replaced `curd-flock.js` outright (no alias) — the spec-driven easy-cheese pipeline, now: Resolve → Criteria → Decompose → Advise → per-curd chain (cook→taste→press) → Integrate barrier (merge surviving curd branches) → whole-diff Age (fan-out via `age-fanout` above the scale threshold) → routed per-curd Cure → Re-age → Verify → Done → Plate. Criteria, Advise, Verify, and Done (ADR-015..017) gate Cook and Plate. A plan the advisor does not approve returns `status: 'blocked'`. The final report adds the `verification` and `advice` fields. Design rationale: [[adr/cheese-factory-workflow]] (ADR-001..007 — ADR-006 moved review from per-curd to the barrier). `age-fanout.js` is the shared child workflow (Packet → one reviewer per /age dimension → Reconcile) also used by `move-my-cheese.js`'s threshold-gated Age ([[architecture/move-my-cheese-workflow]]); its prompts carry zero copied review semantics — agents read the deployed `~/.claude/skills/age/` files at runtime (ADR-007). Any doc still pointing at curd-flock or per-curd age is stale.

**Skill tool inside workflow agents (smoke-verified, 2026-07-20):** agents spawned by a dynamic workflow's `agent()` DO have the Skill tool and can invoke skills successfully (verified by a one-agent throwaway workflow: `Skill(skill='justfile')` loaded instructions; the agent also sees the full skill listing). This is the premise cheese-factory's real-skill phase agents rest on (ADR-001) — no prompt-modeled fallback needed.

**Farming ground (why `/session-harvest` exists):** every ad-hoc Workflow-tool invocation persists its script under `~/.claude/projects/<project>/<session-uuid>/workflows/scripts/<name>-wf_*.js`. Shapes that recur there ≥2× under different names are promotion candidates — a 2026-07 sweep found 61 such scripts and promoted three (`triage-sweep`, `curd-flock` — since replaced by `cheese-factory`, `sliced-bread-audit`). The `/session-harvest` workflow automates that sweep; it requires `sinceIso` as an arg because workflow scripts cannot call `Date.now()`.

**Script constraints** (violations break at runtime, not parse time): pure-literal `export const meta` first; only `agent`/`parallel`/`pipeline`/`phase`/`log`/`args`/`budget`/`workflow` globals; no `Date.now()`/`Math.random()`/argless `new Date()`; no fs/require — path defaults must resolve inside an agent, not in script scope. Inside interleaving `pipeline()` stages use per-agent `opts.phase`, never bare `phase()` (shared mutable state races across items — the one class of finding a 2026-07 review pass caught in otherwise-clean scripts).

**Child workflows (`workflow()`, first used 2026-07-21):** `workflow('name', args)` runs a saved workflow inline as a sub-step (one nesting level only; shares budget/concurrency). The offline harness's default `workflow` global throws — tests override it via `run()`'s overrides object (`workflow` is in `GLOBALS`, `tests/workflows/harness.mjs`). Parents must try/catch the call and fall back gracefully (age-fanout callers fall back to a single-reviewer age).

**Backtick gotcha** (PR #463): the sandbox-guard test (`tests/workflows/all-parse.test.mjs`, "no workflow reaches for a global outside the Workflow runtime surface") blanks string literals with a character state machine that does **not** understand regex literals. A backtick inside a regex literal (e.g. `match(/`+/g)` written with a literal backtick) flips the stripper into template-string state, wrecking quote parity for the rest of the file — later prompt prose leaks into the identifier scan and the test fails on an unrelated word (e.g. "process") far from the real cause, which reads as a pre-existing failure. In workflow scripts, spell backticks as the escape ` whenever they appear in code position (regex literals, char comparisons); backticks *inside* quoted strings are fine.

**Worktree gotcha** (PR #436 review, updated 2026-10-16): git refuses a second checkout of a branch that another worktree holds. So a stage in a fresh isolated worktree never checks out a shared branch. It fetches the branch by name and detaches, or it creates a stage-owned local branch. It pushes with `git push origin HEAD:<branch>` (see `pinStep` and `writerStep` in `claude/workflows/move-my-cheese.js`).

- Run git from the worktree itself, as plain separate commands. The isolation guard refuses a git command that it cannot prove stays inside the worktree, such as `cd <path> && git ...` or a shell loop over branches.
- Fetch the base branch explicitly, for example `git fetch origin <base>`, before `git switch -c <new> origin/<base>` or a diff against it. A fresh worktree can lack the remote-tracking ref of a stacked base branch.
- Fetch a branch that may not exist yet in a separate command. In a multi-ref `git fetch`, one missing ref fails the whole command with `couldn't find remote ref`.
- To hand work to a later stage, return the worktree path or the pushed commit through the schema (for example `worktree_path` from `git rev-parse --show-toplevel`). Do not ask the later stage to check out the same branch.

**Resume inputs:** a Workflow cannot pause, so a gated workflow returns its state and the caller passes it back in a new run.

- move-my-cheese takes `{ prs, plan, approve }`, plus `revise` or `answers`. `plan` is the landing from a `needs-approval` or `needs-input` result, and `approve` is its digest. A changed plan fails the digest check. `answers` applies only to a landing with open questions.
- cheese-board takes `state`, `digest`, `answers`, and `lanes` (PR #1316). `answers` maps a question or its 1-based number to an answer. An unknown key or a repeated answer blocks the run. PR #1361 (open, pending its base PR #1358) holds research questions at the spec checkpoint, so brie-ground runs only for the questions the user approves.
- cheese-factory has no resume input on main. A `resume` object that skips Criteria and Ground has no PR yet.

**vm-realm test gotcha** (PR #486): `tests/workflows/harness.mjs` runs workflow scripts in a `node:vm` context, so objects/arrays the workflow returns carry foreign prototypes — `assert.deepEqual` from `node:assert/strict` fails with "Values have same structure but are not reference-equal" even when contents match. Convention: spread-clone (`{ ...obj }`), `Array.from(arr)`, or JSON round-trip before `deepEqual`. Fixture objects built in the *test* realm and passed through mocks compare fine; only workflow-realm-constructed values trip it.

**Strategy layer (2026-10-14):** `cheese-board.js` sits above `cheese-factory`. It runs `triage-sweep` as a child, then synthesizes a strategy and mints resolver-path mini-specs that form a `factory_queue`. See [[architecture/cheese-board-workflow]].

**Host-fit failures (session analytics, 2026-10-11 to 2026-10-14):** 54 runs of cheese-board, cheese-factory, and move-my-cheese used about 23.5M tokens, and none returned `ok`. The causes were the host setup, not model quality:

- Workflow agents run under the same PreToolUse hooks as the parent. The tool-reroute hook denies shell `grep`/`cat`/`sed` on a file over 16 KiB, so `grep -Fq` criteria checks never ran and clean curds ended `partial` (PR #1324: checks run marked tests; a guard denial is `unrun`).
- The plan advisor blocked 8 of 22 cheese-factory runs on its own payload: the single-pass curd sent `brief: null` and `files: []`. Round two also reversed round-one concerns (PR #1322: single-pass brief, round-two resolve-only rule).
- 7 runs died on argument parsing (PR #1323). The runtime bans `Date`, so cheese-board still needs an explicit stamp.
- 19 of 28 move-my-cheese runs were gate hops with no build, because a Workflow cannot pause and the caller round-trips the plan.
- The auto-mode classifier denies a relaunch of an edited `scriptPath` copy as `[Self-Modification]`. Edit the source, `dots sync`, and relaunch by name.

**Parallel writers and checkpoint cost (session analytics, 2026-10-12 to 2026-10-16):** 48 move-my-cheese runs over 7 sessions landed no plan end to end. From 2026-10-12 to 2026-10-15, 20 of 36 runs that returned a result (56%) were gate hops, and each hop reran survey, the planners, and the advisor. The skill's fan-out sources cover read-heavy work, so they did not cover parallel writers on shared git state. The skill now asks for these rules:

- A preflight stage checks the interpreter, the test runner, `gh` auth, and the host guards before the first planner. Judges ran a Python without pytest and recorded 12 false failures.
- Writers integrate in task-graph order, with a conflict probe after each target, not at one final barrier. A plan that waits for a merge after publish is rejected.
- Gate state lives in a file by default, and a resume skips survey, the planner fan-out, and the advisor. A moved default branch or PR head gets a rebase and recheck, not a replan.
- Git and GitHub plumbing runs in one tested script with JSON output, not in English steps in prompts.

Rules: `skills/claude-workflows/references/parallel-writers.md`, `budget-recovery.md`, and the Preflight and live-boundary sections of `environment.md`.

The design rules live in `skills/claude-workflows/references/environment.md`; the cases are eval data in `skills/claude-workflows/evals/`. Run records for counting: `~/.claude/projects/*/<session>/workflows/wf_*.json`.

Related: [[architecture/cheese-board-workflow]], [[architecture/agents-dir]], [[operations/sync-and-chezmoi]], [[adr/cheese-factory-workflow]], [[architecture/move-my-cheese-workflow]].

*Source: main-clone wiki page (untracked) + cheese-factory-workflow implementation session (PR #486) + barrier-age restructure session (2026-07-21) + cheese workflow session-analytics review (2026-10-14) · Updated: 2026-10-14 · Supersedes: untracked main-clone copy of this page*
