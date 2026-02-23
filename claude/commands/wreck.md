---
name: wreck
description: Adversarial test writer. Spawns roquefort-wrecker to write and run tests that assume code is guilty until proven innocent. Use outside /fromage for on-demand test writing.
allowed-tools: Read, Write, Grep, Glob, Bash
argument-hint: "[file, module, or leave blank for recently changed files]"
---

Run the roquefort-wrecker agent on: $ARGUMENTS

Use the roquefort-wrecker agent (subagent_type: roquefort-wrecker) to write and execute adversarial tests against the target code. The agent handles the full workflow: code analysis, chaos testing, edge case assault, integration failure scenarios, and happy path validation.

If no argument is provided, scope to files from `git diff --name-only` (unstaged changes) or `git diff --staged --name-only` (staged changes).

Present the agent's test execution report directly to the user — pass/fail counts, critical failures found, edge cases covered, and robustness assessment.

This is different from `/test` (which only RUNS existing tests) and from `/fromage` Press phase (which is pipeline-only).
