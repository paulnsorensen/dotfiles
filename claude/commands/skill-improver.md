---
name: skill-improver
description: Audit an agent or skill definition for calibration, tool scoping, context management, and output quality. Produces scored improvement recommendations.
allowed-tools: Read, Grep, Glob
argument-hint: "<path to agent or skill definition>"
---

Invoke the skill-improver skill on: $ARGUMENTS

Read the target agent or skill definition file, audit it against the 5 dimensions (confidence scoring, tool scoping, context management, prompt quality, output format), and produce a scored improvement report.

If no argument is provided, ask what to audit. Common targets:
- `claude/agents/<name>.md` — agent definitions
- `claude/skills/<name>/SKILL.md` — skill definitions

All recommendations use 4-step calibrated confidence scoring (classify, ground, context modifiers, borderline re-assessment). Only surface recommendations scoring >= 50.
