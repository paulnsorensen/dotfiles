---
name: t3-mold
description: >-
  Run `/mold` with T3 delegated subagents. Use in a T3 thread when the user
  wants a spec or plan from Mold. Outside T3, use `/mold`.
---

# t3-mold

Run `/mold` in a T3 thread. Children run through T3 `delegate_task`.

1. Read `~/.claude/skills/mold/SKILL.md` in full and follow it.
2. If that file is missing, stop with an error that names the path. Launch no child.
3. Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.
4. Run the parent check in the dispatch protocol first.
5. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.

Get each target from `t3-run role <role>` (`bin/t3-run role`). Never write a model id.

## Role table

| Mold dispatch | Role |
| --- | --- |
| Explore the codebase | `explorer` |
| Research external constraints | `researcher` |
| Plan for approval | `planner` |
| Fork taste test | `taste-test` |
| Plan gate or judge advice | `advisor` |

All these roles use shared isolation. The parent writes the spec.

## Nested phases

When Mold chains to a phase that dispatches, use the matching `t3-*` wrapper.
