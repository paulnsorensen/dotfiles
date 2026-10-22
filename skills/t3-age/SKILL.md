---
name: t3-age
description: >-
  Run `/age` with T3 delegated subagents. Use in a T3 thread to review a diff,
  PR, branch, or path. Outside T3, use `/age`.
---

# t3-age

Run `/age` in a T3 thread. Children run through T3 `delegate_task`.

1. Read `~/.claude/skills/age/SKILL.md` in full and follow it.
2. If that file is missing, stop with an error that names the path. Launch no child.
3. Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.
4. Run the parent check in the dispatch protocol first.
5. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.

Get each target from `t3-run role <role>` (`bin/t3-run role`). Never write a model id.

## Fan-out override

Replace the age router's native fan-out and the `age-fanout.js` child workflow with T3 children:

| Age dispatch | Role |
| --- | --- |
| One child per router lens group | `reviewer` |
| One child over the whole diff | `second-reviewer` (exactly one) |
| Packet explorer | `explorer` |
| Verifier | `verifier` |
| Judge advice | `advisor` |

Set each `reviewer` effort from the router's dial. The router value wins over the role map.

The parent reconciles all findings into the standard `/age` report. Validate the `verifier` result as the result rules say.

## Nested phases

When Age chains to Cure, use `t3-cure`.
