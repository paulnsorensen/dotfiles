---
name: research
description: Multi-source research. Routes a question across library docs, SERP, AI search, codebase, and GitHub in parallel and synthesizes a compact answer with mechanical confidence scoring.
argument-hint: [--report [filepath]] <research question or topic>
---

Invoke the `research` skill with the user's arguments. The skill parses `--report` itself and handles routing, parallel fetching, synthesis in a sub-agent (opus), and optional report writing.

Pass `$ARGUMENTS` through verbatim via the Skill tool (`skill: "research"`, `args: "$ARGUMENTS"`).

Do NOT spawn the research agent — it no longer exists. Do NOT attempt to fetch sources yourself; the skill manages the whole pipeline.
