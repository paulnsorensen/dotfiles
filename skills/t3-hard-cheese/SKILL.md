---
name: t3-hard-cheese
description: >-
  Run `/hard-cheese` with T3 delegated subagents. Use in a T3 thread to grade
  the user's explanation with a fresh judge. Outside T3, use `/hard-cheese`.
---

# t3-hard-cheese

Run `/hard-cheese` in a T3 thread. Children run through T3 `delegate_task`.

1. Read `~/.claude/skills/hard-cheese/SKILL.md` in full and follow it.
2. If that file is missing, stop with an error that names the path. Launch no child.
3. Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.
4. Run the parent check in the dispatch protocol first.
5. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.

Get each target from `t3-run role <role>` (`bin/t3-run role`). Never write a model id.

## Role table

| Hard-cheese dispatch | Role |
| --- | --- |
| Grade the explanation (fresh judge) | `reviewer` |

The `reviewer` role uses shared isolation.

## Nested phases

When Hard-cheese chains to a phase that dispatches, use the matching `t3-*` wrapper.
