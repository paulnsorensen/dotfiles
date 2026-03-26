---
name: ghostbuster
description: Dead code forensics — find expired code, stale specs, and incomplete implementations. Categorizes findings as DEAD, ZOMBIE, GHOST, or DORMANT with confidence scoring.
argument-hint: "[directory to scope, or leave blank for full codebase]"
---

Run the /ghostbuster skill on: $ARGUMENTS

This command invokes the ghostbuster skill which handles the full workflow:
1. Discover source files and detect languages
2. Collect specs and docs (specs/, CLAUDE.md, README.md, docs/)
3. Spawn ghostbuster agent for dead code detection + spec cross-referencing
4. Present categorized findings (DEAD, ZOMBIE, GHOST, DORMANT) with confidence scores
5. Offer actionable next steps (delete, triage, update specs)

If no argument is provided, scope to the full codebase.

This is an analysis command — it reports but does NOT modify any files.
