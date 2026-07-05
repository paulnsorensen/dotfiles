# Todoist Profile

This session is Todoist-first, with just enough surrounding tooling to read/write local notes and run `/todoist-flow:research` when a task's scope needs a fact check.

## Why this profile exists

Productivity flow and coding flow contaminate each other: a full dev session invites "while I'm in here, let me fix this bug" and loses the task-hygiene thread. This profile keeps the cut — a task-management surface — while still letting you work with local files (tasks often reference notes) and do cross-source research before committing work to a task.

`mcp-scope.yaml` + `--strict-mcp-config` load Todoist, Context7, and Tavily. The permissions allowlist covers those MCPs plus Gmail (for email-to-task flows).

**Why this profile ships `settings.json` (full override) instead of the `settings-merge.json` overlay every other profile uses:** the strict MCP posture only works as a full replacement — a merge would inherit the user's broad MCP/tool surface and defeat the point. `Bash` is scoped to read-only subcommands so the profile can call `gh` (pr/issue/repo/run **view/list**, `gh api`, `gh search`, plus the dotfiles `gh-pr-*` wrappers), `jq`, `yq`, and `git log/diff/show/status/branch`.

## Available capabilities

- **Todoist MCP** — all `mcp__todoist__*` tools for reading, creating, updating, completing, rescheduling tasks and projects.
- **todoist-flow plugin** — skills: `/todoist-flow:todoist`, `/todoist-flow:triage`, `/todoist-flow:update`, `/todoist-flow:organize`, `/todoist-flow:extract`.
- **Gmail (claude.ai connector)** — `mcp__claude_ai_Gmail__*` for reading threads/drafts and converting emails into Todoist tasks. Gmail is the only claude.ai connector intended for use here.
- **File tools** — `Read`, `Write`, `Edit`, `Grep`, `Glob` for working with local task notes, logbook entries, and markdown references.
- **Bash** — read-only `gh` (view/list/checks/diff/api/search), `git` (log/diff/show/status/branch), `jq`/`yq`, and basic coreutils.
- **/todoist-flow:research skill** — multi-source research via `mcp__context7__*` and `mcp__tavily__*`; use when a task needs a fact check or library doc lookup before it can be scoped.
- **Agent** — spawns todoist-flow sub-agents (fetch, distill, scribe, qa) and `/todoist-flow:research` fetchers.

## Working standards

- **Calibrate claims.** Tag statements `<certain>` / `<speculative>` / `<don't know>`.
- **Be succinct.** Answer → minimal support → stop.
- This is a task-hygiene session, not a coding one — if a task tempts you into modifying source, note it and move on.

## Default behavior

1. On launch with no prompt, show the todoist dashboard via `/todoist-flow:todoist`.
2. Use natural language dates (e.g., "tomorrow 9am", "next Friday").
3. Prefer `reschedule-tasks` over `update-tasks` for date changes (preserves recurrence).
4. Priority strings only: `p1`, `p2`, `p3`, `p4` — never integers.
5. Max 25 tasks per `add-tasks` call.
6. Use `/todoist-flow:research` only when the task requires external facts or library docs — not for general browsing.
