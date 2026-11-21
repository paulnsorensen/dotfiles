# Claude Desktop session starts

The Code tab of the Claude desktop app starts sessions through its own `ccd_session` MCP server. Terminal launchers (`ccw`, `claude --worktree`) do not apply there. The `worktree-session` skill routes Desktop through `skills/worktree-session/references/claude-desktop.md`. Researched on 2026-11-21.

## Decision

- Route order in `worktree-session`: T3 tools first, then Desktop `ccd_session` tools, then native and CLI launchers.
- Desktop sessions never fall back to a terminal launcher. The Desktop sidebar and cross-session tools do not see terminal, T3, or cloud sessions, so a substitute session becomes invisible to Desktop.
- The skill reads the live `start_session` schema before each call. Parameter names come from user bug reports, not official documentation.

## Gotchas

- **`spawn_task` is gone.** Since about 2026-10-15, `start_session` replaces `spawn_task` when side sessions are on ([#102449](https://github.com/anthropics/claude-code/issues/102449), [#104205](https://github.com/anthropics/claude-code/issues/104205)).
- **Initiation values.** `user_asked` starts a session when the user asked for it. `own_initiative` and `offer` post a proposal card that the user must click. When the user asks for isolation and the schema has no worktree field, the skill posts an `offer` card: `user_asked` starts at once and can share the project folder, while a card lets the user turn on **Worktree** under **Options**. Review of PR #1637 found this conflict.
- **Proposal cards carry no place.** A card cannot name a folder, host, environment, preset, or repository. It opens in the proposing session's project ([#104205](https://github.com/anthropics/claude-code/issues/104205)).
- **Worktree is off by default.** With it off, a session works in the project folder itself. A started task uses the current session's environment, so a task from a non-worktree session can share the project folder ([desktop docs](https://code.claude.com/docs/en/desktop), "Run a session in its own worktree" and "Start a task that Claude suggests").
- **Unattended sessions cannot start sessions.** Scheduled and remotely dispatched sessions get a refusal for every initiation value. Remote Control also refuses `user_asked`. The refusal follows the session origin, not user presence ([#102449](https://github.com/anthropics/claude-code/issues/102449), [#108687](https://github.com/anthropics/claude-code/issues/108687)).
- **No model or effort on cards.** `spawn_task` had no model or effort field. The user sets these under the card's **Options** ([#107160](https://github.com/anthropics/claude-code/issues/107160)).
- **Worktree location.** Desktop stores worktrees under `<project-root>/.claude/worktrees/` unless **Settings > Code** sets another location.
- **Desktop is macOS and Windows only.** It does not run on Linux, so these routes do not apply to the Linux T3 host.

## Related

- [[harnesses/claude]]
- [[architecture/t3-code-launch]]
