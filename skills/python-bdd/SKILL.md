---
name: python-bdd
description: >
  Builds integration-first Python BDD suites when the user says "add Python BDD",
  "write Gherkin scenarios", "design behavior tests", "test the public CLI with pytest-bdd",
  "add integration scenarios", or invokes /python-bdd.
  Do NOT use for generic Python scaffolding (/python-scaffold), unit-only tests,
  test-suite speed work (/build-optimize), or CI speed work (/ci-optimize).
disable-model-invocation: true
argument-hint: "[<project-dir>] [<behavior-or-requirement>]"
license: MIT
metadata:
  author: paulnsorensen
---

# /python-bdd

Build a small Python behavior suite that exercises real public boundaries and detects representative regressions.

## Inputs

Read the project directory and behavior from the text after the skill name. Default the directory to the current directory.
Resolve missing product rules from project instructions, code, and existing tests. Ask only when the rule still changes acceptance.

## Flow

1. **Inspect.** Read the requirement, public entry point, persistence path, existing tools, build backend, local gate, and CI gate.
   Keep existing unit coverage and all existing tools. For a new repository, use /python-scaffold for its base stack.
   For a new project, use uv and pytest-bdd. In an existing repository, retain its runner and tools unless the user approves migration.
2. **Map.** Write a compact trace for each selected behavior: requirement → scenario → public boundary → assertion → failure probe.
   Select a few valuable paths, including a failure that must leave state unchanged when the contract requires it.
   Separate scenario-language altitude from execution altitude. Domain words describe one behavior and precise external outcomes, not command syntax or implementation details.
3. **Bind.** Write the scenario first. Bind each feature to a collected test module and check collection.
   Drive the real application through its public CLI, API, or service boundary. Use real application persistence with isolated test data.
   Substitute only out-of-process dependencies that cannot be controlled; check each substitute against its contract.
   Keep setup shortcuts outside the behavior under test. Do not require a browser for every scenario.
4. **Prove red.** Run the focused scenario and observe the intended failure before implementing its production slice.
   For existing behavior, demonstrate that a representative mutation or temporary, reversible production regression fails the correct assertion.
   Restore the change and confirm the scenario passes. Do not change production when an isolated, safe reversal is unavailable; report that proof as unrun.
   Do not remove unit tests or impose a unit-first loop. Add targeted unit tests for algorithms when useful.
5. **Converge.** Run the BDD slice and the repository's existing full gate.
   Build one wheel and smoke-test its installed public behavior outside the source tree when the project is packaged.
   Use locked dependencies and the same required checks locally and in CI. A cache may save downloads, but it never skips results.
   Measure timings before reporting speed. Claim improvement only against a comparable baseline.

## References

- [Implementation](references/implementation.md) — read when binding pytest-bdd, isolating persistence, or checking a built artifact.
- [Research](references/research.md) — read when choosing a scenario or evaluation format, or explaining this standard's evidence.

## Output

Report the trace, scenario count, public boundary, real components, substitutions, and the observed red/green result.
Name the exact local and CI gates, wheel-smoke result, measured timings if any, and each unrun check.

## What this skill never does

- It does not delete production code to force red.
- It does not replace an existing runner, package manager, backend, CI, or checks without approval.
- It does not treat readable Gherkin, collected scenarios, or green tests alone as integration proof.
