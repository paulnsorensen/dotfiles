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
argument-hint: <module path, spec path, PR number, symbol, or concept>
allowed-tools: Read, Write, Glob, Grep, Bash(sg:*), Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git rev-parse:*), Bash(gh:*), Agent, mcp__tilth__tilth_search, mcp__tilth__tilth_read, mcp__tilth__tilth_list, mcp__tilth__tilth_deps
---

# /xray — Interactive Design Verification

Systematic outside-in verification of code modules via dependency graph traversal.
Leaves first, confidence bubbles up, evidence backs every verdict.

**Target**: $ARGUMENTS

## Preflight: Code-intelligence tools

Before any analysis, orient with the code-intelligence tools your harness
exposes. Use whatever LSP- and MCP-backed tooling is available — symbol and
reference lookup, AST-aware search/read, dependency/blast-radius queries —
rather than reaching for `grep` first. No specific tool is mandatory; pick
the best available for each lookup.

In this repo that means the `mcp__tilth__*` tools are the default for
name-shaped or text-shaped lookups — they outline definitions, callers, and
usages in one call. No separate index build is needed; tilth lazily parses on
first use. Where an LSP is available, prefer it for type-grounded questions
(symbol resolution, call hierarchy, reference sets).

Use these instead of `Grep` / `Glob` / `Read` whenever you need to:

- Find where a symbol is defined or called → `tilth_search(query, kind="symbol"|"callers")`.
- Pull a file (or a slice) with smart outlining → `tilth_read(paths=[...])`.
- List files by pattern → `tilth_list(patterns=[...])`.
- Check a symbol's or file's blast radius → `tilth_deps(path=...)`.

For semantic-meaning queries ("the auth middleware", "the thing that validates
orders"), lead with a semantic MCP search if one is available; otherwise fall
back to `tilth_search(kind="any")` over the concept's vocabulary.

## Session Setup

### Parse the target

Determine the target type from $ARGUMENTS:

- **Module path** (e.g. `domains/orders/`, `bin/`): analyze this directory
- **Spec path** (e.g. `.claude/specs/xray.md`): find the module it describes, analyze that
- **PR number** (e.g. `#42`): get changed files via `gh pr diff`, analyze those modules
- **Symbol** (e.g. `validateOrder`, `auth.middleware.requireUser`): resolve it
  with the available symbol search (LSP symbol lookup or `tilth_search`), then
  trace its steel threads (see below)
- **Concept** (e.g. "auth flow"): resolve it with a semantic MCP search if one
  is available, otherwise `tilth_search(kind="any")` over the concept's vocabulary

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

Use the available LSP- and MCP-backed code-intelligence tools at each step —
symbol/reference lookup, call hierarchy, dependency/blast-radius queries,
semantic search. No specific tool is mandatory; the examples below name the
tilth tools this repo exposes, but any equivalent works.

#### 1. Resolve the target

Resolve the symbol to a concrete definition (file, line, kind) with the
available symbol search — LSP symbol lookup, a semantic MCP search, or
`tilth_search(query=<symbol>, kind="symbol")`. Pick the definition whose
`name` or qualified name matches. If several plausible matches exist, list
them and ask the user to disambiguate — guessing wastes the rest of the
pipeline.

If the target is a file path, skip the search and use it directly as the
changed file for the dependency/blast-radius steps below.

#### 2. First-hop dependents (parallel)

Find who touches the target directly and whether it's tested:

- Direct callers → LSP call hierarchy (incoming) or `tilth_search(kind="callers")`.
- Importers of the file → `tilth_deps(path=<file>)` or an import/reference query.
- Tests covering it → `tilth_search` for the symbol name in test files.

Cheap and precise — run them in a single batched turn.

#### 3. Blast radius

Walk the dependency closure outward from the target's file with
`tilth_deps(path=<file>)` (or an equivalent impact-radius query). Keep the
depth shallow first; widen only if the first hop returns a handful of nodes —
cost grows fast.

#### 4. Steel threads (the answer)

Follow the call chain from each first-hop caller outward to its entry point
(nothing calls it) and inward to the leaves, layer by layer, using call
hierarchy / caller lookups. Each entry → … → target → … → leaf path is one
steel thread. If a precomputed flow/impact tool is available, prefer it —
it already assembles these chains. Rank threads by how critical the entry
point is when presenting.

#### 5. Architectural weight (optional)

Only when the symbol looks critical or the impact set is large, judge whether
it is:

- A **hub** — high fan-in/fan-out; blast radius is larger than the raw call
  graph suggests. Derive from the session graph's `role`/`fanIn`/`fanOut` or
  a hub-node query if one is available.
- A **bridge** — a chokepoint between otherwise-disconnected areas. Breaking
  it splits the graph.

Skip both for obviously leaf-shaped symbols.

#### 6. Fallback for fuzzy targets

If step 1 finds nothing and the user gave a description ("the thing that
validates orders") rather than a name, broaden the search: run a semantic MCP
search over the concept vocabulary if available, else `tilth_search(kind="any")`,
and traverse outward from the best-matching node.

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
- If step 4 surfaces zero threads, say so explicitly — the symbol isn't on a
  reachable execution path (pure helper, dead code, or framework-magic
  dispatch the call graph couldn't follow). Suggest the user check dead-code
  detection if appropriate.
- If the impact set is huge (>50 functions at depth 2), flag it as a
  warning before dumping — the user probably wants to narrow the change.

### Steel-thread gotchas

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
   - "Run `/press` on red nodes to write missing tests?"
   - "Create GitHub issues for red/yellow findings?"
   - "Run `/de-slop` to fix detected anti-patterns?"

## Out of Scope

- Not `/age` — that reviews diffs between commits. This reviews design.
- Not `/de-slop` standalone — de-slop runs as part of xray verification.
- Not `/test` — test execution is delegated to whey-drainer within xray.
- Not a CI gate — this is interactive, human-in-the-loop verification.

## What You Don't Do

- Auto-fix findings — suggest /de-slop or /press instead, let the user decide
- Run without user confirmation at each node — this is interactive by design
- Replace /age — xray verifies design decisions, not code quality
- Write tests — delegate to /press for adversarial testing

## Gotchas

- Dependency graph building fails on repos without standard import patterns — fall back to manual node selection
- LSP `callHierarchy` is not available for all languages — use `tilth_search(kind="callers")` as the fallback before reaching for grep
- `.context/xrays/` directory requires write access — create it if missing
- Mermaid graphs break above ~50 nodes — split into subgraphs for large modules
- Sub-agent spawning (xray-scout, xray-analyst, xray-verifier) adds latency — budget 30s per node
- If the user edits files mid-session, re-resolve affected symbols and re-run the caller/dependency lookups before the next query — code-intelligence results go stale as soon as a file changes
