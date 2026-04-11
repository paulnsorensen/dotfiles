# Todoist Best Practices Reference

Condensed from research report. Used by todoist-scribe and todoist-flow skills.

## Task Naming

Pattern: `[Action verb] [object] [qualifier]`

Good: `Write Q3 retrospective doc`, `Review pull request #142`, `Call dentist to reschedule`
Bad: `Dentist`, `PR`, `Retro stuff`, `[WAITING] Call vendor`, `Reply to Sarah by Friday`

Length: 5-10 words. Longer = decompose or use description field.

Qualifiers: who (`for @Alex`), where (`at home`), constraint (`before shipping v2`).

## Priorities

| Level | Meaning | Discipline |
|-------|---------|------------|
| p1 | Urgent + Important. Do today. | Max 1-3/day. Rare. |
| p2 | Important, not urgent. This week. | Your workhorse. |
| p3 | Useful but deferrable. | Nice-to-have. |
| p4 | Someday/maybe. Default. | Bulk of backlog. |

P4 as default is intentional. Promotion is deliberate.

## Due Dates vs Deadlines

| Field | Meaning | Format |
|-------|---------|--------|
| dueString | When you intend to work on it | Natural language |
| deadlineDate | Immovable external constraint | ISO 8601 (YYYY-MM-DD) |

Don't over-assign due dates. "Someday this week" = P2 without a date, not a fake due date.

Use `reschedule-tasks` (not `update-tasks`) to change dates — preserves recurrence.

## Project Structure

- Max 15 active projects
- Max 2 levels deep (3 is Todoist limit, rarely needed)
- PARA: Projects (active, has outcome), Areas (ongoing, no end date)
- GTD: Contexts go in labels, not projects

## Labels vs Sections vs Filters

| Tool | Use for | Anti-pattern |
|------|---------|--------------|
| Labels | Cross-cutting attributes spanning projects | Using as containers (@client-X) |
| Sections | Grouping within one project | Empty sections |
| Filters | Cockpit views aggregating everything | Not building any |

High-value labels: `@waiting`, `@deep-work`, `@quick-win`, `@low-energy`

Cockpit filters:

- Today: `(today | overdue) & !#Someday`
- Deep Work: `#Work & @deep-work & !today`
- Quick Wins: `@quick-win & p:2`
- Waiting On: `@waiting`
- Weekly Review: `7 days & !@waiting`

## Descriptions

Include: links, acceptance criteria, context for cold return.
Avoid: boilerplate, checklist steps (those become sub-tasks or a project).

## Staleness Signals

- Overdue 3+ weeks = implicitly deprioritized (honest action: delete or Someday)
- No verb in title = probably reference material, not a task
- URL-only tasks = reference material
- "look into", "remember", "idea:" = reference, not action
- 90+ days old with no due date = dormant
