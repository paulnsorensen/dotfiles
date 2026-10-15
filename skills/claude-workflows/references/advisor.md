# The advisor role

Read at Flow step 3, or when a design has no pre-implementation review.

## Role

The advisor is a stronger model one level above the implementers.
It reads the plan or the state and returns `approve`, `revise`, or `stop` with concerns and short guidance.
It has no write tools. The implementer stays the only writer [s15], [s16].

## When to call

1. After orientation, before substantive work [s15]. Skip this call when code already checks the whole plan and no leverage trigger fires. Leverage triggers are auth, irreversible effects, concurrency, public contracts, destructive operations, and cross-slice dependencies.
2. Optional: when a task stalls or exhausts its continuations. The template does not implement this call.
3. When the run considers a change of approach [s15].
4. Before the run declares done, after the deliverable is durable [s15].

Plan for about two to three calls per task [s15].

## Give the advisor a plan it can approve

The advisor judges the payload, not the code that built it. A placeholder reads as a defect.
State each valid plan shape in the prompt. For example, a single-pass plan has one task that covers the whole spec.
Do not send `null` or an empty list for a field that the plan shape leaves out. Omit the field.
When a revise round cannot change the field that the advisor names, return `needs-input` with the concern. Do not call the advisor again.

Evidence: 8 of 22 cheese-factory runs from 2026-10-13 to 2026-10-14 stopped at the plan advisor. The single-pass payload sent `brief: null` and `files: []`, and the advisor asked for both in each round.

## What to send

Send the goal, the ontology, and the precomputed context. For the done call, send the verdict table and the task outcomes.
Do not send raw transcripts.

## Conflicts and bounds

1. When the executor has evidence against the advice, make one reconcile call. State the evidence and ask which constraint breaks the tie [s15].
2. Bound revision rounds in code, for example `LIMITS.advisorRevisions = 1`.
3. After the limit, return `needs-input` to the user. Return typed questions `{id, question, options[], recommended, evidence, initiative?, closed?, kind?}`, the state, and a digest of the state. Do not loop.
   The next run takes `{state, digest, answers}`. Before the first agent, it checks the digest and the answers. Then it applies one revision. An unsettled advisor returns `needs-input` on every path.
   The prelude `digestOf` and `matchAnswers` are one implementation of this check. Any equivalent code works.
4. Ask for guidance under 80 words. Advisor output is its main cost driver [s15].
5. On a revision round, send the prior concerns. The advisor judges only whether each one is resolved. It raises a new concern only for a blocker, and it never reverses a prior concern.

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
