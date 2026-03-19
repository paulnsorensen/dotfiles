---
name: xray
description: >
  Interactive design verification via dependency graph traversal. Replaces /notebook.
  Use when reviewing large modules, verifying agent output, auditing design decisions,
  or when you need to understand whether code does what it should. Point it at a module,
  spec, or PR. Triggers on: /xray, "review this module", "verify the design",
  "is this the right architecture", "check this code against the spec",
  "what does this module actually do", design review, code audit.
argument-hint: <module path, spec path, PR number, or concept>
allowed-tools: Read, Write, Glob, Grep, Bash(sg:*), Bash(git diff:*), Bash(git log:*), Bash(gh:*), Agent
---

# /xray — Interactive Design Verification

Systematic outside-in verification of code modules via dependency graph traversal.
Leaves first, confidence bubbles up, evidence backs every verdict.

**Target**: $ARGUMENTS

## Session Setup

### Parse the target

Determine the target type from $ARGUMENTS:
- **Module path** (e.g. `domains/orders/`, `bin/`): analyze this directory
- **Spec path** (e.g. `.claude/specs/xray.md`): find the module it describes, analyze that
- **PR number** (e.g. `#42`): get changed files via `gh pr diff`, analyze those modules
- **Concept** (e.g. "auth flow"): use Grep/Glob to locate the relevant module(s)

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

The scout builds the semantic dependency graph using LSP + ast-grep and writes
it to `.context/xrays/{slug}-graph.json`.

After the scout returns, read the graph JSON and display the opening dashboard:

### 1. ASCII Dependency Tree

```
{slug} dependency graph — all nodes unverified

  {root-module}  [ ]
  ├── {child-a}  [ ]
  │   ├── {leaf-1}  [ ]
  │   └── {leaf-2}  [ ]
  └── {child-b}  [ ]
      └── {leaf-3}  [ ]

Legend: [G] green  [Y] yellow  [R] red  [ ] unverified
```

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

## DFS Verification Loop

Walk nodes in `dfsOrder` (leaves first). At each node:

### 1. Show position

Display breadcrumb and updated tree:

```
━━━ Verifying: {symbolName} ({filePath}) ━━━
Path: {leaf} → {parent} → {grandparent}

  {root}  [ ]
  ├── {child-a}  [ ]
  │   ├── {current} ← YOU ARE HERE
  │   └── {leaf-2}  [G]
  └── {child-b}  [ ]
```

### 2. Run analysis

Spawn **xray-analyst** (sonnet) for this node with:
- The node data and its edges from the graph
- Module name for search context
- Session slug

The analyst orchestrates spec-finder and researcher sub-agents, analyzes
contracts, callers, test shape, and architecture, then returns a structured
node report.

### 3. Run verification

After the analyst returns, spawn **xray-verifier** (sonnet) with:
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
  [confirm]          Accept proposed verdict
  [override G/Y/R]   Override with note (required)
  [note: <text>]     Add observation without confirming
  [skip]             Skip this node for now
  [drill <symbol>]   Expand to function-level detail
  [up]               Bubble to parent node
  [done]             End session, save progress
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
- **up**: Jump to the current node's parent in the tree.
- **done**: Save session and exit.

### 7. Update tree

After each verdict, redisplay the ASCII tree with updated traffic lights.

## Navigation

These commands work at any point in the session:

| Command | Action |
|---------|--------|
| `up` | Bubble to parent node |
| `down` / `drill <symbol>` | Expand function-level detail |
| `next` | Skip to next sibling |
| `back` | Return to previous node |
| `tree` | Redisplay full ASCII tree with current traffic lights |
| `notes` | Show all accumulated notes across nodes |
| `status` | Show progress: N verified, M remaining, K stale |

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
- Remaining: {M}
- Stale: {K}

## Node Notes
### {node-1 symbolName} [{status}]
{accumulated notes}

### {node-2 symbolName} [{status}]
{accumulated notes}

## Session Log
- {timestamp}: Started xray on {target}
- {timestamp}: {node} marked {color} — {reason}
```

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
