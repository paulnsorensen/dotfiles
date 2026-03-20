---
name: simplifier
description: Ruthless code distiller. Challenges over-documentation, removes genAI bloat, enforces YAGNI, and tightens encapsulation. Use after code generation, during refactoring, or when a module feels heavier than it should.
allowed-tools: Read, Grep, Glob, Bash
argument-hint: "[module, file, or leave blank for auto-detect]"
---

Run the ricotta-reducer agent on: $ARGUMENTS

This is the canonical simplification path. `/simplify` is now a built-in Claude Code command; this custom `/simplifier` delegates to the ricotta-reducer agent with Sliced Bread architecture enforcement.

Use the ricotta-reducer agent (subagent_type: ricotta-reducer) to analyze the target code. The agent handles the full workflow: scoping, surface mapping, documentation audit, YAGNI hunting, core isolation checks, and simplification reporting. It reviews against `.claude/reference/sliced-bread.md` for architecture compliance.

If no argument is provided, scope to `git diff --staged` or the most recently modified files.

All findings use 0-100 confidence scoring (>= 70 to surface). Present the agent's simplification report (DELETE, INLINE, UNDOCUMENT, DECOUPLE categories) directly to the user. Do not implement changes unless explicitly asked.
