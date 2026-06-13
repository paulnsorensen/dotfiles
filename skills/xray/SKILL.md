---
name: xray
model: opus
effort: high
description: >
  Interactive design verification via dependency-graph traversal (replaces
  /notebook) — point it at a module, spec, or PR. Use when reviewing large
  modules, verifying agent output, or auditing design, or when the user says
  "review this module", "verify the design", "is this the right architecture",
  "check this code against the spec", "what does this module actually do", or
  invokes /xray.
argument-hint: <module path, spec path, PR number, or concept>
allowed-tools: Read, Write, Glob, Grep, Bash(sg:*), Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git rev-parse:*), Bash(gh:*), Agent, mcp__tilth__tilth_search, mcp__tilth__tilth_read, mcp__tilth__tilth_files, mcp__tilth__tilth_deps, mcp__code-review-graph__list_graph_stats_tool, mcp__code-review-graph__build_or_update_graph_tool, mcp__code-review-graph__embed_graph_tool, mcp__code-review-graph__semantic_search_nodes_tool, mcp__code-review-graph__query_graph_tool, mcp__code-review-graph__get_impact_radius_tool, mcp__code-review-graph__get_affected_flows_tool, mcp__code-review-graph__get_hub_nodes_tool, mcp__code-review-graph__get_bridge_nodes_tool, mcp__code-review-graph__traverse_graph_tool
---

# /xray — Interactive Design Verification

Systematic outside-in verification of code modules via dependency graph traversal.
Leaves first, confidence bubbles up, evidence backs every verdict.

**Target**: $ARGUMENTS

## Preflight: Build the index and embeddings

Before any analysis, make sure the two semantic backends are ready.

### 1. code-review-graph (structural + semantic)

Used for impact radius, affected flows, hub/bridge analysis, and semantic
node search.

1. `mcp__code-review-graph__list_graph_stats_tool` — check the graph exists
   and compare `last_update` against `git rev-parse HEAD`.
2. If missing, stale, or the user has uncommitted edits to the target:
   `mcp__code-review-graph__build_or_update_graph_tool` (incremental by
   default). Pass `base=HEAD` so the diff window matches what's on disk.
3. If stats do not report embeddings as fresh:
   `mcp__code-review-graph__embed_graph_tool` — build / refresh embeddings
   so `semantic_search_nodes_tool` returns useful results.

If the MCP is unreachable, surface the error and stop. Do NOT fall back to
grep — the graph is the whole point of the session.

### 2. tilth (AST-aware code search)

The `mcp__tilth__*` tools are the default for name-shaped or text-shaped
lookups inside this skill — they outline definitions, callers, and usages
in one call. No separate index build is needed; tilth lazily parses on
first use.

Use tilth instead of `Grep` / `Glob` / `Read` whenever you need to:

- Find where a symbol is defined or called → `tilth_search(query, kind="symbol"|"callers")`.
- Pull a file (or a slice) with smart outlining → `tilth_read(paths=[...])`.
- Glob files by pattern → `tilth_files(patterns=[...])`.

For cross-repo or semantic-meaning queries ("the auth middleware", "the
thing that validates orders"), prefer
`mcp__code-review-graph__semantic_search_nodes_tool` — it searches the
embeddings index, not literal text.

## Session Setup

### Parse the target

Determine the target type from $ARGUMENTS:

- **Module path** (e.g. `domains/orders/`, `bin/`): analyze this directory
- **Spec path** (e.g. `.claude/specs/xray.md`): find the module it describes, analyze that
- **PR number** (e.g. `#42`): get changed files via `gh pr diff`, analyze those modules
- **Symbol** (e.g. `validateOrder`, `auth.middleware.requireUser`): resolve via
  `semantic_search_nodes_tool`, then trace its steel threads (see below)
- **Concept** (e.g. "auth flow"): try `semantic_search_nodes_tool` first; fall
  back to `tilth_search(kind="any")` only if the embeddings index returns nothing

Derive a slug from the target: `domains/orders/` → `domains-orders`, `bin/` → `bin`.

### Check for existing session

Look for `.context/xrays/{slug}-graph.json`. If found:

1. Read the existing graph
2. Get the saved `gitSha` from meta
3. Run `git diff {savedSha}..HEAD --name-only` to find changed files
4. For each changed file that maps to a graph node:
   - Downgrade status from `green` to `yellow` (stale)
   - Add note: "File changed since last verification"
   - Keep `red` nodes as `red` (already flagged)
   - Keep `unverified` nodes as `unverified`
5. Display resume summary:

   ```
   Resumed xray session: {slug}
   Nodes: {verified} verified, {stale} stale (files changed), {remaining} remaining
   ```

If no existing session, create `.context/xrays/` if needed.

### Read agent references

Read these references (they're loaded on demand, not upfront):

- `references/graph-schema.json` — graph contract
- `references/sliced-bread-checks.md` — architecture rules
- Agent references are read by the agents themselves

## Graph Building

Spawn an **xray-scout** agent (sonnet) with:

- `targetPath`: the resolved module path
- `slug`: the derived slug

The scout builds the semantic dependency graph using ecosystem dependency tools
(dependency-cruiser, pydeps, cargo-modules, go list) with ast-grep fallback,
enriches with LSP, computes node roles, and writes the graph JSON + Mermaid
visualization.

After the scout returns, read the graph JSON and display the opening dashboard:

### 1. Layered Role Dashboard

```
━━━ {slug} ━━━  {N} nodes, {M} edges, {K} cycles

ENTRY POINTS (nothing imports these)
  controller.ts          fanIn:0  fanOut:3  [ ]

HUBS (high traffic)
  service.ts             fanIn:4  fanOut:5  [ ]

DOMAIN (business logic)
  pricing.ts             fanIn:2  fanOut:2  [ ]

UTILITIES (widely imported, few deps)
  types.ts               fanIn:6  fanOut:1  [·]

LEAVES (import nothing internal)
  validator.ts           fanIn:1  fanOut:0  [ ]

[·] = auto-green candidate
Cycles: {list or "none"}
```

Group nodes by their `role` field from the graph. Within each group, sort by
`fanIn` descending. Show `[·]` marker for auto-green candidates (see Triage).

### 1.5. Barrel Entry Points

Display the barrel file's public exports from `meta.barrelExports` as the
module's contract:

```
Barrel: {meta.barrelFile}
Entry points:
  {barrelExports[].name}({signature or "—"})
  ...
```

If no barrel file found, display:

```
⚠ No barrel/index file found
```

### 2. API Surface Summary

List all nodes where `visibility: "public"`, grouped by file:

```
Exports:
  {module-a}: {symbolName1}, {symbolName2}, {symbolName3}
  {module-b}: {symbolName1}
```

### 3. Upfront Health Scan

Spawn a de-slop scan on the whole target directory. Display results in the
dashboard:

```
Health: {N} de-slop findings across {M} files
  {top 3 findings with file:line}
```

### 4. Encapsulation Summary

From scout's visibility tagging (counts derived from graph nodes):

```
Encapsulation: {N} public exports, {M} private internals
```

Issue counts are added here after analyst reports are generated during the DFS loop.

## Triage

After displaying the dashboard, classify every node into a triage level before
starting the DFS loop. This determines how deeply each node gets analyzed.

### Classification rules

**auto-green** — return immediately, no analysis:

- Leaf node (`role: "leaf"`) with <50 LOC AND exports only types/constants
- Re-export barrel files (all exports are re-exports, no logic)
- Generated code (file header contains `@generated`, `auto-generated`, or similar)
- Terminal nodes (`role: "terminal"`) — always auto-skipped

**light** — skip spec search and external research:

- Leaf node with logic but <100 LOC AND tests exist
- Utility node (`role: "utility"`) with passing tests
- Nodes where all children are already green

**full** — complete analysis pipeline:

- Hub nodes (`role: "hub"`) — always full
- Domain nodes (`role: "domain"`)
- Entry-point nodes (`role: "entry-point"`)
- Any node with a red child
- Any node the user explicitly drills into

### Triage prompt

Present the triage plan and let the user adjust:

```
Triage plan:
  auto-green: {N} nodes ({list or "types.ts, constants.ts, ..."})
  light:      {M} nodes ({list})
  full:       {K} nodes ({list})

  [confirm all]          Accept triage plan
  [review individually]  Step through each classification
  [skip triage]          Full analysis on everything
```

On `confirm all`, apply the triage levels. On `skip triage`, set all nodes to
`triageLevel: "full"`. On `review individually`, present each node with its
proposed level and let the user override.

## DFS Verification Loop

Walk nodes in `dfsOrder` (leaves first). At each node:

**Terminal node handling**: Nodes with `role: "terminal"` are auto-skipped.
Mark as `status: "green"` with evidence "Terminal node (well-known external library)".
Advance to next node without prompting.

### 1. Show position

Display breadcrumb and updated layered view:

```
━━━ Verifying: {symbolName} ({filePath}) [{role}] ━━━
Path: {leaf} → {parent} → {grandparent}
Triage: {auto-green|light|full}

  {root}  [ ]
  ├── {child-a}  [ ]
  │   ├── {current} ← YOU ARE HERE
  │   └── {leaf-2}  [G]
  └── {child-b}  [ ]
```

### 2. Run analysis

Spawn **xray-analyst** (sonnet) for this node with:

- The node data and its edges from the graph (including `role`, `fanIn`, `fanOut`)
- Module name for search context
- Session slug
- `triageLevel`: the triage level assigned to this node

The analyst orchestrates spec-finder and researcher sub-agents (full only),
analyzes contracts, callers, test shape, and architecture, then returns a
structured node report.

**auto-green nodes**: The analyst returns immediately with evidence. Display:

```
━━━ {symbolName} — Auto-Green ━━━
{evidence line}
```

Auto-confirm as green. Advance to next node without prompting.

### 3. Run verification

After the analyst returns (light and full only), spawn **xray-verifier** (sonnet) with:

- The node data
- Test files discovered by the analyst
- Spec criteria from the analyst's findings
- Module name

The verifier runs tests via whey-drainer and de-slop scan in parallel,
then returns a verification report.

### 4. Present findings

Synthesize the analyst and verifier reports into a concise presentation:

```
━━━ {symbolName} — Analysis ━━━

Role: {role}  fanIn:{N}  fanOut:{M}
Contracts: {public API summary}
Spec: {alignment summary or "no spec found"}
Tests: {pass}/{total}, {behavioral_coverage}% behavioral coverage
Architecture: {clean or violations}
De-slop: {finding count}
Build-vs-buy: {flags or "none"}

Proposed: {GREEN|YELLOW|RED} — {evidence summary}
```

### 5. Get user verdict

Present the proposed traffic light and wait for user input:

```
  [confirm]                Accept proposed verdict
  [override G/Y/R]         Override with note (required)
  [note: <text>]           Add observation without confirming
  [skip]                   Skip this node for now
  [drill <symbol>]         Expand to function-level detail
  [drill <symbol> depth=N] N levels of outgoing call hierarchy
  [drill <symbol> callers] Incoming call hierarchy
  [thread <symbol>]        Trace steel threads for a symbol (see Steel Threads)
  [map]                    Show full Mermaid graph with current traffic lights
  [map <node>]             Ego-centric view: node ± 1 level
  [up]                     Bubble to parent node
  [done]                   End session, save progress
```

### 6. Process verdict

- **confirm**: Update node status in graph JSON, add evidence to node,
  set lastVerified timestamp. Advance to next node.
- **override G/Y/R**: Prompt for required note explaining the override.
  Update node with override status and note. Advance.
- **note: text**: Append to node's notes array. Stay on current node.
- **skip**: Leave as unverified, advance to next node.
- **drill symbol**: Expand the node to function-level:
  - Use LSP `documentSymbol` to list all symbols in the file
  - Use LSP `callHierarchy` (outgoing) for the drilled symbol
  - Create child nodes in the graph
  - Enter sub-DFS on the expanded children
  - On completion, collapse back and return to the parent node
- **drill symbol depth=N**: Same as drill but follow outgoing calls N levels deep.
- **drill symbol callers**: Use LSP `callHierarchy` (incoming) to show who calls
  this symbol. Display as a flat list, don't enter sub-DFS.
- **map**: Regenerate the Mermaid graph at `.context/xrays/{slug}-graph.md` with
  current traffic light classDefs applied. Display the path.
- **map node**: Generate an ego-centric Mermaid subgraph showing the focal node
  plus all nodes 1 hop away (direct importers + direct dependencies).
- **up**: Jump to the current node's parent in the tree.
- **done**: Save session and exit.

### 7. Update dashboard

After each verdict, redisplay the layered role view with updated traffic lights.

## Navigation

These commands work at any point in the session:

| Command | Action |
|---------|--------|
| `up` | Bubble to parent node |
| `down` / `drill <symbol>` | Expand function-level detail |
| `drill <symbol> depth=N` | N levels of outgoing call hierarchy |
| `drill <symbol> callers` | Incoming call hierarchy |
| `next` | Skip to next sibling |
| `back` | Return to previous node |
| `tree` | Redisplay layered role dashboard with current traffic lights |
| `map` | Regenerate full Mermaid graph with current traffic lights |
| `map <node>` | Ego-centric view: node ± 1 level of dependencies |
| `thread <symbol>` | Trace steel threads for a symbol (see Steel Threads) |
| `notes` | Show all accumulated notes across nodes |
| `status` | Show progress: N verified, M remaining, K stale |

## Steel Threads

A **steel thread** is an end-to-end execution flow: entry point → call chain →
leaf. When the user asks "what depends on this", "blast radius of changing X",
"what flows pass through this", or runs `thread <symbol>` inside the DFS loop,
run this pipeline. Borrowed from the `/thread` skill but adapted to write
findings into the xray session graph.

### When to invoke automatically

- The user runs `thread <symbol>` at the verdict prompt.
- A node is about to be marked **red** or **yellow** because of architectural
  concerns — trace its threads first so the verdict carries blast-radius
  evidence.
- A hub node (`role: "hub"` with `fanIn > 5`) is up for analysis — its
  threads are the reason it's a hub.

### Pipeline

Run in order. Stop early if the user only wants a quick answer; the full
pipeline is for review-grade output.

#### 1. Resolve the target

`mcp__code-review-graph__semantic_search_nodes_tool(query=<symbol>, limit=5)`

Pick the highest-ranked node whose `name` or `qualified_name` matches. If
several plausible matches exist, list them and ask the user to disambiguate
— guessing wastes the rest of the pipeline.

If the target is a file path, skip the search and pass it as
`changed_files=[path]` to the impact/flow tools below.

#### 2. First-hop dependents (parallel)

- `query_graph_tool(pattern="callers_of", target=<qualified_name>)`
- `query_graph_tool(pattern="importers_of", target=<qualified_name>)`
- `query_graph_tool(pattern="tests_for", target=<qualified_name>)`

These three answer "who touches this directly" and "is it tested." Cheap
and precise — run them in a single batched turn.

#### 3. Blast radius

`get_impact_radius_tool(changed_files=[file_of_target], max_depth=2)`

Multi-hop closure of dependents. Bump `max_depth=3` only if depth 2 returns
fewer than a handful of nodes — cost grows fast.

#### 4. Steel threads (the answer)

`get_affected_flows_tool(changed_files=[file_of_target])`

Returns the execution flows (entry → call chain) that pass through the
symbol's file. Each flow is one steel thread. Rank by `criticality` when
presenting.

#### 5. Architectural weight (optional)

Only when the symbol looks load-bearing or the impact set is large:

- `get_hub_nodes_tool` — is this a hub? Blast radius is larger than the
  raw call graph suggests.
- `get_bridge_nodes_tool` — is it a chokepoint between communities?
  Breaking it splits the graph.

Skip both for obviously leaf-shaped symbols.

#### 6. Fallback for fuzzy targets

If step 1 finds nothing and the user gave a description ("the thing that
validates orders") rather than a name:

`traverse_graph_tool(query=<input>, mode="bfs", depth=3, token_budget=2000)`

BFS from the best-matching node within a token budget — returns whatever's
nearby.

### Output

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

### Persist into the session

After the steel-thread pipeline runs, append a `threads` block to the
current node in the graph JSON:

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

### Decision rules

- One target per `thread` invocation. If the user names two symbols, ask
  which to trace first.
- Always include the file path next to symbol names — bare names are
  useless in repos with collisions.
- If step 4 returns zero flows, say so explicitly — the symbol isn't on a
  precomputed execution path (pure helper, dead code, or framework-magic
  dispatch the graph couldn't follow). Suggest the user check dead-code
  detection if appropriate.
- If the impact set is huge (>50 functions at depth 2), flag it as a
  warning before dumping — the user probably wants to narrow the change.

### Steel-thread gotchas

- If the user edits the target mid-pipeline, re-run
  `build_or_update_graph_tool` + `embed_graph_tool` before continuing.
- Flow detection skips dynamic dispatch (decorators, registries, plugin
  loaders). Symbols invoked only via framework magic will have empty
  `affected_flows` even when they're on a real execution path.
- `query_graph_tool` patterns expect a `qualified_name`; a bare `name`
  works but is ambiguous in repos with shadowed identifiers.
- `get_affected_flows_tool` keys off `changed_files`, not symbol names —
  changing a single function in a busy file surfaces every flow through
  that file. Call this out in the output so the user doesn't over-trust
  the list.

## Traffic Light System

### Evidence-based proposal

The tool proposes a traffic light based on concrete evidence:

**Green** (all must be true):

- Tests exist and pass
- Spec aligned (when spec exists) or heuristic coverage is high
- No de-slop findings
- Architecture checks pass
- No build-vs-buy flags

**Yellow** (any one of):

- Partial test coverage or some tests mock-heavy
- Minor architecture findings (growth justification, premature structure)
- Minor de-slop findings (comment pollution, verbose names)
- Build-vs-buy opportunity (not critical)

**Red** (any one of):

- Tests fail
- No tests exist
- Major architecture violation (model purity, dependency direction)
- Significant spec gaps (< 50% criteria covered)
- Critical de-slop findings (silent error swallowing, dead code)

### Confidence propagation

When ALL children of a node are green:

- Parent's proposed confidence starts higher (evidence: "all dependencies verified green")
- This is a boost, not automatic green — the parent still needs its own analysis

When ANY child is red:

- Parent's analysis must address the red dependency
- Note: "Depends on {child} which is RED — {reason}"

## Persistence

### Save session state

After each verdict or on `done`, save:

**Graph JSON** (`.context/xrays/{slug}-graph.json`):

- Updated node statuses, notes, evidence, lastVerified timestamps
- Current git HEAD SHA in meta.gitSha
- Updated meta.lastVerified timestamp

**Mermaid graph** (`.context/xrays/{slug}-graph.md`):

- Updated traffic light classDefs on verified nodes

**Session notes** (`.context/xrays/{slug}.md`):

```markdown
---
slug: {slug}
target: {targetPath}
created: {date}
lastUpdated: {date}
gitSha: {sha}
progress: {verified}/{total} nodes
---

# XRay: {slug}

## Progress
- Verified: {N} ({green} green, {yellow} yellow, {red} red)
- Auto-green: {K}
- Remaining: {M}
- Stale: {J}

## Node Notes
### {node-1 symbolName} [{status}]
{accumulated notes}

### {node-2 symbolName} [{status}]
{accumulated notes}

## Session Log
- {timestamp}: Started xray on {target}
- {timestamp}: {node} marked {color} — {reason}
```

### Session Limits

After ~40 tool calls or 15 nodes analyzed, suggest saving progress and resuming
in a fresh session to avoid context degradation. Interactive sessions accumulate
context faster than batch operations.

### Wrap-up

When the user says `done` or all nodes are verified:

1. Save final state
2. Display summary:

   ```
   ━━━ XRay Complete: {slug} ━━━
   Green: {N}  Yellow: {M}  Red: {K}  Unverified: {J}

   Key findings:
   - {top finding 1}
   - {top finding 2}
   - {top finding 3}
   ```

3. Offer next steps:
   - "Run `/wreck` on red nodes to write missing tests?"
   - "Create GitHub issues for red/yellow findings?"
   - "Run `/de-slop` to fix detected anti-patterns?"

## Out of Scope

- Not `/age` — that reviews diffs between commits. This reviews design.
- Not `/de-slop` standalone — de-slop runs as part of xray verification.
- Not `/test` — test execution is delegated to whey-drainer within xray.
- Not a CI gate — this is interactive, human-in-the-loop verification.

## What You Don't Do

- Auto-fix findings — suggest /de-slop or /wreck instead, let the user decide
- Run without user confirmation at each node — this is interactive by design
- Replace /age — xray verifies design decisions, not code quality
- Write tests — delegate to /wreck for adversarial testing

## Gotchas

- Dependency graph building fails on repos without standard import patterns — fall back to manual node selection
- LSP `callHierarchy` is not available for all languages — use `tilth_search(kind="callers")` as the fallback before reaching for grep
- `.context/xrays/` directory requires write access — create it if missing
- Mermaid graphs break above ~50 nodes — split into subgraphs for large modules
- Sub-agent spawning (xray-scout, xray-analyst, xray-verifier) adds latency — budget 30s per node
- If the user edits files mid-session, re-run `build_or_update_graph_tool` + `embed_graph_tool` before the next semantic query
