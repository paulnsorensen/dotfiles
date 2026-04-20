---
name: update
description: "Review active (non-overdue) Todoist tasks for completion, irrelevance, or rewording. Incremental hygiene, not bankruptcy. Use when the user says 'update tasks', 'review my tasks', 'task hygiene', 'check what I've done', 'mark tasks done', 'clean up active tasks', or when they want a project-by-project walkthrough of current work."
---

# Todoist Update

Walk through active tasks with the user to find completed work, irrelevant items, and tasks that need better formatting. This is routine hygiene — the counterpart to `/triage` (which handles overdue debt).

## Flow

### Step 1: Choose Scope

Ask the user what to review via `AskUserQuestion`:

```
What would you like to review?
(A) All projects — full sweep
(P) Pick a project — I'll list them
(F) Flagged tasks only — P1/P2 tasks (are priorities still accurate?)
```

If they pick (P), fetch projects via `mcp__todoist__find-projects` and let them choose.

### Step 2: Fetch Tasks

Spawn todoist-fetch to retrieve tasks in a fresh context window:

```
Agent(subagent_type: "todoist-fetch", prompt: "Fetch active (non-overdue) tasks for [scope]. Exclude overdue tasks. Include task IDs, titles, projects, priorities, due dates, creation dates, descriptions, and labels. Flag: tasks with no due date, P1/P2 tasks, tasks created 90+ days ago.")
```

Focus on:

- Tasks with no due date (dormant — still relevant?)
- Tasks due in the future (still planned correctly?)
- High-priority tasks (P1/P2 — priority still accurate?)

### Step 3: Present for Review

Show 5 tasks at a time:

```
### Task 1/N: [Task Title]
- Project: [project]
- Priority: [p1-p4]
- Due: [date or "no date"]
- Created: [date] (X days ago)
- Description: [if any]

Actions: (D)one | (X)Delete — irrelevant | (R)eword | (P)riority change [p1-p4] | (S)chedule [when?] | (K)eep | (?)Research
```

Use `AskUserQuestion` for decisions. Accept shorthand: `d`, `x`, `r`, `p2`, `s next week`, `k`, `?`.

### Step 4: Handle Rewording

If the user picks (R), ask what the new title should be — or offer a suggestion based on best practices:

```
Current: "dentist"
Suggested: "Call dentist to schedule cleaning"
Use suggestion, or type your own:
```

The todoist-scribe agent will validate the reworded title against formatting rules.

### Step 5: Handle Research

If `?`, invoke the research skill for context:

```
Skill(skill: "research", args: "Context for: '[task title]'. [description]. Help the user decide if this task is still relevant.")
```

Re-present the task after research returns.

### Step 6: Execute

Batch decisions per group of 5 and run through the write pipeline (distill → scribe → QA):

**1. Validate reasoning** — spawn todoist-distill:

```
Agent(subagent_type: "todoist-distill", prompt: "Validate these update decisions against user intent: [decisions with task data and user choices]")
```

**2. Format commands** — spawn todoist-scribe with validated plan:

```
Agent(subagent_type: "todoist-scribe", prompt: "Format these validated update operations as MCP commands: [distill's validated plan]")
```

**3. Verify and execute** — spawn todoist-qa:

```
Agent(subagent_type: "todoist-qa", prompt: "Verify and execute: [scribe's formatted commands]. Original intent: [distill's validated plan]")
```

### Step 7: Running Stats

After each batch show progress:

```
Progress: [X/Y tasks reviewed]
Done: X | Deleted: X | Reworded: X | Reprioritized: X | Scheduled: X | Kept: X
```

Ask to continue or stop.

### Step 8: Summary

```
## Update Complete — [Project Name or "All Projects"]

| Action | Count |
|--------|-------|
| Marked done | X |
| Deleted (irrelevant) | X |
| Reworded | X |
| Reprioritized | X |
| Scheduled | X |
| Kept as-is | X |

Tasks reviewed: X of Y
```

## Priority Audit Mode

When scope is (F) flagged tasks, focus the review on priority accuracy:

- P1 tasks: "Is this genuinely urgent and important today? Or has the urgency passed?"
- P2 tasks: "Is this still this week's focused work?"
- Show current P1 count — if >3, flag inflation: "You have X tasks at P1. Ideally 1-3. Which are truly urgent today?"

## Key Principles

- **Incremental, not bankruptcy** — the user explicitly doesn't want to archive everything. Respect that by reviewing task-by-task.
- **Completed work matters** — the user may have done tasks without marking them complete. This is the most satisfying part of the review.
- **Formatting is secondary** — if a task is correctly titled and prioritized, don't suggest changes just for polish. Only reword tasks that are genuinely unclear.
- **No guilt** — deletion is healthy. Don't make the user feel bad about removing irrelevant tasks. Frame it as "this served its purpose" or "priorities shifted."
