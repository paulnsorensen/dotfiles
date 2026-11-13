---
name: t3-briesearch
description: >-
  Run `/briesearch` with T3 delegated subagents. Use in a T3 thread for cited
  research on heavy sources. Outside T3, use `/briesearch`.
model: opus
effort: high
---

# t3-briesearch

Run `/briesearch` in a T3 thread. Children run through T3 `delegate_task`.

Source: `~/.claude/skills/briesearch/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

## Overrides

The parent writes the cited report. When Briesearch chains to a phase that dispatches, use the matching `t3-*` wrapper.
