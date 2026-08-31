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
  invokes /xray. Do NOT use for a standalone "trace this concept" or "blast
  radius" question with no verification session — that is /steel-thread.
argument-hint: <module path, spec path, PR number, symbol, or concept>
allowed-tools: Read, Write, Glob, Grep, Bash(sg:*), Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git rev-parse:*), Bash(gh:*), Agent, mcp__tilth__tilth_search, mcp__tilth__tilth_read, mcp__tilth__tilth_list, mcp__tilth__tilth_deps
---

# /xray — Interactive Design Verification

Systematic outside-in verification of code modules via dependency graph traversal.
Leaves first, confidence bubbles up, evidence backs every verdict.

**Target**: $ARGUMENTS

## Preflight: Code-intelligence tools

Orient with the code-intelligence tools your harness exposes — symbol and
reference lookup, AST-aware search/read, dependency/blast-radius queries —
rather than reaching for `grep` first. No specific tool is mandatory. In this
repo the `mcp__tilth__*` tools are the default: `tilth_search` for symbols,
callers, or text; `tilth_read` for outlined file reads; `tilth_list` for
pattern listing; `tilth_deps` for blast radius. No index build needed — tilth
lazily parses on first use. Prefer an LSP, where available, for type-grounded
questions (symbol resolution, call hierarchy, reference sets). For
semantic-meaning queries ("the auth middleware"), lead with a semantic MCP
search if available; otherwise `tilth_search(kind="any")` over the concept's
vocabulary.

## Session Setup

### Parse the target

Determine the target type from $ARGUMENTS:

- **Module path** (e.g. `domains/orders/`, `bin/`): analyze this directory
- **Spec path** (e.g. `.claude/specs/xray.md`): find the module it describes, analyze that
- **PR number** (e.g. `#42`): get changed files via `gh pr diff`, analyze those modules
- **Symbol** (e.g. `validateOrder`): resolve it with the available symbol
  search (LSP symbol lookup or `tilth_search`), then trace its steel threads
  (see Steel Threads)
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
5. Display the resume summary (see `references/session-formats.md`)

If no existing session, create `.context/xrays/` if needed.

### Read references

Read these on demand, not upfront:

- `references/graph-schema.json` — graph contract
- `references/sliced-bread-checks.md` — architecture rules
- `references/session-formats.md` — exact display templates for every block
  named below (dashboard, triage prompt, breadcrumb, findings, session notes,
  wrap-up)
- `references/steel-threads.md` — the thread-tracing pipeline (read when a
  Steel Threads trigger fires)
- Agent references are read by the agents themselves

## Graph Building

Spawn an **xray-scout** agent (sonnet) with:

- `targetPath`: the resolved module path
- `slug`: the derived slug

The scout builds the semantic dependency graph using ecosystem dependency tools
(dependency-cruiser, pydeps, cargo-modules, go list) with ast-grep fallback,
enriches with LSP, computes node roles, and writes the graph JSON + Mermaid
visualization.

After the scout returns, read the graph JSON and display the opening dashboard
(templates in `references/session-formats.md`):

1. **Layered role dashboard** — nodes grouped by `role`, sorted by `fanIn`
   descending within each group, with auto-green candidates marked
2. **Barrel entry points** — the module's public contract from
   `meta.barrelExports`; warn if no barrel/index file exists
3. **API surface summary** — all `visibility: "public"` nodes, grouped by file
4. **Upfront health scan** — spawn a de-slop scan on the whole target
   directory; show the finding count and top 3 findings
5. **Encapsulation summary** — public-export vs private-internal counts from
   the scout's visibility tagging; issue counts are appended later as analyst
   reports arrive

## Triage

After the dashboard, classify every node into a triage level before starting
the DFS loop. This determines how deeply each node gets analyzed.

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

Present the triage plan (template in `references/session-formats.md`) with
three options. On `confirm all`, apply the triage levels. On `skip triage`,
set all nodes to `triageLevel: "full"`. On `review individually`, present each
node with its proposed level and let the user override.

## DFS Verification Loop

Walk nodes in `dfsOrder` (leaves first). At each node:

**Terminal node handling**: Nodes with `role: "terminal"` are auto-skipped.
Mark as `status: "green"` with evidence "Terminal node (well-known external library)".
Advance to next node without prompting.

### 1. Show position

Display the breadcrumb and updated layered view (template in
`references/session-formats.md`).

### 2. Run analysis

Spawn **xray-analyst** (sonnet) for this node with:

- The node data and its edges from the graph (including `role`, `fanIn`, `fanOut`)
- Module name for search context
- Session slug
- `triageLevel`: the triage level assigned to this node

The analyst orchestrates spec-finder and researcher sub-agents (full only),
analyzes contracts, callers, test shape, and architecture, then returns a
structured node report.

**auto-green nodes**: The analyst returns immediately with evidence. Display
the auto-green block, auto-confirm as green, and advance without prompting.

### 3. Run verification

After the analyst returns (light and full only), spawn **xray-verifier**
(sonnet) with the node data, test files discovered by the analyst, spec
criteria from the analyst's findings, and the module name. The verifier runs
tests via whey-drainer and de-slop scan in parallel, then returns a
verification report.

### 4. Present findings

Synthesize the analyst and verifier reports into the node findings
presentation (template in `references/session-formats.md`): role and fan
counts, contracts, spec alignment, test results and behavioral coverage,
architecture, de-slop count, build-vs-buy flags, and the proposed
GREEN/YELLOW/RED verdict with evidence summary.

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
- **drill symbol**: Expand the node to function-level: list the file's symbols
  via LSP `documentSymbol`, follow LSP `callHierarchy` (outgoing) for the
  drilled symbol, create child nodes in the graph, and enter sub-DFS on the
  expanded children. On completion, collapse back to the parent node.
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

These commands work at any point in the session, alongside the verdict-menu
commands above (`drill`, `map`, `thread`, `up`):

| Command | Action |
|---------|--------|
| `next` | Skip to next sibling |
| `back` | Return to previous node |
| `tree` | Redisplay layered role dashboard with current traffic lights |
| `notes` | Show all accumulated notes across nodes |
| `status` | Show progress: N verified, M remaining, K stale |

## Steel Threads

A **steel thread** is an end-to-end execution flow: entry point → call chain →
leaf. Run the pipeline in `references/steel-threads.md` (resolve → first-hop
dependents → blast radius → thread assembly → architectural weight, with
output format, session persistence, and gotchas) when:

- The user runs `thread <symbol>` at the verdict prompt, or asks "what depends
  on this", "blast radius of changing X", "what flows pass through this".
- A node is about to be marked **red** or **yellow** because of architectural
  concerns — trace its threads first so the verdict carries blast-radius
  evidence.
- A hub node (`role: "hub"` with `fanIn > 5`) is up for analysis — its
  threads are the reason it's a hub.

Findings persist as a `threads` block on the current node, so later nodes
inherit blast-radius context without re-running the pipeline. For standalone
concept tracing outside an xray session, route to `/steel-thread` instead.

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

- **Graph JSON** (`.context/xrays/{slug}-graph.json`): updated node statuses,
  notes, evidence, lastVerified timestamps; current git HEAD SHA in
  `meta.gitSha`; updated `meta.lastVerified`
- **Mermaid graph** (`.context/xrays/{slug}-graph.md`): updated traffic light
  classDefs on verified nodes
- **Session notes** (`.context/xrays/{slug}.md`): progress counts, per-node
  notes, session log — template in `references/session-formats.md`

### Session limits

After ~40 tool calls or 15 nodes analyzed, suggest saving progress and resuming
in a fresh session to avoid context degradation. Interactive sessions accumulate
context faster than batch operations.

### Wrap-up

When the user says `done` or all nodes are verified:

1. Save final state
2. Display the wrap-up summary (template in `references/session-formats.md`):
   traffic-light totals plus the top 3 findings
3. Offer next steps:
   - "Run `/press` on red nodes to write missing tests?"
   - "Create GitHub issues for red/yellow findings?"
   - "Run `/de-slop` to fix detected anti-patterns?"

## Out of Scope

- Not `/age` — that reviews diffs between commits. This reviews design.
- Not `/steel-thread` — that is standalone concept tracing with no session;
  xray's thread pipeline writes into the session graph.
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
