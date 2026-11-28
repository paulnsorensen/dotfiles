---
name: t3-mold
description: >-
  Run `/mold` with T3 delegated subagents. Use in a T3 thread when the user
  wants a spec or plan from Mold. Outside T3, use `/mold`.
model: opus
effort: high
---

# t3-mold

Run `/mold` in a T3 thread. Children run through T3 `delegate_task`.

Source: `~/.claude/skills/mold/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

## Overrides

The taste test uses role `taste-test`, not `reviewer`.

The parent writes the spec. When Mold chains to a phase that dispatches, use the matching `t3-*` wrapper.
