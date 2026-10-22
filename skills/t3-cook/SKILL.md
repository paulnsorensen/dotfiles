---
name: t3-cook
description: >-
  Run `/cook` with T3 delegated subagents. Use in a T3 thread to implement an
  approved spec or focused task. Outside T3, use `/cook`.
---

# t3-cook

Run `/cook` in a T3 thread. Children run through T3 `delegate_task`.

1. Read `~/.claude/skills/cook/SKILL.md` in full and follow it.
2. If that file is missing, stop with an error that names the path. Launch no child.
3. Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.
4. Run the parent check in the dispatch protocol first.
5. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.

Get each target from `t3-run role <role>` (`bin/t3-run role`). Never write a model id.

## Role table

| Cook dispatch | Role |
| --- | --- |
| Decompose the spec | `planner` |
| Implementation | `coder` |
| Press loop | `press` |
| Taste-test | `taste-test` |
| Gate digest | `gate-runner` |
| Plan gate, done gate, or judge advice | `advisor` |

## Write roles

`coder`, `press`, and `continuation` use worktree isolation, as the role map sets. Commit before you delegate. Each returns a branch and a full head SHA. The parent integrates through `t3-run gate sha <head_sha>`, never by branch name.

## Nested phases

When Cook chains to Press or Age, use `t3-cook` for Press and `t3-age` for Age. When Age chains to Cure, use `t3-cure`.
