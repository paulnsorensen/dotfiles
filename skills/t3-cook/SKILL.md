---
name: t3-cook
description: >-
  Run `/cook` with T3 delegated subagents. Use in a T3 thread to implement an
  approved spec or focused task. Outside T3, use `/cook`.
model: opus
effort: high
---

# t3-cook

Run `/cook` in a T3 thread. Children run through T3 `delegate_task`.

Source: `~/.claude/skills/cook/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. For prose skills that name a preferred type in their `## Agent resolution` table, pass that type.

## Overrides

- **Press.** Do not route Press through `t3-cook`. A Press child reads `~/.claude/skills/press/SKILL.md` and runs with role `press`. It applies the T3 override block.
- **Age.** When Cook chains to Age, use `t3-age`. When Age chains to Cure, use `t3-cure`.
- **Write roles.** Commit before you delegate. A write child returns a branch and a full head SHA. Follow the result rules.
