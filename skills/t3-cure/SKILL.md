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

1. Read `~/.claude/skills/cure/SKILL.md` in full and follow it.
2. If that file is missing, stop with an error that names the path. Launch no child.
3. Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.
4. Run the parent check in the dispatch protocol first.
5. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.

Get each target from `t3-run role <role>` (`bin/t3-run role`). Never write a model id.

## Role table

| Cure dispatch | Role |
| --- | --- |
| Apply selected findings | `cure` |
| Resume a stopped fix | `continuation` |
| Gate digest | `gate-runner` |
| Judge or done-gate advice | `advisor` |

## Write roles

`cure` and `continuation` use worktree isolation, as the role map sets. Commit before you delegate. Each returns a branch and a full head SHA. The parent integrates through `t3-run gate sha <head_sha>`, never by branch name.

## Nested phases

When Cure chains to a phase that dispatches, use the matching `t3-*` wrapper.
