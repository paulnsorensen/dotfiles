---
name: extract
description: "Find Todoist tasks that are really reference material (not actionable) and export them as structured markdown for Dropbox or other storage. Use when the user says 'extract references', 'find non-actionable tasks', 'clean up reference tasks', 'move to dropbox', 'todoist to dropbox', 'separate reference from tasks', or when /todoist dashboard flags many noun-only or URL tasks."
---

# Todoist Extract

Identify tasks that aren't really tasks — they're reference material, ideas, bookmarks, or notes masquerading as action items. Extract them into structured markdown the user can save to Dropbox (or wherever they store reference material).

## Why This Matters

Todoist is an action system. When it fills up with reference material ("look into X", bookmarked URLs, "idea: Y"), it dilutes the signal. Actionable tasks compete with passive notes for attention. Extracting reference material makes the task list honest — everything left is something to do.

## Flow

### Step 1: Scan for Candidates

Spawn todoist-fetch to retrieve all tasks in a fresh context window:

```
Agent(subagent_type: "todoist-fetch", prompt: "Fetch all tasks broadly (all projects, or user-specified scope). Include task IDs, titles, projects, priorities, due dates, creation dates, descriptions, labels, and any URLs in descriptions. Flag: tasks with no verb in title, URL-only tasks, tasks 90+ days old with no due date.")
```

Score each returned task for "reference-ness":

**Detection patterns** (a task matching 2+ patterns is a strong candidate):

| Pattern | Signal | Example |
|---------|--------|---------|
| No verb | Not actionable | `Kubernetes best practices` |
| URL-only | Bookmark | `https://example.com/article` |
| "look into", "check out", "explore" | Passive curiosity | `Look into Rust async patterns` |
| "remember", "note:", "idea:" | Note, not task | `Remember: API rate limit is 100/min` |
| "maybe", "someday", "consider" | Speculative | `Maybe try Obsidian for notes` |
| 90+ days old, no due date | Dormant | Any old undated task |
| Project is "Ideas" or "Someday" | Already filed as non-action | — |

### Step 2: Present Candidates

Group by type and present:

```
## Reference Material Candidates

### Bookmarks (X tasks)
1. "https://example.com/rust-patterns" — in project "Learning", created 4 months ago
2. "Check out htmx docs" — in project "Ideas", created 2 months ago

### Notes & Ideas (X tasks)
3. "Idea: build a CLI for todoist cleanup" — in Inbox, created 3 months ago
4. "Remember: work VPN requires cert renewal every 90 days" — in "Work"

### Dormant (X tasks, 90+ days, no date)
5. "Research home solar panel options" — in "Home", created 6 months ago

Extract all of these? Or review one at a time? (A/R)
```

Use `AskUserQuestion`. If (R), walk through each and let the user keep or extract.

### Step 3: Format as Markdown

Group extracted tasks into a structured reference document:

```markdown
# Extracted from Todoist — [date]

## Bookmarks
- [Rust async patterns](https://example.com/rust-patterns)
  - Source project: Learning
  - Originally created: 2025-10-15

- htmx docs — check out the getting started guide
  - Source project: Ideas
  - Originally created: 2026-02-01

## Ideas
- Build a CLI for todoist cleanup
  - Context: [task description if any]
  - Originally created: 2026-01-15

## Notes
- Work VPN requires cert renewal every 90 days
  - Source project: Work

## To Research (someday)
- Home solar panel options
  - Source project: Home
  - Originally created: 2025-10-01
```

### Step 4: Save the Document

Write the markdown file to a temp location:

```
$TMPDIR/todoist-extract-[date].md
```

Tell the user where it is:

```
Saved to: $TMPDIR/todoist-extract-2026-04-09.md

Move this file to your preferred reference storage (Dropbox, Obsidian, etc.).
When you confirm it's saved, I'll remove these tasks from Todoist.
```

### Step 5: Clean Up (with confirmation)

**Only after the user confirms they've saved the file**, remove extracted tasks from Todoist.

Use `AskUserQuestion`: "Have you saved the reference file? Ready to remove these X tasks from Todoist? (y/n)"

If yes, run through the write pipeline (distill → scribe → QA):

**1. Validate reasoning** — spawn todoist-distill:

```
Agent(subagent_type: "todoist-distill", prompt: "Validate deletion of these extracted reference tasks. User confirmed file is saved. Tasks: [task IDs and titles]")
```

**2. Format commands** — spawn todoist-scribe:

```
Agent(subagent_type: "todoist-scribe", prompt: "Format delete-object commands for these extracted tasks: [distill's validated plan]")
```

**3. Verify and execute** — spawn todoist-qa:

```
Agent(subagent_type: "todoist-qa", prompt: "Verify and execute: [scribe's formatted commands]. Original intent: delete extracted reference tasks after user confirmed save.")
```

### Step 6: Summary

```
## Extraction Complete

| Category | Count |
|----------|-------|
| Bookmarks | X |
| Ideas | X |
| Notes | X |
| To Research | X |
| **Total extracted** | **X** |

Saved to: [path]
Removed from Todoist: X tasks
```

## Research Integration

If the user wants to evaluate whether a candidate is truly reference material vs. actionable:

```
Skill(skill="cheese-flow:research", args="Is '[task title]' something actionable or reference material? Context: [description]. Help decide if this belongs in a task list or a reference doc.")
```

## Key Principles

- **Conservative extraction** — when in doubt, keep the task. It's better to leave an ambiguous item than to extract something the user actually needs to act on.
- **User confirms before deletion** — never remove tasks until the user confirms they've saved the reference file. Data loss from premature deletion is unrecoverable.
- **Grouping adds value** — random tasks extracted into a flat list aren't useful. Group by type (bookmarks, ideas, notes, research topics) so the reference doc has structure.
- **Don't over-process** — the markdown output should be clean and readable, not a database export. Include enough context to be useful, not every metadata field Todoist has.
