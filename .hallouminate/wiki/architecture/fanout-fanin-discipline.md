# Fan-out / fan-in discipline

How to run a multi-agent fan-out without paying for it twice. Companion to
[[subagent-routing-policy]] (which decides *whether* to fan out; this page is
*how*). From the "Practical Sub-Agent Routing" guide (ingested 2026-07-24).

## The economics

`wall-clock ≈ max(worker durations) + coordination + integration`;
`total tokens ≈ parent + Σ(worker bootstrap + work) + integration + review`.
Parallelism buys **latency, not lower total tokens** — it is cost-efficient only
when cheap workers replace expensive serial work or when preserved parent
context prevents a degraded long session. Goal: the **minimum** number of agents
that yields a clean decomposition, protects the parent context, and reduces
expensive-model time — not "as many cheap agents as possible".

Sub-agents help: read-heavy exploration across independent areas; parallel
review lenses; competing debugging hypotheses; independent slices with low file
overlap behind a stable contract; verbose disposable output (logs, searches,
test dumps); tool/permission isolation. Keep it in one session when: the edit is
small and files are known; phases share dense context; work is sequential;
workers would fight over the same foundations; the environment is expensive or
flaky; requirements are still moving.

## How many agents

Start with 2–3 workers, not 5 by habit — token use scales with active workers
and coordination has diminishing returns.

| Situation | Parallelism |
|---|---|
| One narrow feature/bug | 0–1 (usually parent or one worker) |
| Large unfamiliar module | 2–3 read-only explorers, split by concern |
| Independent frontend/backend/test slices | 2–3 workers after interface freeze |
| PR review | 2–4 reviewers with non-overlapping lenses |
| Mechanical repo-wide migration | 2–6 workers by exclusive subtree |
| Unclear production bug | 3–5 hypothesis investigators, one lead synthesizes |

Patterns, cheapest first: **read-heavy discovery** (spawn by concern — execution
path / tests / data model / external APIs — never by arbitrary file ranges);
**directory ownership** (mechanical changes, integrator owns shared files);
**interface-first fan-out** (strong planner freezes types/errors/invariants,
then workers implement behind the contract); **competing hypotheses** (each
agent a distinct causal theory, fan-in by disconfirming evidence, not voting);
**specialist review** (distinct lenses, evidence required); **planner+verifier
tree** (strong model delegates bounded verification, keeps synthesis);
**sequential specialist chain** (researcher → planner → coder → tester →
reviewer when phases depend on each other — context protection without unsafe
parallelism).

## Fan-in contract

Every write-worker returns the same fields, so the parent never reads raw
transcripts and integration is deterministic:

```
STATUS: DONE | BLOCKED | ESCALATE
SCOPE: files/symbols owned + files explicitly untouched
SUMMARY / EVIDENCE (commands, tests, file:symbol) / ASSUMPTIONS / RISKS
HANDOFF: commits/patches + exact integration steps
NEXT: one recommended action for the parent
```

In this repo the four-field handoff block (`status`/`next`/`artifact`/orientation,
see [[agents-dir]]) is the transport envelope; the fields above are the payload
contract for parallel write-workers specifically.

## Write ownership and contract freeze

- Each worker gets an explicit **file/directory allowlist**; it stops (ESCALATE)
  before editing outside it.
- Shared types, root config, migrations, and generated artifacts are reserved
  for the integrator unless the plan names one owner.
- Concurrent writers get isolated worktrees/branches; one commit per slice with
  test evidence.
- Parallel workers need a **frozen, versioned contract artifact** (types, API
  contract, decision record, planner summary) — without it they independently
  "help" by redefining semantics.
- **Integrator rule:** the integrator may reject a worker patch that violates
  the contract even when its local tests pass. Local success ≠ integration
  success.

## Context packets and context reset

Sub-agents start blank on every harness we run (Claude, Codex, OMP). The spawn
prompt must carry: goal + acceptance criteria; why the slice exists and which
contract it implements; allowed/forbidden files and tools; relevant project
commands; decisions already made; expected deliverable + validation; escalation
conditions. Context reset is a feature: seed a fresh reviewer (and, on long
builds, a fresh integration session) with the plan, commits, test evidence, and
open risks — not the accumulated search history.

## Validation pyramid

| Layer | Owner | Checks |
|---|---|---|
| Slice | worker | targeted tests, lint/typecheck, reproduction |
| Contract | integrator | cross-slice API/type checks, migrations, generated code |
| System | integrator/CI | full suite, integration/e2e, build/rollout |
| Adversarial | fresh reviewer | assumptions, negative tests, rollback, security, concurrency |

## Failure modes → controls

| Failure | Control |
|---|---|
| Weak router calls a risky change "small" | hard overrides; evidence schema; mid-tier review of low-confidence profiles |
| Over-decomposition (bootstrap > work) | minimum useful slice; start 2–3; combine related tasks |
| Contract drift between workers | interface-first plan; freeze; integrator owns shared files |
| Write collisions | exclusive ownership; stage dependent changes |
| Context starvation | full spawn packet |
| Duplicate research | partition by question/concern; unique deliverable each |
| False review confidence (3 reviewers, same surface notes) | distinct lenses; fresh context; require failure scenarios |
| Recursive agent explosion | depth 1 default; concurrency caps; leaf workers cannot spawn |
| Local-test illusion | integrator owns combined validation; review the combined diff |
| Planner becomes implementer | read-only planner with explicit output |
| Worker scope creep | allowlist; stop-and-escalate; smallest defensible change |
| Review churn (style-only, broad refactors) | finding format; severity threshold; no style-only comments |

**Recovery ladder:** 1 retry only transient tool/env failures → 2 rewrite the
slice contract and restart fresh (never pile corrections onto a confused
thread) → 3 escalate the slice to a stronger worker/planner → 4 contradictory
outputs go to a strong adjudicator comparing evidence, not majority vote → 5
merge failure: stop parallel work, freeze state, one integrator → 6 architecture
failure: back to plan; don't patch around a broken contract.

## Shared memory instead of the orchestrator bottleneck (2026-07-24)

The fan-in contract above passes findings *through the parent*. When workers'
findings must chain with each other — worker A's fact connects to worker B's —
that transport breaks: the parent window grows linearly with worker count and
cross-worker connections die in summarization. The structural alternative is a
shared, provenance-carrying store (a blackboard) that workers write findings
into and any agent queries later; the orchestrator's window stays small.
Anthropic's numbers frame the trade: multi-agent systems beat single agents by
90.2% on tasks needing multiple independent directions but consume 10–15× the
tokens — the shared store is the context-management answer. In this repo the
hallouminate wiki + `.cheese/` artifacts play that role; a triple-style graph
is the next rung when findings must be chained, not just retrieved — see
[[knowledge-graph-playbook]].

*Source: "Practical Sub-Agent Routing" guide (docx ingest, hash ac33ad5418f0c6a0) + "KG Engineering Playbook" (hash 32c0769bb78d8fb7) · Updated: 2026-07-24*
