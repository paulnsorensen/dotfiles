# Todoist Profile

This session is Todoist-first, with just enough surrounding tooling to read/write
local notes and run `/briesearch` when a task's scope needs a fact check.

## Why this profile exists

Productivity flow and coding flow contaminate each other: a full dev session
invites "while I'm in here, let me fix this bug" and loses the task-hygiene
thread. This profile keeps the cut — no code MCPs, no LSP, no git/gh chores —
while still letting you work with files (tasks often reference local notes)
and do cross-source research before committing work to a task.

`mcp-scope.yaml` + `--strict-mcp-config` ensure only Todoist, Context7, Tavily,
and Serper load. The permissions allowlist covers those MCPs plus Gmail (for
email-to-task flows).

## Available capabilities

- **Todoist MCP** — all `mcp__todoist__*` tools for reading, creating, updating, completing, rescheduling tasks and projects
- **todoist-flow plugin** — skills: `/todoist-flow:todoist`, `/todoist-flow:triage`, `/todoist-flow:update`, `/todoist-flow:organize`, `/todoist-flow:extract`
- **Gmail (claude.ai connector)** — `mcp__claude_ai_Gmail__*` for reading threads/drafts and converting emails into Todoist tasks
- **File tools** — `Read`, `Write`, `Edit`, `Grep`, `Glob` for working with local task notes, logbook entries, and markdown references
- **Bash** — available for `gh`, shell utilities, and `/briesearch`'s gh CLI fetcher
- **/briesearch skill** — multi-source research via `mcp__context7__*`, `mcp__tavily__*`, `mcp__serper__*`; use when a task needs a fact check or library doc lookup before it can be scoped
- **Agent** — spawns todoist-flow sub-agents (fetch, distill, scribe, qa) and `/briesearch` fetchers

## What is NOT available

No LSP, NotebookEdit, WebFetch, WebSearch, or any code-review / code-graph
MCPs (tilth, code-review-graph). This is not a coding session. If you find
yourself wanting to modify source code, stop — the user opened `ccp todo`,
not `claude` or `ccp fe`.

Other claude.ai connectors (Figma, Drive, Calendar, n8n) are technically
loaded because the connector channel is all-or-nothing, but they are NOT in
the permissions allowlist — do not invoke them. Gmail is the only connector
intended for use here.

## Default behavior

1. On launch with no prompt, show the todoist dashboard via `/todoist-flow:todoist`
2. Use natural language dates (e.g., "tomorrow 9am", "next Friday")
3. Prefer `reschedule-tasks` over `update-tasks` for date changes (preserves recurrence)
4. Priority strings only: `p1`, `p2`, `p3`, `p4` — never integers
5. Max 25 tasks per `add-tasks` call
6. Use `/briesearch` only when the task requires external facts or library docs — not for general browsing
