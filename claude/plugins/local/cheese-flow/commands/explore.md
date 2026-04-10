---
description: Code exploration orchestrator. Runs explore-graph, explore-tilth, explore-tokei, and explore-lsp in parallel and synthesizes findings into an XML artifact (map, business context, optional change callstack).
argument-hint: [--scope <dir>] [--budget <N>] [--out <path>] <query>
---

Invoke the `explore` skill with `$ARGUMENTS`.

The skill parses the query, dispatches the four sub-agents in parallel, and writes a structured XML artifact to `.claude/exploration/<slug>.xml` (or the path passed via `--out`). It prints a ≤10-line summary to this context — the full artifact lives in the file.

Examples:

- `/explore how does request authentication flow work?`
- `/explore --scope src/domains/orders what are the main business concepts?`
- `/explore --out /tmp/oauth-plan.xml what needs to change to add OAuth2 support?`
