---
name: nih-audit
description: Scan a codebase for custom code that duplicates what open-source libraries already do, then recommend which libraries to adopt. Detects hand-rolled utility functions, custom retry logic, manual validation, DIY date handling, home-grown argument parsers, and other reinvented wheels. Cross-checks against installed dependencies and open specs. Returns scored migration recommendations with effort estimates.
argument-hint: "[directory to scope, or leave blank for full codebase]"
---

Run the /nih-audit skill on: $ARGUMENTS

This command invokes the nih-audit skill which handles the full workflow:
1. Detect build system and extract dependencies from manifests
2. Spawn nih-scanner agent for structural NIH pattern detection
3. Research library alternatives via parallel research agents
4. Check specs and code comments for intentional NIH decisions
5. Score findings 0-100 with evidence grounding and context modifiers
6. Report only findings >= 50 with effort sizing (S/M/L) and migration paths

If no argument is provided, scope to the full codebase.

This is an analysis command — it recommends but does NOT modify any files.
