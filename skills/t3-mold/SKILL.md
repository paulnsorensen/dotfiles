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

Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. For prose skills that name a preferred type in their `## Agent resolution` table, pass that type.

## Overrides

The parent writes the spec. When Mold chains to a phase that dispatches, use the matching `t3-*` wrapper.
