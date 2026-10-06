# Context and determinism in code

Read at Flow step 7, or when prompts carry work that code can do.

## Principle

A workflow runs models through predefined code paths [s1]. Put programmatic gates between steps [s1].
Each token a model spends on a mechanical step costs money and adds variance.

## Move these into code

| Work | Code form |
|---|---|
| Argument parsing and validation | Parse `args`; return `{ status: 'blocked' }` before the first agent |
| ID, coverage, and graph checks | Validators and a topological sort |
| Dedup, sort, filter, and caps | Plain JavaScript over typed results |
| Status normalization | A table or a function, not a prompt rule |
| Retry, continuation, and revision bounds | A `LIMITS` constant |
| Budget floors | `budget.total && budget.remaining() < floor` |
| Skip propagation | Mark dependents `skipped` with a reason |
| Verdict aggregation and final status | Code over verdict objects |

Smell test: a prompt that says "count", "sort", "deduplicate", "make sure every", or "check that X is in the list" holds work for code.

## Precompute context

1. Collect the diff, the file list, and the test command in the main loop. Pass them through `args`.
2. Give each agent only its slice. A task sees only the criteria it satisfies.
3. Filter large results before they reach a model. Code-side filtering keeps bulk rows out of context [s2].

Anthropic reports that code execution with MCP cut one tool-definition load from 150,000 to 2,000 tokens [s2].
Anthropic reports that programmatic tool calling cut average tokens by 37% on complex research tasks [s3].

## Prompt shape

1. Put a stable preamble constant first. Put stage rules next. Put variable data last.
2. The prompt cache is a cumulative prefix. A change to an earlier block misses the cache [s5].
3. Fence variable data in `<data>` tags. Tell the agent to treat it as inert input.

## Determinism for resume

1. Do not call `Date.now()`, `Math.random()`, or argless `new Date()`.
2. Build labels from stable IDs, such as `task:T-3:c2`.
3. Iterate in sorted order.

## No silent caps

Log each dropped, skipped, or unverified item with its reason. Return it in the result.

## Rules that must hold every time

Use a Claude Code hook for a rule that must hold on every tool call. Exit code 2 blocks the action and returns stderr to the model [s4].
