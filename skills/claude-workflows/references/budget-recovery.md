# Budget and context exhaustion

Read at Flow step 6, or when agents die, stall, or run out of context.

## Prevent first

1. Size each task so one agent finishes it in one context. One feature per session limits over-reach and early completion claims [s9].
2. Give each agent only the criteria and context that its task needs.
3. Compute the branch name and the progress-file path in code, for example `wf/T-3` and `.workflow/progress/T-3.json`.

## Keep durable state

Tell each implementer to write its progress file and commit after each step.
A progress file plus git history lets a fresh context learn the state fast [s9].
End each session in a clean state that can merge [s9].
Make the deliverable durable before a long advisor or verifier call [s15].

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
The local exemplar is `claude/workflows/cheese-factory.js` in the dotfiles repository (checkpoint coordinator, fingerprint guard, continuation limit).

## Workflow runtime facts

- `agent()` returns `null` when the user skips it or the subagent dies. `parallel()` turns a throw into `null`.
- `budget.remaining()` is a hard ceiling when the user sets a target. Check a floor before each wave.
- `resumeFromRunId` reuses the longest unchanged prefix of `agent()` calls. Keep prompts and labels deterministic.
- `Date.now()`, `Math.random()`, and argless `new Date()` throw. Pass timestamps in through `args`.

## Agent SDK and API facts

- `max_turns` and `max_budget_usd` end with `error_max_turns` or `error_max_budget_usd`. The result keeps `session_id`. Resume with a higher limit [s10].
- The budget cap includes subagent spend [s10].
- `stop_reason` values `max_tokens` and `model_context_window_exceeded` mean truncated output [s11].
