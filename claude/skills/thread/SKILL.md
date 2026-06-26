---
name: thread
model: haiku
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git rev-parse:*), mcp__code-review-graph__list_graph_stats_tool, mcp__code-review-graph__build_or_update_graph_tool, mcp__code-review-graph__semantic_search_nodes_tool, mcp__code-review-graph__query_graph_tool, mcp__code-review-graph__get_impact_radius_tool, mcp__code-review-graph__get_affected_flows_tool, mcp__code-review-graph__get_hub_nodes_tool, mcp__code-review-graph__get_bridge_nodes_tool, mcp__code-review-graph__traverse_graph_tool, mcp__code-review-graph__detect_changes_tool
description: >
  Trace steel threads from a symbol or entry point: given "what changes if I
  touch X", returns the call chains, downstream callers, impacted flows, and
  architectural significance via the code-review-graph MCP. Use when the user
  asks "what depends on this", "what flows pass through this", "blast radius
  of changing X", "what's the steel thread for Y", or invokes /thread.
  Argument: symbol name, qualified name, or file path.
argument-hint: <symbol | qualified.name | path/to/file.ext>
---

# thread

Steel-thread tracing. Resolve a symbol or entry point, then surface every
call chain, downstream caller, and execution flow that needs to move with it.

**Target**: $ARGUMENTS

## Preconditions

The code-review-graph MCP must be reachable (`mcp__code-review-graph__*`).
Run `list_graph_stats_tool` first. If the graph is missing or stale relative
to `git rev-parse HEAD`, call `build_or_update_graph_tool` (incremental by
default). For untracked or in-flight changes, pass `base=HEAD` so the diff
window matches what's on disk.

## Pipeline

Run these in order. Stop early if the user only wants a quick answer; the
full pipeline is for review-grade output.

### 1. Resolve the target

`semantic_search_nodes_tool(query=$ARGUMENTS, limit=5)`

Pick the highest-ranked node whose `name` or `qualified_name` matches. If
multiple plausible matches exist, list them and ask the user to disambiguate
before continuing — guessing wastes the rest of the pipeline.

If the target looks like a file path, skip search and pass it directly as
`changed_files=[path]` to the impact/flow tools below.

### 2. First-hop dependents

`query_graph_tool(pattern="callers_of", target=<qualified_name>)`
`query_graph_tool(pattern="importers_of", target=<qualified_name>)`
`query_graph_tool(pattern="tests_for", target=<qualified_name>)`

These three answer "who touches this directly" and "is it tested." Cheap
and precise. Run them in parallel.

### 3. Blast radius

`get_impact_radius_tool(changed_files=[file_of_target], max_depth=2)`

Multi-hop closure of dependents. Bump `max_depth=3` only if depth 2 returns
fewer than a handful of nodes — the cost grows fast.

### 4. Steel threads (the answer the user asked for)

`get_affected_flows_tool(changed_files=[file_of_target])`

Returns the execution flows (entry-point → call chain) that pass through
the symbol's file. Each flow is one steel thread. Rank by `criticality`
when presenting.

### 5. Architectural weight (optional, only if useful)

Only run when the symbol looks load-bearing or the impact set is large:

- `get_hub_nodes_tool` — is the symbol a hub? If so, blast radius is bigger
  than the call graph alone suggests.
- `get_bridge_nodes_tool` — is it a chokepoint between communities? Breaking
  it splits the graph.

Skip both for obviously leaf-shaped symbols.

### 6. Fallback for unknown targets

If step 1 found nothing and the user gave a fuzzy description rather than
a name, fall back to:

`traverse_graph_tool(query=$ARGUMENTS, mode="bfs", depth=3, token_budget=2000)`

BFS from the best-matching node within a token budget. Returns whatever's
nearby — useful when "I think it's somewhere in auth" is the input.

## Output

Present results in this order, dropping sections that came back empty:

```
Target: <qualified_name>  (<file>:<line>, <kind>)

Direct callers (N):
  <name>  <file>:<line>
  ...

Importers (N):
  <file>
  ...

Tests covering target (N):
  <test_name>  <file>:<line>
  ...

Steel threads (M flows, ranked by criticality):
  [<criticality>] <flow_name>  (<entry_kind>)
    <entry> → ... → <target> → ... → <leaf>
  ...

Blast radius (depth 2): N functions, M files
  Hottest impacted nodes:
    <name>  <file>  (degree: D)
    ...

Architectural notes:
  - <hub/bridge findings, only if surfaced>
```

Keep each section to ~5 rows by default; the user can ask for more.

## Decision rules

- One target per invocation. If the user names two symbols, ask which to
  trace first — don't fan out silently.
- Always include the file path next to symbol names. Bare names are useless
  in a repo with collisions.
- If step 4 returns zero flows, say so explicitly — it means the symbol
  isn't on any precomputed execution path (likely a pure helper, dead code,
  or a flow that wasn't detected). Suggest the user check
  `find_dead_code` via `refactor_tool(mode="dead_code")`.
- If the impact set is huge (>50 functions at depth 2), surface that as a
  warning before dumping — the user probably wants to narrow the change.

## What you don't do

- Don't apply refactors. This skill traces; `apply_refactor_tool` is the
  executor and lives behind an explicit user ask.
- Don't run `detect_changes_tool` here — that's for "review my current
  diff," not "trace from a symbol I'm thinking about touching." If the
  user is reviewing committed changes, route them to a review skill instead.
- Don't grep, find, or read source as a fallback when the MCP fails. Surface
  the MCP error so the user can rebuild the graph.

## Gotchas

- Graph staleness is silent: `list_graph_stats` shows `last_update`, but
  uncommitted edits never appear until you call `build_or_update_graph_tool`.
  Rebuild before tracing if the user just edited the target.
- Flow detection skips dynamic dispatch (decorators, registries, plugin
  loaders). Symbols invoked only via framework magic will have empty
  `affected_flows` even when they're on a real execution path.
- `query_graph_tool` patterns expect a `qualified_name`; passing a bare
  `name` works but is ambiguous in repos with shadowed identifiers.
- `get_affected_flows_tool` keys off `changed_files`, not symbol names —
  changing a single function in a busy file will surface every flow
  through that file, not just the ones touching that function. Mention
  this in the output so the user doesn't over-trust the list.
