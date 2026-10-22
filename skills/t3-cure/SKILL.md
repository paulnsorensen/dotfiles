---
name: t3-cure
description: >-
  Run `/cure` with T3 delegated subagents. Use in a T3 thread to apply
  selected review findings. Outside T3, use `/cure`.
model: opus
effort: high
---

# t3-cure

Run `/cure` in a T3 thread. Children run through T3 `delegate_task`.

Source: `~/.claude/skills/cure/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. For prose skills that name a preferred type in their `## Agent resolution` table, pass that type.

## Overrides

Commit before you delegate a write child. A write child returns a branch and a full head SHA. When Cure chains to a phase that dispatches, use the matching `t3-*` wrapper.
