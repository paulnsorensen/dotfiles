---
name: todoist
description: "Todoist dashboard and router. Shows inbox count, overdue count, project health, and routes to the right sub-skill. Use when the user says 'todoist', 'check my tasks', 'task overview', 'what's on my plate', 'show me my todos', or any general Todoist inquiry that doesn't clearly map to triage/organize/update/extract."
---

# Todoist Dashboard

Entry point for the todoist-flow suite. Show the user where things stand, then route them to the right tool.

## Flow

### Step 1: Fetch State

Spawn todoist-fetch to gather dashboard data in a fresh context window:

```
Agent(subagent_type: "todoist-fetch", prompt: "Fetch dashboard data: 1) get-overview for inbox count and project summary, 2) find-tasks with filter 'overdue' for overdue count — flag any 3+ weeks stale, 3) get-productivity-stats for completion trends. Return structured overview with counts.")
```

### Step 2: Present Dashboard

Format as a concise status board:

```
## Todoist Status

| Metric | Count |
|--------|-------|
| Inbox | X tasks |
| Overdue | X tasks (Y are 3+ weeks stale) |
| Due today | X tasks |
| Active projects | X |

### Health Signals
- [good/warn/critical] Overdue debt: X tasks
- [good/warn/critical] Inbox backlog: X tasks
- [good/warn/critical] P1 inflation: X tasks at P1
```

### Step 3: Route

Based on the state, suggest the most impactful next action:

| Signal | Recommendation |
|--------|---------------|
| Overdue > 10 | "Run `/triage` to process overdue tasks" |
| Inbox > 20 | "Run `/triage` to clear inbox backlog" |
| P1 count > 5 | "Run `/update` to review priority inflation" |
| Projects > 15 or empty projects exist | "Run `/organize` to restructure projects" |
| Many noun-only or URL tasks | "Run `/extract` to pull out reference material" |
| Everything looks healthy | "Looking good. Run `/update` for routine hygiene." |

Present the suggestion but let the user decide. Don't auto-invoke sub-skills.

## Research Integration

If the user asks for deeper context on their productivity patterns, invoke the research skill:

```
Skill(skill="research", args="[specific topic the user asked about]")
```

This is opt-in — only when the user explicitly asks for research.
