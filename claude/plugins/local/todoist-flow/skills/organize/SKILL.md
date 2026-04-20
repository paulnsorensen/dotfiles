---
name: organize
description: "Audit and restructure Todoist projects, labels, sections, and filters. Proposes changes with approval before executing. Use when the user says 'organize todoist', 'restructure projects', 'clean up projects', 'fix my todoist structure', 'audit labels', 'create filters', or when /todoist dashboard shows structural issues (too many projects, empty projects, missing filters)."
---

# Todoist Organize

Audit the structural health of the user's Todoist workspace and propose targeted improvements. Every change requires explicit user approval.

## Flow

### Step 1: Audit Current State

Spawn todoist-fetch to gather all audit data in a fresh context window:

```
Agent(subagent_type: "todoist-fetch", prompt: "Fetch full workspace audit data: 1) find-projects with task counts, 2) find-labels with usage counts, 3) find-sections across all projects, 4) find-filters (all existing), 5) analyze-project-health for health metrics. Return structured inventory with IDs and counts for each category.")
```

### Step 2: Identify Issues

Check for these structural problems (from best practices in `${CLAUDE_PLUGIN_ROOT}/references/best-practices.md`):

**Projects:**

- Empty projects (0 tasks) — candidates for archival
- Oversized projects (>30 tasks without sections) — need sectioning or splitting
- Too many active projects (>15) — cognitive overload
- Deep nesting (>2 levels) — flatten
- Projects without clear outcomes (noun-only names like "Ideas" or "Misc")

**Labels:**

- Orphan labels (exist but used by 0 tasks)
- Labels used as containers instead of attributes (e.g., `@client-name` with many tasks)
- Missing high-value labels (`@waiting`, `@deep-work`, `@quick-win` not present)

**Sections:**

- Projects with >30 tasks and no sections
- Empty sections (cruft)

**Filters:**

- Missing cockpit filters (the user should have at least 3 working views)
- Suggested filters: Today, Deep Work, Quick Wins, Waiting On, Weekly Review

### Step 3: Present Audit Report

```
## Todoist Structure Audit

### Projects (X active)
- [issue] "Misc" has 45 tasks and no sections → Split or add sections
- [issue] "Old ideas" is empty → Archive
- [good] 12 active projects (under 15 limit)

### Labels (X total)
- [issue] @client-acme has 30 tasks → Convert to a project
- [issue] No @waiting label → Create it
- [good] @deep-work in use (8 tasks)

### Sections
- [issue] "Work" has 38 tasks, no sections → Add phase sections

### Filters (X total)
- [issue] No "Today" filter → Create: (today | overdue) & !#Someday
- [issue] No "Waiting" filter → Create: @waiting
- [good] "This Week" filter exists
```

### Step 4: Propose Changes

Group changes into categories and present as a plan:

```
## Proposed Changes

### Quick wins (safe, low-risk):
1. Archive empty project "Old ideas"
2. Create @waiting label
3. Create "Today" filter: (today | overdue) & !#Someday

### Structural (review each):
4. Add sections to "Work" project: Backlog / In Progress / Done
5. Convert @client-acme label to a project (move 30 tasks)

Approve all quick wins? (y/n)
Then I'll walk through structural changes one at a time.
```

Use `AskUserQuestion` for approval. For quick wins, batch approval is fine. For structural changes, get approval per change.

### Step 5: Execute

Run approved changes through the write pipeline (distill → scribe → QA):

**1. Validate reasoning** — spawn todoist-distill:

```
Agent(subagent_type: "todoist-distill", prompt: "Validate these structural changes against user approval: [approved changes with context]")
```

**2. Format commands** — spawn todoist-scribe with validated plan:

```
Agent(subagent_type: "todoist-scribe", prompt: "Format these validated structural operations as MCP commands: [distill's validated plan]")
```

**3. Verify and execute** — spawn todoist-qa:

```
Agent(subagent_type: "todoist-qa", prompt: "Verify and execute: [scribe's formatted commands]. Original intent: [distill's validated plan]")
```

For large batches (10+ operations), split into logical groups (filters, sections, project changes) and run each group through the pipeline separately.

### Step 6: Verify

After execution, re-fetch overview and show before/after:

```
## Results
- Projects: 18 → 14 (archived 4 empty)
- Labels: +2 created (@waiting, @quick-win), -1 converted (→ project)
- Filters: +3 cockpit filters created
- Sections: +3 added to "Work" project
```

## Research Integration

If the user wants advice on how to structure a specific domain (e.g., "how should I organize my home renovation project?"), invoke the research skill:

```
Skill(skill: "research", args: "Best practices for organizing [domain] tasks in a task management system. Suggest project structure, sections, and labels.")
```

## Key Principles

- **Propose, don't impose** — every change gets user approval. The user knows their workflow better than any best practice doc.
- **Quick wins first** — low-risk changes build momentum and trust before structural ones.
- **Rename before restructure** — renaming a project preserves task history. Prefer rename over delete+recreate.
- **Filters are the highest-value change** — if the user has no cockpit filters, creating 3-5 filters will have more impact than any project restructuring.
