---
name: t3-age
description: >-
  Run `/age` with T3 delegated subagents. Use in a T3 thread to review a diff,
  PR, branch, or path. Outside T3, use `/age`.
model: opus
effort: high
---

# t3-age

Run `/age` in a T3 thread. Children run through T3 `delegate_task`.

Source: `~/.claude/skills/age/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. For prose skills that name a preferred type in their `## Agent resolution` table, pass that type.

## Overrides

Replace the age router's native fan-out and the `age-fanout.js` child workflow with T3 children:

- Dispatch exactly one `second-reviewer` child over the whole diff.
- Dispatch one `reviewer` child per router lens group.

Set each `reviewer` effort from the router's dial. The router value wins over the role map.

The parent reconciles all findings into the standard `/age` report. When Age chains to Cure, use `t3-cure`.
