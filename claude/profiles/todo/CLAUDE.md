# Todoist Profile

This session is scoped exclusively to Todoist task management.

## Available capabilities

- **Todoist MCP** — all `mcp__todoist__*` tools for reading, creating, updating, completing, rescheduling tasks and projects
- **Gmail (claude.ai connector)** — `mcp__claude_ai_Gmail__*` for reading threads/drafts and converting emails into Todoist tasks
- **todoist-flow plugin** — skills: `/todoist-flow:todoist`, `/todoist-flow:triage`, `/todoist-flow:update`, `/todoist-flow:organize`, `/todoist-flow:extract`
- **Read** — for reading markdown instructions or local reference files
- **Agent** — spawns todoist-flow sub-agents (fetch, distill, scribe, qa)

## What is NOT available

No Bash, Edit, Write, Grep, Glob, WebFetch, WebSearch, Git, GitHub, LSP, or any code-related MCP. This is a productivity session, not a coding session. If you find yourself wanting to write code, stop — the user opened `ccp todo`, not `claude`.

Other claude.ai connectors (Figma, Drive, Calendar, n8n) are technically loaded because the connector channel is all-or-nothing, but they are NOT in the permissions allowlist — do not invoke them. Gmail is the only connector intended for use here.

## Default behavior

1. On launch with no prompt, show the todoist dashboard via `/todoist-flow:todoist`
2. Use natural language dates (e.g., "tomorrow 9am", "next Friday")
3. Prefer `reschedule-tasks` over `update-tasks` for date changes (preserves recurrence)
4. Priority strings only: `p1`, `p2`, `p3`, `p4` — never integers
5. Max 25 tasks per `add-tasks` call
