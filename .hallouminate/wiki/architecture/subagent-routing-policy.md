# Sub-agent routing policy: discover, then commit

Routing doctrine for multi-agent work across all harnesses (Claude, Codex, OMP),
adopted from the "Practical Sub-Agent Routing" guide (ingested 2026-07-24). The
core rule: **never ask a cheap worker to judge whether it is capable — ask it to
gather a bounded set of facts, let a deterministic policy pick the route, and
spend frontier-model tokens only at serial bottlenecks** (the plan everyone
depends on, and the fresh-context review of the combined diff). Route by risk
and coupling, not line count: a five-line auth change may need a strong planner
and reviewer; a 500-line mechanical rename with good tests may not.

## The five-stage default topology

| Stage | Role | Tier (claude / codex / omp role) | Why |
|---|---|---|---|
| 0 Intake | parent/router | sonnet / terra / `default` | enforce policy without flagship cost per tool call |
| 1 Scope | read-only scoper | haiku / luna / `tiny` | facts: files, call paths, tests, contracts, risk flags, slices |
| 2 Plan | planner (only when triggered) | opus–fable high–xhigh / sol xhigh / `plan` | ambiguity, interfaces, sequencing, invariants |
| 3 Execute | leaf coder(s) | sonnet / terra / `task` | implement precise slices with explicit ownership |
| 4 Integrate | parent or integrator | sonnet / terra (strong when coupled) | merge, contract drift, cross-slice validation |
| 5 Review | fresh-context reviewer | opus–fable high–xhigh / sol high–xhigh / `slow` | global bugs, security, missing tests, invalid assumptions |

## Discover-then-commit: the route decision

1. **Bounded scoper** (read-only, turn-limited, fixed output schema) returns a
   change profile: likely files, module boundaries, services affected, shared
   interfaces, unknowns, risk flags, validation available
   (targeted/integration/manual), independent slices, expected file overlap,
   recommended route + confidence, evidence.
2. **Hard overrides** — any one forces STRONG_PLAN / STRONG_REVIEW regardless of
   size: auth/secrets/crypto/tenant isolation; payments/ledgers/irreversible
   effects; concurrency/idempotency/ordering/retries; schema/migration/protocol/
   public-API changes; production-destructive ops or rollout logic; weak
   integration coverage around a global invariant.
3. **Score the rest** on eight 0–2 dimensions: breadth, coupling, ambiguity,
   validation, parallelism, write overlap, novelty, reversibility.
4. **Route by threshold** (calibrate per repo):

| Score / condition | Route | Execution |
|---|---|---|
| 0–3, no overrides | DIRECT | one cheap/mid worker, targeted validation |
| 4–6 | SCOPED_SINGLE | one mid worker, optional short plan, one owner |
| 7–9 | PLAN | strong planner, then one staged worker |
| 10+ and low overlap | FAN_OUT | strong contract, 2–4 isolated workers, central integration |
| any hard override | STRONG_PLAN / STRONG_REVIEW | escalate regardless of score |
| high overlap / sequential | STAGED | chain workers or stay in one session — never parallelize writes |

1. **"Needs planning" ≠ "can parallelize."** Force a strong planner on: risk
   flags, ≥2 module boundaries or services, ≥2 unknowns, public-contract change,
   migration, or no integration validation. Fan out writes only when: ≥2
   independent slices AND low file overlap AND frozen interfaces AND per-slice
   validation. A task can need strong planning yet still be one worker; a
   mechanical refactor can fan out with almost no planning.
2. **Re-route on evidence** — routing is a state machine, not a one-time guess:
   `UNKNOWN → SCOPED → {DIRECT|PLAN|FAN_OUT|STAGED} → IMPLEMENTED → INTEGRATED →
   REVIEWED → DONE`, and any worker may flip its slice to ESCALATE.

## Layered authority — who routes

| Layer | Responsibility | Intelligence |
|---|---|---|
| Evidence collector | factual scoping answers | cheap, read-only, bounded |
| Routing policy | thresholds + hard overrides | **code / written policy, not model intuition** |
| Borderline router | incomplete or contradictory evidence | mid tier (strong only when risky) |
| Lead/integrator | plan, assignments, contracts, merge, final state | parent session — never delegated casually |

Workers **discover and recommend**; the parent **routes and commits**. Ask
evidence questions a weak model can answer ("which shared interfaces change?",
"which tests cover this end-to-end?"), never "are you capable enough?". The same split governs mechanical scale:
pre-filter candidates with cheap deterministic logic (an index, a diff stat, a
grep) and spend model calls only arbitrating within the small blocks that
remain ([[knowledge-graph-playbook]]).

## The worker escalation rule

A leaf worker may: gather evidence, implement its assigned contract, recommend a
route, request verification. It may **not**: silently change a shared contract,
expand from one module to several, decide a hard-risk domain needs no strong
review, spawn an unbounded agent tree, or merge/approve its own high-risk
result. Any prohibited condition → return ESCALATE with evidence.

## Where to spend the strong model

Serial bottlenecks only: freezing an interface/contract before workers split;
choosing between architectures with different rollout risk; deciding whether
test evidence justifies merge; reviewing the integrated diff fresh; adjudicating
repeated failure or contradictory findings. Not: file discovery, formatting,
grep output, routine test loops, mechanical edits. **Reviewer strength follows
risk, not implementation strength** — a cheap coder inside a frozen contract
plus a strong fresh reviewer beats a strong coder with no independent review.
A reviewer is strongest when grounded: hand it provenance-carrying evidence
(diff hunks, spec lines, test output) to fact-check claims against, and
escalate claims no evidence can settle to a human rather than letting the
reviewer guess ([[knowledge-graph-playbook]]).

## Calibration

Measure per task: routing accuracy (did the topology need rework?), first-pass
success by profile × tier, total tokens + wall clock, merge conflicts and
out-of-scope edits per worker, review yield (high-severity findings per strong
call), test-escape rate. Recalibrate thresholds after 20–50 tasks; prefer adding
a hard override over globally upgrading every task a tier.

## Current state (2026-07-24)

Precursors exist but the scoper→policy→route stage does not yet: easy-cheese's
`/ultracook` decomposer + `select_mode` (parallel iff ≥2 curds) and `/age`'s
scale threshold (>15 files / >25KB → dimension fan-out) gate on **size, not
risk/coupling**, and the `/age` fan-out is all-or-nothing (one opus reviewer per
dimension via `claude/workflows/age-fanout.js`). Static tier pins live in
`agents/registry.yaml` (per-harness `models:`), OMP `modelRoles`
([[operations/omp-fanout-worker-models]]), and `codex/config.toml`. Turn/context
ceilings are enforced by the turn-budget-guard hook
([[subagent-turn-budgets]]).

Model-behavior deltas (Opus 5, 2026-07-24): review accuracy holds at low
effort (effort is a second dial beside reviewer count), severity-conservative
review prompts suppress recall, and explicit self-verification scaffolding
over-verifies — see [[operations/prompting-claude-opus-5]].

See [[fanout-fanin-discipline]] for fan-out sizing, fan-in contract, and merge
discipline; [[agents-dir]] for the registry that pins per-agent models;
[[agent-vs-skill-tiering]] for why phase agents get their own windows.

_Source: "Practical Sub-Agent Routing" guide (docx ingest, hash ac33ad5418f0c6a0) + "Prompting Claude Opus 5" (hash 9a680a14e9bdf39a) + "KG Engineering Playbook" (hash 32c0769bb78d8fb7) · Updated: 2026-07-24_
