---
name: test
description: Run existing tests via whey-drainer agent. Returns concise summary (pass/fail counts + failure details only). Does NOT write tests — use /wreck for that.
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[test command, or leave blank to auto-detect framework]"
---

Run the whey-drainer agent on: $ARGUMENTS

Use the whey-drainer agent (subagent_type: whey-drainer, model: haiku) to run existing tests. The agent detects the test framework, executes the suite, and returns only pass/fail counts and failure details — all verbose output stays in its context window.

If no argument is provided, the agent auto-detects the test framework (bats, pytest, jest, vitest, go test, cargo test, make test).

If a specific test command is provided (e.g., `pytest tests/auth/`, `bats tests/sync.bats`), the agent runs that instead.

Present the agent's test results directly to the user — passed/failed/skipped counts, framework detected, and failure details only.

This is different from `/wreck` (which WRITES adversarial tests) — `/test` only RUNS existing tests.
