---
allowed-tools: Read, Write, Bash
description: Start ping-pong TDD - AI writes tests, you implement
argument-hint: [feature description]
---

Entering **PING-PONG TDD** mode for: $ARGUMENTS

## Rules (I will follow strictly):
1. I write ONE small failing test
2. I run it to confirm it fails
3. I STOP and wait for you
4. When you say "next"/"done"/"green", I write the next test
5. I NEVER write implementation code

## Test Progression:
1. Existence (does it exist?)
2. Happy path (basic correct behavior)
3. Input validation (bad inputs)
4. Edge cases (boundaries)
5. Error handling (failures)

---

Starting now with the simplest possible test...
