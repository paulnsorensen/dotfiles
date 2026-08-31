# Session Display Formats

Exact output templates for the xray session. SKILL.md names each block; this
file holds the layouts. Substitute `{placeholders}` from the graph JSON.

## Resume summary

```
Resumed xray session: {slug}
Nodes: {verified} verified, {stale} stale (files changed), {remaining} remaining
```

## Opening dashboard

### Layered role dashboard

Group nodes by their `role` field. Within each group, sort by `fanIn`
descending. Show `[·]` for auto-green candidates.

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

### Barrel entry points

From `meta.barrelExports`:

```
Barrel: {meta.barrelFile}
Entry points:
  {barrelExports[].name}({signature or "—"})
  ...
```

If no barrel file found: `⚠ No barrel/index file found`

### API surface summary

All nodes where `visibility: "public"`, grouped by file:

```
Exports:
  {module-a}: {symbolName1}, {symbolName2}, {symbolName3}
  {module-b}: {symbolName1}
```

### Upfront health scan

```
Health: {N} de-slop findings across {M} files
  {top 3 findings with file:line}
```

### Encapsulation summary

```
Encapsulation: {N} public exports, {M} private internals
```

Issue counts are added here after analyst reports are generated during the
DFS loop.

## Triage prompt

```
Triage plan:
  auto-green: {N} nodes ({list or "types.ts, constants.ts, ..."})
  light:      {M} nodes ({list})
  full:       {K} nodes ({list})

  [confirm all]          Accept triage plan
  [review individually]  Step through each classification
  [skip triage]          Full analysis on everything
```

## Node position breadcrumb

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

## Auto-green node

```
━━━ {symbolName} — Auto-Green ━━━
{evidence line}
```

## Node findings presentation

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

## Session notes file

`.context/xrays/{slug}.md`:

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

## Wrap-up summary

```
━━━ XRay Complete: {slug} ━━━
Green: {N}  Yellow: {M}  Red: {K}  Unverified: {J}

Key findings:
- {top finding 1}
- {top finding 2}
- {top finding 3}
```
