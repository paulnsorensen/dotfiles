# The advisor role

Read at Flow step 3, or when a design has no pre-implementation review.

## Role

The advisor is a stronger model one level above the implementers.
It reads the plan or the state and returns `approve`, `revise`, or `stop` with concerns and short guidance.
It has no write tools. The implementer stays the only writer [s15], [s16].

## When to call

1. After orientation, before substantive work [s15].
2. Optional: when a task stalls or exhausts its continuations. The template does not implement this call.
3. When the run considers a change of approach [s15].
4. Before the run declares done, after the deliverable is durable [s15].

Plan for about two to three calls per task [s15].

## What to send

Send the goal, the ontology, and the precomputed context. For the done call, send the verdict table and the task outcomes.
Do not send raw transcripts.

## Conflicts and bounds

1. When the executor has evidence against the advice, make one reconcile call. State the evidence and ask which constraint breaks the tie [s15].
2. Bound revision rounds in code, for example `LIMITS.advisorRevisions = 1`.
3. After the limit, return `needs-input` to the user. Do not loop.
4. Ask for guidance under 80 words. Advisor output is its main cost driver [s15].

## Workflow tool implementation

The template function `advise()` in `assets/workflow-template.js` makes this call. Copy that function; do not retype it.
The call uses `agentType: 'judge'`, a prompt whose first line is exactly `Judge mode: advise`, and the labels `advise:plan:<round>` and `advise:done`.

The `judge` agent type has no edit or write tools. It keeps Bash only to read state and run checks. Its agent definition forbids repository mutation.
The tool grant does not block Bash. Rely on the agent definition for that rule, and keep prose in the prompt as a second guard.
No source confirms that the Workflow `agent()` exposes the API advisor tool. This emulation does not depend on it.

## API and Agent SDK implementation

- Tool type `advisor_20260301`, name `advisor`, required `model` [s15].
- Beta header `advisor-tool-2026-03-01` [s15].
- Optional `max_uses`, `max_tokens` (minimum 1024), and `caching` [s15].
- The executor decides when to call. The server forwards the full transcript to the advisor [s15].
- The benefit shrinks as the executor approaches the advisor's capability [s15].
- Vendor-reported: Sonnet with an Opus advisor gained 2.7 points on SWE-bench Multilingual at 11.9% lower cost per task [s16]. Run your own evals.
