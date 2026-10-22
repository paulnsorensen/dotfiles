---
name: t3-briesearch
description: >-
  Run `/briesearch` with T3 delegated subagents. Use in a T3 thread for cited
  research on heavy sources. Outside T3, use `/briesearch`.
---

# t3-briesearch

Run `/briesearch` in a T3 thread. Children run through T3 `delegate_task`.

1. Read `~/.claude/skills/briesearch/SKILL.md` in full and follow it.
2. If that file is missing, stop with an error that names the path. Launch no child.
3. Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.
4. Run the parent check in the dispatch protocol first.
5. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.

Get each target from `t3-run role <role>` (`bin/t3-run role`). Never write a model id.

## Role table

| Briesearch dispatch | Role |
| --- | --- |
| Fetch and synthesize one heavy source | `researcher` |
| Judge advice | `advisor` |

The `researcher` role uses shared isolation. The parent writes the cited report.

## Nested phases

When Briesearch chains to a phase that dispatches, use the matching `t3-*` wrapper.
