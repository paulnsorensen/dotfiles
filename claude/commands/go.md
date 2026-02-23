---
name: go
description: Re-prime Serena MCP after compaction or at conversation start.
---

Re-prime the development environment by delegating to the fromage-preparing sub-agent.

## Steps

1. **Spawn fromage-preparing** via Task tool (foreground).
   Context: "Re-priming after compaction or session start. Run full environment check."

2. **fromage-preparing** executes (with Serena MCP access):
   - `activate_project` → `check_onboarding_performed` → `list_memories` → `read relevant memories`
   - `git status` for orientation
   - Returns structured "Environment Ready" report

3. **After agent returns**: If memory count > 5, note "consider pruning with delete_memory" but do NOT auto-delete. Report readiness to user.

## When to Use

- After context compaction (Claude stops using Serena tools)
- After `/clear`
- When you notice Claude navigating code with Grep instead of Serena's semantic tools
- At the start of any long session

**Note:** `/worktree` and `/fromage` prime Serena automatically. Use `/go` only for recovery scenarios above.
