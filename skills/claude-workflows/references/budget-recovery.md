# Budget and context exhaustion

Read at Flow step 6, or when agents die, stall, or run out of context.

## Prevent first

1. Size each task so one agent finishes it in one context. One feature per session limits over-reach and early completion claims [s9].
2. Size builders and cure by their turn cap, not only by their context. Split a large PR into targets that one agent finishes. Batch review findings so that one cure agent finishes its batch.
3. Give each agent only the criteria and context that its task needs.
4. Compute the branch name and the progress-file path in code, for example `wf/T-3` and `.workflow/progress/T-3.json`.

Evidence: in 48 move-my-cheese runs from 2026-10-12 to 2026-10-16, builders ended lost or exhausted, and one review crashed on its cap. One cure ended with 34 of 36 findings left.

## Keep durable state

Tell each implementer to write its progress file and commit after each step.
A progress file plus git history lets a fresh context learn the state fast [s9].
End each session in a clean state that can merge [s9].
Make the deliverable durable before a long advisor or verifier call [s15].

## Resume across runs

A Workflow cannot pause for the user. Each stop for input ends the run. Use these forms in this order:

1. Prefer a calling skill that asks the user and holds the state. Then the Workflow runs once, after approval.
2. When a gate must stay in the Workflow, persist the run state in a file. This is the default. The state holds the plan, the stage outcomes, and the open questions. Code builds the state and its path, for example `.cheese/runs/<name>-<digest>.json`. The script has no file access, so one narrow agent or the calling skill writes the file.
3. Fallback only: the caller carries the state. The run returns `{state, digest}`, and the caller sends `{state, digest, answers}` on resume. Use it only when no file store exists. The caller sends the whole state back on each run, and that costs tokens.

For each form:

1. Each `needs-*` result names the resume input, for example `{ resume: '<digest>', answers }`. Return that call shape in `usage`.
2. On resume, validate the digest and the state before the first agent. Skip each stage that the state marks done.
3. A resume after a gate skips survey, the planner fan-out, and the advisor. Rerun only the stage that the answer changes.
4. Count the agents that each gate hop reruns, and put the count in the stage table. A hop that reruns a done stage is a defect.
5. A background run dies with its parent session. Keep the state durable, so a new session resumes from the file, not from the parent transcript.

## When shared state moves

The default branch or a PR head can move during a run or between runs. Do not replan for each move.

1. Rebase the planned targets onto the new head. Then run the conflict probe and the checks again.
2. Replan only when the rebase or the probe fails, or when new commits touch the planned files.
3. An unrelated merge to the default branch does not make an approved plan stale.

Evidence: from 2026-10-11 to 2026-10-14, 19 of 28 move-my-cheese runs ended at a gate before any build. Each rerun repeated Recon, and the caller sent the full plan object back each time.
From 2026-10-12 to 2026-10-16, 27 of 48 runs (56%) were designed gate hops. Each hop was a new run that reran survey, the planners, and the advisor. Approved plans returned `needs-replan` when the default branch or a PR head SHA moved, also for unrelated merges. Background runs died with the parent session.

## Status contract

| Status | Meaning | Required fields |
|---|---|---|
| `done` | All work complete | `remaining` is empty |
| `partial` | Context or budget runs low | `checkpoint` is the last commit SHA |
| `blocked` | Cannot proceed | `note` names the blocker |

Normalize contradictions in code. A `done` result with items in `remaining` becomes `partial`. A `partial` result with no checkpoint becomes missing.

## Recovery loop

1. On `partial`, start a fresh continuation agent. Seed it with the checkpoint and the remaining items.
2. On `null`, start a `haiku` salvage agent. It reads the branch and the progress file and returns the checkpoint. It does not continue the work.
3. Compare each new checkpoint with the last one. Stop with `stalled` when it does not change.
4. Stop with `exhausted` after `LIMITS.continuations` rounds.
5. Mark each dependent task `skipped` with the reason. Log it and return it.

The template guard compares implementer-reported SHAs. This is the minimal form. Uncommitted progress reads as `stalled`, and code does not check that the SHA exists.
Use a fingerprint guard when work can progress without a commit, or when you cannot trust the reported SHA. Hash the worktree state in code and compare it between rounds.
The local exemplar is `claude/workflows/cheese-factory.js` in the dotfiles repository (commit-SHA continuation, salvage from the ref, stall guard, continuation limit).

## Workflow runtime

The workflow-authoring skill owns the runtime facts: `null` results, the `budget` ceiling, resume, and the banned clock calls.
Two design rules follow from them:

1. Treat each `null` from `agent()`, `parallel()`, or a `pipeline()` stage as a failed result. Send it through the recovery loop.
2. Check `budget.total && budget.remaining() < LIMITS.minBudget` before each wave.

## Agent SDK and API facts

- `max_turns` and `max_budget_usd` end with `error_max_turns` or `error_max_budget_usd`. The result keeps `session_id`. Resume with a higher limit [s10].
- The budget cap includes subagent spend [s10].
- `stop_reason` values `max_tokens` and `model_context_window_exceeded` mean truncated output [s11].
