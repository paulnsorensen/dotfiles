---
name: t3-hard-cheese
description: >-
  Run `/hard-cheese` with T3 delegated subagents. Use in a T3 thread to grade
  the user's explanation with a fresh judge. Outside T3, use `/hard-cheese`.
model: opus
effort: high
---

# t3-hard-cheese

Run `/hard-cheese` in a T3 thread. Children run through T3 `delegate_task`.

Source: `~/.claude/skills/hard-cheese/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. For prose skills that name a preferred type in their `## Agent resolution` table, pass that type.
