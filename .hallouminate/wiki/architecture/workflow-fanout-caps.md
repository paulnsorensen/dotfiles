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
- Keep a child workflow's worst case under the budget its callers reserve. brie-ground's worst case is 35 agents, and `BRIE_GROUND_MAX_AGENTS = 35` reserves exactly that; a prelude test computes the worst case from the brie-ground caps and pins the reservation to it.
- Log the number of items that the cap drops. Report capped items as unverified, not as checked.
- Batch items into one agent when each item needs only a short check. Each agent start costs its startup context, so one agent per item multiplies that cost.

## Current caps (2026-10-16)

A row marked with an open PR describes the code on that PR branch. A stacked PR is pending its base PR.

| Workflow | Fan-out | Cap | Model |
|---|---|---|---|
| brie-ground | sub-questions | 5, at most 3 deep; extra deep ones run shallow; the rest go to `open_questions` | — |
| brie-ground | verify | one batched agent per sub-question; 4 distinct claim and citation pairs; code matches verdict ids | explorer, sonnet |
| brie-ground | deep search | one agent for all angles; angles 3 to 6, 6 results per angle, repeat URLs removed | sonnet |
| brie-ground | deep extract | 12 URLs in batches of 4, so 3 agents; 4 claims per source | sonnet |
| triage-sweep | gather | one agent and one redo, then `blocked` | explorer, haiku; `runner` in PR #1359 |
| triage-sweep | ground | one agent per batch of 4 items of one kind; one redo for missing items | explorer |
| triage-sweep | verify | one agent per batch of 4 closing items | explorer |
| triage-sweep | map | one agent per lens; 60 open items per lens | explorer |
| triage-sweep | route | single call | opus; `explorer` type, `formatter` in PR #1359 |
| sliced-bread-audit | slice evaluators | 20 slices; the rest become failures | opus |
| sliced-bread-audit | refuters | 12 per run, one per fingerprint and claim | opus |
| age-fanout | dimension reviewers | 12 distinct dimensions, else blocked | opus |
| age-fanout (PR #1357) | assignment reviewers | 5 `age-route` assignments; the rest are logged and returned | opus |
| hill-climb-threads | adopt, climb, verify, publish | 8 threads × 12 rounds | sonnet |
| move-my-cheese | criterion judges | 24 criteria per plan, else rejected; one judge runs a batch of checks | sonnet |
| cheese-factory | criterion judges | 24 criteria (`LIMITS.maxCriteria`); one judge per criterion, run serially | judge, sonnet |

### brie-ground (PR #1340, merged)

The worst case is 35 agents: recall 2, plan 2, 3 deep sub-questions × 7, 2 shallow sub-questions × 3, synthesis 2, and prototype 2.
A deep sub-question uses wiki, search, 3 extract batches, code, and verify.
The worst case was 96 agents before this PR.

A claim past the verify cap, or a claim with no verdict, is `unchecked`.
Code ignores an unknown or repeated verdict id.
An unchecked decision-critical claim stops the recall short-circuit, so the run does fresh research.
A sub-question with no evidence goes to `failed_sub_questions` and `open_questions`.
A dropped sub-question goes to `open_questions`.
Code lowers `certain` to `speculating` when a sub-question is ungrounded or a decision-critical claim is not verified.
The result reports `dropped_sub_questions` and `unchecked_claims`.

### Prelude reservation (PR #1356, open)

`claude/workflow-prelude/prelude.js` reserves `BRIE_GROUND_MAX_AGENTS` for each brie-ground child.
Main still reserves 100, which over-reserves by 65.
PR #1356 lowers the value to 35 in the prelude and in its copies in `cheese-board.js`, `cheese-factory.js`, and `move-my-cheese.js`.
A prelude test computes the worst case from the brie-ground caps and pins the reservation to it.
The PR also logs and returns the count of follow-up questions and citation rows that a capped child drops.

### triage-sweep (PR #1337, merged)

At `limit` 200, the worst case is 302 agents, not about 800; a test checks the count.
`limit` defaults to 30 and has a maximum of 200 per kind.
A 50k token floor runs before the first agent, before Map, and before Route.
Code moves each unconfirmed close to needs-human, so the close rule does not depend on the prompt.
PR #1359 sets Gather to the `runner` type and Route to the `formatter` type. It is stacked on PR #1358, which adds those agent types, so it is pending its base.

### age-fanout (PR #1357, open)

The packet agent plans the review with `age.pyz age-route` and takes the review lock.
Review starts one reviewer per planned assignment and caps the wave at 5.
Code logs the dropped assignments, and Reconcile records them as coverage restrictions.
`AGE_FANOUT_MAX_AGENTS` drops to 14.
Until the PR merges, main starts one reviewer per dimension, up to 12.

### Judge batching

PR #1358 (open) lets `judge` verify mode take a list of checks and return one verdict per check id.
move-my-cheese already runs one judge per batch of checks.
cheese-factory still starts one judge per criterion. Its change has no PR yet.

## Tests

Each cap has an offline test in `tests/workflows/`. The test fails on the code from before the cap.
