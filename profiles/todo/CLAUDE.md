# Todoist Profile

This session is Todoist-first, with just enough surrounding tooling to read/write
local notes and run `/todoist-flow:research` when a task's scope needs a fact check.

## Why this profile exists

Productivity flow and coding flow contaminate each other: a full dev session
invites "while I'm in here, let me fix this bug" and loses the task-hygiene
thread. This profile keeps the cut — no code MCPs, no LSP, no git/gh chores —
while still letting you work with files (tasks often reference local notes)
and do cross-source research before committing work to a task.

`mcp-scope.yaml` + `--strict-mcp-config` ensure only Todoist, Context7, and
Tavily load. The permissions allowlist covers those MCPs plus Gmail (for
email-to-task flows).

**Why this profile ships `settings.json` (full override) instead of the
`settings-merge.json` overlay every other profile uses:** the strict MCP
posture only works as a full replacement — a merge would inherit the user's
broad MCP/tool surface and defeat the point. `Bash` is scoped to read-only
subcommands so the profile can call `gh` (pr/issue/repo/run **view/list**,
`gh api`, `gh search`, plus the dotfiles `gh-pr-*` wrappers), `jq`, `yq`,
and `git log/diff/show/status/branch` — but not mutating gh operations
(`gh pr merge`, `gh repo delete`, `gh pr close`, …) or arbitrary shell.

## Available capabilities

- **Todoist MCP** — all `mcp__todoist__*` tools for reading, creating, updating, completing, rescheduling tasks and projects
- **todoist-flow plugin** — skills: `/todoist-flow:todoist`, `/todoist-flow:triage`, `/todoist-flow:update`, `/todoist-flow:organize`, `/todoist-flow:extract`
- **Gmail (claude.ai connector)** — `mcp__claude_ai_Gmail__*` for reading threads/drafts and converting emails into Todoist tasks
- **File tools** — `Read`, `Write`, `Edit`, `Grep`, `Glob` for working with local task notes, logbook entries, and markdown references
- **Bash** — read-only `gh` (view/list/checks/diff/api/search), `git` (log/diff/show/status/branch), `jq`/`yq`, and basic coreutils. Mutating `gh` (`pr merge`, `pr close`, `repo delete`, …) is intentionally **not** in the allowlist.
- **/todoist-flow:research skill** — multi-source research via `mcp__context7__*` and `mcp__tavily__*`; use when a task needs a fact check or library doc lookup before it can be scoped. Lives inside the todoist-flow plugin so the cheese-flow plugin (and its tilth/milknado MCPs) does not need to be enabled in this profile.
- **Agent** — spawns todoist-flow sub-agents (fetch, distill, scribe, qa) and `/todoist-flow:research` fetchers

## What is NOT available

No LSP, NotebookEdit, WebFetch, WebSearch, or any code-review / code-graph
MCPs (tilth, code-review-graph). This is not a coding session. If you find
yourself wanting to modify source code, stop — the user opened the `todo`
profile (`dots profile launch claude todo`), not a general `claude` or `fe` session.

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
6. Use `/todoist-flow:research` only when the task requires external facts or library docs — not for general browsing
