---
name: triage
description: "Interactive triage of overdue and stale Todoist tasks. Presents tasks in batches, user decides fate of each: complete, reschedule, delete, someday, or skip. Use when the user says 'triage', 'process overdue tasks', 'clean up todoist', 'deal with overdue', 'task triage', 'inbox zero', or when /todoist dashboard shows high overdue count."
---

# Todoist Triage

Process overdue and stale tasks interactively. You present, the user decides — never assume a task's fate.

## Flow

### Step 1: Fetch Overdue Tasks

Spawn todoist-fetch to retrieve tasks in a fresh context window:

```
Agent(subagent_type: "todoist-fetch", prompt: "Fetch overdue tasks: find-tasks with filter 'overdue'. Sort by age (oldest first). Include task IDs, titles, projects, priorities, due dates, creation dates, descriptions, and any labels.")
```

If the user said "triage inbox" or "inbox zero":

```
Agent(subagent_type: "todoist-fetch", prompt: "Fetch inbox tasks: find-tasks with filter '#Inbox'. Sort by creation date (oldest first). Include task IDs, titles, priorities, due dates, creation dates, descriptions, and any labels.")
```

### Step 2: Calculate Staleness

For each task, calculate days overdue. Flag tasks that are **3+ weeks overdue** — these have been implicitly deprioritized and are strong candidates for deletion or Someday.

### Step 3: Present Batches

Show 5 tasks at a time. For each task, display:

```
### Task 1/N: [Task Title]
- Project: [project name]
- Priority: [p1-p4]
- Due: [original due date] (X days overdue)
- Description: [if any, truncated to 2 lines]
- Staleness: [STALE if 3+ weeks — "This task has been sitting for X weeks. Honest question: is this still relevant?"]

Actions: (C)omplete | (R)eschedule [when?] | (D)elete | (S)omeday | (K)eep as-is | (?)Research
```

Use `AskUserQuestion` to get the user's decision. Accept shorthand: `c`, `r tomorrow`, `r next monday`, `d`, `s`, `k`, `?`.

### Step 4: Handle "Research" Requests

If the user picks `?` on a task, invoke the research skill to get context:

```
Skill(skill="research", args="Context for this task: '[task title]'. [task description if any]. Help the user decide if this is still relevant and what the current state of this topic is.")
```

After research returns, re-present the task with the research context and ask again.

### Step 5: Execute Decisions

Batch decisions and run through the write pipeline (distill → scribe → QA):

**Operation mapping:**

- **Complete**: `complete-tasks`
- **Reschedule**: `reschedule-tasks` (NEVER update-tasks — preserves recurrence)
- **Delete**: `delete-object`
- **Someday**: Move to "Someday" project (create if needed) + strip due date via `update-tasks` with `dueString: "remove"`
- **Keep**: No action

**1. Validate reasoning** — spawn todoist-distill:

```
Agent(subagent_type: "todoist-distill", prompt: "Validate these triage decisions against user intent: [decisions with task data, user choices, and context]")
```

**2. Format commands** — spawn todoist-scribe with validated plan:

```
Agent(subagent_type: "todoist-scribe", prompt: "Format these validated triage operations as MCP commands: [distill's validated plan]")
```

**3. Verify and execute** — spawn todoist-qa:

```
Agent(subagent_type: "todoist-qa", prompt: "Verify and execute: [scribe's formatted commands]. Original intent: [distill's validated plan]")
```

### Step 6: Continue or Finish

After each batch of 5:

- Show running stats: `Completed: X | Rescheduled: X | Deleted: X | Someday: X | Kept: X`
- Ask: "Continue with next batch? (Y tasks remaining)" via `AskUserQuestion`

### Step 7: Summary

When done (all tasks processed or user stops):

```
## Triage Complete

| Action | Count |
|--------|-------|
| Completed | X |
| Rescheduled | X |
| Deleted | X |
| Moved to Someday | X |
| Kept as-is | X |

Overdue count: [before] → [after]
```

## Key Principles

- **Never assume** — always ask the user. Even obviously stale tasks might be important.
- **Flag staleness honestly** — a task overdue 3+ weeks deserves a direct "is this still real?" prompt. Don't soften it.
- **Batch writes** — collect decisions for 5 tasks, then send to todoist-scribe in one shot. Don't make API calls one at a time.
- **Respect "research"** — when the user needs context, get it. The point is informed decisions, not speed.
- **Track the Someday project** — on first Someday action, check if a "Someday" project exists. Create it if not. Remember the project ID for subsequent moves.
