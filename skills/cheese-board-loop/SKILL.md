---
name: cheese-board-loop
model: sonnet
effort: medium
description: >
  Runs the cheese-board workflow and asks the user each question it raises. Use when the user says
  "cheese-board", "plan the backlog", "strategy from triage and ideas", or invokes /cheese-board-loop.
  Do NOT use for one spec (/mold), for building a spec (/cheese-factory), or for an unattended
  run (pass auto:true to the workflow directly).
---

# cheese-board-loop

Run the cheese-board workflow. Ask the user each question the workflow raises. Rerun it with the answers.

## Loop

1. Run the Workflow tool with `cheese-board` and args `{ stamp: "<today, YYYY-MM-DD>" }`. Add `repo`, `limit`, `ideas`, `maxSpecs`, or `focus` only when the user gave them.
2. Read `status` in the result.
3. If `status` is `needs-input`, ask the user every entry in `questions` with AskUserQuestion.
   - Put the `recommended` option first. Add the other `options`.
   - Show `evidence` as the question context.
   - AskUserQuestion takes 1 to 4 questions per call and 2 to 4 options per question. Batch the questions in groups of up to 4, with one call per group.
   - If a question has 0 or 1 options, pad the options, or let the user type a free answer in the built-in "Other" field. Keep the `recommended` option first.
   - At the `strategy` checkpoint, ask whether any initiative changes lane. Pass the moves as `lanes: { "IN-n": "spec|mold|defer" }`.
4. Rerun the Workflow tool with `{ stamp, state, digest, answers }`.
   - Reuse the original `stamp` without change on every rerun.
   - Copy `state` and `digest` from the `needs-input` result without change.
   - Key each answer by the question `id`. The exact question text or its 1-based number also works.
5. Repeat from step 2.
6. Stop on any other `status` (`ok`, `partial`, `needs-review`, `stopped`, `blocked`, `empty`). Report the factory queue, the `/mold` list, the report path, and the gaps.

## Rules

- Never edit `state`. The digest detects an edit, and the run returns `blocked`.
- Never combine `auto: true` with `state`, `digest`, `answers`, or `lanes`. An auto run does not pause.
- Answer closed questions (those with `options` and a `closed` flag) with exactly one option.
- At the `done` checkpoint, the answer `approve` records the strategy. Any other answer is a fix that the workflow applies to the report once.
- Do not chain into `/cheese-factory`. Print the queue commands and stop.
