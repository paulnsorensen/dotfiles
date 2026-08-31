# Steel Thread Pipeline

End-to-end execution-flow tracing inside an xray session. Read this when the
user runs `thread <symbol>` or a trigger in SKILL.md's Steel Threads section
fires. Borrowed from the standalone `/steel-thread` skill but adapted to write
findings into the xray session graph.

Run the steps in order. Stop early if the user only wants a quick answer; the
full pipeline is for review-grade output.

Use the available LSP- and MCP-backed code-intelligence tools at each step —
symbol/reference lookup, call hierarchy, dependency/blast-radius queries,
semantic search. No specific tool is mandatory; the examples below name the
tilth tools this repo exposes, but any equivalent works.

## Pipeline

### 1. Resolve the target

Resolve the symbol to a concrete definition (file, line, kind) with the
available symbol search — LSP symbol lookup, a semantic MCP search, or
`tilth_search(query=<symbol>, kind="symbol")`. Pick the definition whose
`name` or qualified name matches. If several plausible matches exist, list
them and ask the user to disambiguate — guessing wastes the rest of the
pipeline.

If the target is a file path, skip the search and use it directly as the
changed file for the dependency/blast-radius steps below.

### 2. First-hop dependents (parallel)

Find who touches the target directly and whether it's tested:

- Direct callers → LSP call hierarchy (incoming) or `tilth_search(kind="callers")`.
- Importers of the file → `tilth_deps(path=<file>)` or an import/reference query.
- Tests covering it → `tilth_search` for the symbol name in test files.

Cheap and precise — run them in a single batched turn.

### 3. Blast radius

Walk the dependency closure outward from the target's file with
`tilth_deps(path=<file>)` (or an equivalent impact-radius query). Keep the
depth shallow first; widen only if the first hop returns a handful of nodes —
cost grows fast.

### 4. Steel threads (the answer)

Follow the call chain from each first-hop caller outward to its entry point
(nothing calls it) and inward to the leaves, layer by layer, using call
hierarchy / caller lookups. Each entry → … → target → … → leaf path is one
steel thread. If a precomputed flow/impact tool is available, prefer it —
it already assembles these chains. Rank threads by how critical the entry
point is when presenting.

### 5. Architectural weight (optional)

Only when the symbol looks critical or the impact set is large, judge whether
it is:

- A **hub** — high fan-in/fan-out; blast radius is larger than the raw call
  graph suggests. Derive from the session graph's `role`/`fanIn`/`fanOut` or
  a hub-node query if one is available.
- A **bridge** — a chokepoint between otherwise-disconnected areas. Breaking
  it splits the graph.

Skip both for obviously leaf-shaped symbols.

### 6. Fallback for fuzzy targets

If step 1 finds nothing and the user gave a description ("the thing that
validates orders") rather than a name, broaden the search: run a semantic MCP
search over the concept vocabulary if available, else `tilth_search(kind="any")`,
and traverse outward from the best-matching node.

## Output

Drop sections that came back empty:

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

Keep each section to ~5 rows; the user can ask for more.

## Persist into the session

After the pipeline runs, append a `threads` block to the current node in the
graph JSON (the shape is defined in `graph-schema.json`):

```json
"threads": {
  "directCallers": [...],
  "flows": [{"name": ..., "criticality": ..., "chain": [...]}],
  "blastRadius": {"depth": 2, "functions": N, "files": M},
  "hub": true|false,
  "bridge": true|false,
  "capturedAt": "<timestamp>"
}
```

This lets later nodes inherit blast-radius context without re-running the
pipeline.

## Decision rules

- One target per `thread` invocation. If the user names two symbols, ask
  which to trace first.
- Always include the file path next to symbol names — bare names are
  useless in repos with collisions.
- If step 4 surfaces zero threads, say so explicitly — the symbol isn't on a
  reachable execution path (pure helper, dead code, or framework-magic
  dispatch the call graph couldn't follow). Suggest the user check dead-code
  detection if appropriate.
- If the impact set is huge (>50 functions at depth 2), flag it as a
  warning before dumping — the user probably wants to narrow the change.

## Gotchas

- If the user edits the target mid-pipeline, re-resolve it and re-run the
  caller/dependency lookups before continuing — code-intelligence results go
  stale as soon as the file changes.
- Call-graph tools skip dynamic dispatch (decorators, registries, plugin
  loaders). Symbols invoked only via framework magic will show no callers
  even when they're on a real execution path — note this in the output.
- Bare symbol names are ambiguous in repos with shadowed identifiers; prefer
  a qualified name or file:line when querying and when presenting.
- File-keyed impact queries (e.g. `tilth_deps` on a file) surface every
  dependent of the *whole file* — changing one function in a busy file over-
  reports. Call this out so the user doesn't over-trust the list.
