---
name: t3-affinage
description: >-
  Run `/affinage` with T3 delegated subagents. Use in a T3 thread to triage
  review claims and CI evidence. Outside T3, use `/affinage`.
---

# t3-affinage

Run `/affinage` in a T3 thread. Children run through T3 `delegate_task`.

1. Read `~/.claude/skills/affinage/SKILL.md` in full and follow it.
2. If that file is missing, stop with an error that names the path. Launch no child.
3. Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.
4. Run the parent check in the dispatch protocol first.
5. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.

Get each target from `t3-run role <role>` (`bin/t3-run role`). Never write a model id.

## Role table

| Affinage dispatch | Role |
| --- | --- |
| Triage review claims and CI evidence | `reviewer` |
| Gate digest | `gate-runner` |
| Judge advice | `advisor` |

The `reviewer` role uses shared isolation.

## Nested phases

When Affinage chains to Cure, use `t3-cure`. Write roles return a branch and a full head SHA. The parent integrates through `t3-run gate sha`.
