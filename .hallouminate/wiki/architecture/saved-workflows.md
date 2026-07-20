# Saved Claude workflows

Source of truth is `claude/workflows/*.js`. `dots sync` copies the whole dir into `chezmoi/dot_claude/exact_workflows/` (`.sync-lib.sh` → `sync_claude_chezmoi_sources`), and chezmoi applies it to `~/.claude/workflows/`, where each script becomes an invocable `/name` skill.

**Why the layering matters:**

- `chezmoi/dot_claude/exact_workflows/` is **gitignored** — it is an assembled artifact, not source. Never edit or `git add` it; commit `claude/workflows/` only.
- No registry listing needed: the whole dir syncs, unlike MCPs/hooks/agents which are selected via `chezmoi/.chezmoidata/claude.yaml`.
- Gate: `tests/workflows-parse.sh` globs `claude/workflows/` and checks every script parses as an async function (runs inside `just check`).

**Current inventory note (PR #486):** `cheese-factory.js` replaced `curd-flock.js` outright (no alias) — the spec-driven easy-cheese pipeline: Resolve → Decompose → per-curd real-skill chain (cook→taste→press→age→cure→re-age) → Plate barrier. Design rationale: [[adr/cheese-factory-workflow]] (ADR-001..005). Any doc still pointing at curd-flock is stale.

**Skill tool inside workflow agents (smoke-verified, 2026-07-20):** agents spawned by a dynamic workflow's `agent()` DO have the Skill tool and can invoke skills successfully (verified by a one-agent throwaway workflow: `Skill(skill='justfile')` loaded instructions; the agent also sees the full skill listing). This is the premise cheese-factory's real-skill phase agents rest on (ADR-001) — no prompt-modeled fallback needed.

**Farming ground (why `/session-harvest` exists):** every ad-hoc Workflow-tool invocation persists its script under `~/.claude/projects/<project>/<session-uuid>/workflows/scripts/<name>-wf_*.js`. Shapes that recur there ≥2× under different names are promotion candidates — a 2026-07 sweep found 61 such scripts and promoted three (`triage-sweep`, `curd-flock` — since replaced by `cheese-factory`, `sliced-bread-audit`). The `/session-harvest` workflow automates that sweep; it requires `sinceIso` as an arg because workflow scripts cannot call `Date.now()`.

**Script constraints** (violations break at runtime, not parse time): pure-literal `export const meta` first; only `agent`/`parallel`/`pipeline`/`phase`/`log`/`args`/`budget`/`workflow` globals; no `Date.now()`/`Math.random()`/argless `new Date()`; no fs/require — path defaults must resolve inside an agent, not in script scope. Inside interleaving `pipeline()` stages use per-agent `opts.phase`, never bare `phase()` (shared mutable state races across items — the one class of finding a 2026-07 review pass caught in otherwise-clean scripts).

**Backtick gotcha** (PR #463): the sandbox-guard test (`tests/workflows/all-parse.test.mjs`, "no workflow reaches for a global outside the Workflow runtime surface") blanks string literals with a character state machine that does **not** understand regex literals. A backtick inside a regex literal (e.g. `match(/`+/g)` written with a literal backtick) flips the stripper into template-string state, wrecking quote parity for the rest of the file — later prompt prose leaks into the identifier scan and the test fails on an unrelated word (e.g. "process") far from the real cause, which reads as a pre-existing failure. In workflow scripts, spell backticks as the escape \u0060 whenever they appear in code position (regex literals, char comparisons); backticks *inside* quoted strings are fine.

**Worktree gotcha** (PR #436 review): a follow-up agent must never pair `isolation: 'worktree'` with `git checkout <branch>` of a branch another agent's worktree still holds — git refuses a second checkout of an already-checked-out branch. Hand the first agent's worktree path back through its schema (e.g. `worktree_path` via `git rev-parse --show-toplevel`) and have the follow-up agent run *without* isolation and `cd` there instead.

**vm-realm test gotcha** (PR #486): `tests/workflows/harness.mjs` runs workflow scripts in a `node:vm` context, so objects/arrays the workflow returns carry foreign prototypes — `assert.deepEqual` from `node:assert/strict` fails with "Values have same structure but are not reference-equal" even when contents match. Convention: spread-clone (`{ ...obj }`) or `Array.from(arr)` before `deepEqual`. Fixture objects built in the *test* realm and passed through mocks compare fine; only workflow-realm-constructed values trip it.

Related: [[architecture/agents-dir]], [[operations/sync-and-chezmoi]], [[adr/cheese-factory-workflow]].

_Source: main-clone wiki page (untracked) + cheese-factory-workflow implementation session (PR #486) · Updated: 2026-07-20 · Supersedes: untracked main-clone copy of this page_
