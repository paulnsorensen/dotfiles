---
name: go
description: Re-prime MCP tools (Serena, Context7) after compaction or at conversation start.
---

Re-prime the development environment. Run this after context compaction or at the start of a long session.

## Steps

1. **Activate Serena** for the current project (`activate_project`). If unsure which project, check the working directory.
2. **Check Serena onboarding** (`check_onboarding_performed`). Run onboarding if not yet done.
3. **Read Serena memories** (`list_memories`, then `read_memory` for relevant ones).
4. **Confirm ready** — Report which project is active and what memories were loaded.

## When to Use

- After context compaction (Claude stops using Serena tools)
- At the start of a long coding session
- When you notice Claude navigating code with Grep instead of Serena's semantic tools
- After `/clear`
