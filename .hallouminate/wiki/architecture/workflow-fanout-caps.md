# Workflow fan-out caps and model pins

Every fan-out in `claude/workflows/*.js` has a count cap in code and a named model.
A schema `maxItems` or a prompt limit is not a cap, because the runtime or the agent can ignore it.

## Why

On 2026-10-15 a move-my-cheese run started 46 opus verify agents.
The source was its brie-ground child, not move-my-cheese.
`verifyEvidence` in `brie-ground.js` started one refute agent for each decision-critical claim.
It had no count cap and no `model`, so each agent used the parent model (opus).
A deep sub-question can extract 12 sources × 4 claims, so 46 agents was a normal result.

## Rules

- An `agent()` call with no `model` and no model-pinned `agentType` uses the parent model. Set `model` on each fan-out worker.
- Cap each fan-out whose item count comes from agent output. Use a `slice`, a `LIMITS` value, or a check that blocks the run.
- Remove repeats before the fan-out, not after it. A repeat shares the verdict of the first copy only when the verifier read the same thing: brie-ground keys on claim and citation, sliced-bread-audit on fingerprint and claim.
- Keep a child workflow's worst case under the budget its callers reserve. brie-ground's worst case is 96 agents against `BRIE_GROUND_MAX_AGENTS = 100`; a test runs that case.
- Log the number of items that the cap drops. Report capped items as unverified, not as checked.

## Current caps (2026-10-15)

| Workflow | Fan-out | Cap | Model |
|---|---|---|---|
| brie-ground | sub-questions | 5; the rest go to `open_questions` | — |
| brie-ground | refute agents | 4 distinct claim and citation pairs per sub-question; speculating before dont_know | sonnet |
| brie-ground | deep scope, search, extract, wiki | angles 6, claims 4 per source (code `slice`) | sonnet |
| triage-sweep | ground and verify | `limit` per kind, repeats by kind and number removed | explorer |
| triage-sweep | route | single call | opus |
| sliced-bread-audit | slice evaluators | 20 slices; the rest become failures | opus |
| sliced-bread-audit | refuters | 12 per run, one per fingerprint and claim | opus |
| age-fanout | dimension reviewers | 12 distinct dimensions, else blocked | opus |
| hill-climb-threads | adopt, climb, verify, publish | 8 threads × 12 rounds | sonnet |
| move-my-cheese | criterion judges | 24 criteria per plan, else rejected | sonnet |

brie-ground: a claim past the refute cap, or a claim whose refute agent returned nothing, is `unchecked`. An unchecked decision-critical claim stops the recall short-circuit, so the run does fresh research. A dropped sub-question goes to `open_questions` and keeps the confidence below `certain`. The result also reports `dropped_sub_questions` and `unchecked_claims`.

## Tests

Each cap has an offline test in `tests/workflows/`. The test fails on the code from before the cap.
