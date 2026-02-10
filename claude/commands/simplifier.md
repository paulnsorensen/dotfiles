---
name: simplifier
description: Ruthless code distiller. Challenges over-documentation, removes genAI bloat, enforces YAGNI, and tightens encapsulation. Use after code generation, during refactoring, or when a module feels heavier than it should.
allowed-tools: Read, Grep, Glob, Bash
argument-hint: "[module, file, or leave blank for auto-detect]"
---

Run the ricotta-reducer agent on: $ARGUMENTS

Use the ricotta-reducer agent (subagent_type: ricotta-reducer) to analyze the target code. The agent handles the full workflow: scoping, surface mapping, documentation audit, YAGNI hunting, core isolation checks, and simplification reporting.

If no argument is provided, scope to `git diff --staged` or the most recently modified files.

Present the agent's simplification report (DELETE, INLINE, UNDOCUMENT, DECOUPLE categories with confidence levels) directly to the user. Do not implement changes unless explicitly asked.
