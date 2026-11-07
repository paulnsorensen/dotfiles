---
name: t3-affinage
description: >-
  Run `/affinage` with T3 delegated subagents. Use in a T3 thread to triage
  review claims and CI evidence. Outside T3, use `/affinage`.
model: opus
effort: high
---

# t3-affinage

Run `/affinage` in a T3 thread. Children run through T3 `delegate_task`.

Source: `~/.claude/skills/affinage/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

## Overrides

When Affinage chains to Cure, use `t3-cure`.
