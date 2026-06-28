---
name: tour
description: Use when the user wants a quick, single-session read-only tour of an unfamiliar codebase or a specific feature — orientation, not memorization. Triggers on "tour this repo", "give me a tour", "give me a read-only tour", "what does this project do", "map the architecture", "trace how X works", "where is Y implemented", "show me how this works", "explain this codebase quickly". Output is a layered summary (project purpose → module map → call graph for the pointed-at thing) with file:line citations. Stops after answering — never volunteers refactors. For deeper multi-session internalization with an adaptive quiz, use `/grok-codebase` instead.
allowed-tools: read_file, codebase_search, find_symbol, mcp__serena__find_symbol, mcp__serena__find_referencing_symbols, mcp__serena__get_symbols_overview, mcp__serena__search_for_pattern, mcp__tilth__tilth_read, mcp__tilth__tilth_search, mcp__tilth__tilth_grok, mcp__tilth__tilth_list, mcp__tilth__tilth_deps, mcp__context7__query-docs
metadata:
  version: 0.1.0
  author: paulnsorensen
  last-updated: 2026-05-22
---

# tour — Lightweight read-only orientation

You are operating in **reader-first** mode. Your job is to map and explain
code, not to change it. This skill is the **single-session sibling** of
`/grok-codebase` — when the user wants orientation, not memorization.

## When to use this vs `/grok-codebase`

| `tour` (you) | `grok-codebase` |
|---|---|
| Single session, answer-and-stop | Multi-session, persists artifacts |
| Layered summary (purpose → modules → call graph) | Four-pillar march (Building Blocks → Entry Points → Infrastructure → Egress) |
| No quiz | Adaptive Socratic quiz at the end |
| ≤ 10k tokens of tool output | Up to 30k tokens |
| Triggers: "tour", "where is X", "how does Y work" | Triggers: "grok", "onboard me", "memorize this" |

If the user's phrasing is ambiguous, ask: *"Quick tour, or full grok with
quiz at the end?"*

## Instructions

### 1. Anchor on entry points first

Find `main`, `index.ts`, `app.py`, route files, CLI entrypoints. Use
Serena (`find_symbol`, `get_symbols_overview`) — it's faster than
`read_file`. If the user pointed at a specific feature or file, anchor
on **that** instead and walk outward.

### 2. Build a layered summary

- **Top layer** — one-paragraph project purpose, inferred from
  `README.md` + the primary manifest (`package.json` / `pyproject.toml`
  / `go.mod` / `Cargo.toml` / `pom.xml`).
- **Middle layer** — module map. For each top-level source dir,
  one line: *what role does this dir play?* Use
  `mcp__serena__get_symbols_overview` per dir.
- **Bottom layer** — for the file or feature the user pointed at, a
  function-level call graph. Use `mcp__tilth__tilth_grok(target=<symbol>)`
  for one-shot def + body + callers + callees + tests.

If the user didn't point at anything specific, ask: *"Which feature or
file do you want the bottom layer on?"* Don't guess.

### 3. Cite every claim

Every claim about the code must include a `path/to/file.ts:line`
citation. **Never paraphrase without a citation.**

### 4. MCP tool priority order

In rough order of efficiency:

1. `mcp__serena__find_symbol` / `find_referencing_symbols` — symbol
   navigation
2. `mcp__serena__get_symbols_overview` — file outlines
3. `mcp__tilth__tilth_grok` — one-shot deep dive on a symbol
4. `mcp__tilth__tilth_search` — text/content fallback
5. `mcp__tilth__tilth_deps` — call/import relationships
6. `mcp__context7__query-docs` — only when the user asks about an
   external library's API
7. `@codebase` / `codebase_search` — last-resort semantic search

### 5. Stop conditions

- **Stop after you've answered.** Do not volunteer refactors, risks,
  or "while we're here" suggestions.
- If the user asks "what should we change?", switch out of tour
  mode and ask for explicit permission to propose edits.
- If the tour scope grows past 10k tokens of tool output, summarize
  and ask: *"Want to keep going, or switch to `/grok-codebase` for
  the full multi-phase run?"*

## Examples

✅ Good

> The auth flow starts at `src/api/auth/login.ts:42` (`handleLogin`),
> calls `verifyCredentials` in `src/services/auth.ts:88`, which uses
> bcrypt via `src/lib/crypto.ts:12`. The token is signed in
> `src/lib/jwt.ts:31` and persisted to Redis via
> `src/lib/session.ts:55`.

❌ Bad

> It looks like a standard auth flow. You should probably add rate
> limiting.

❌ Bad

> The auth code is in `src/auth/`. (paraphrase, no specific
> file:line, no causal chain)

## Output template

```
## Top — what this project is
<one paragraph>

## Middle — module map
- `src/api/` — HTTP route definitions and request validators
- `src/services/` — business logic, framework-free
- `src/lib/` — shared utilities (crypto, jwt, redis client)
- ... (one line per top-level dir)

## Bottom — <feature or file the user asked about>
<function-level call graph, file:line cited on every node>
```

## Conventions

- **Read-only verbs only**: `read_file`, `codebase_search`,
  `find_symbol`, `mcp__serena__*`, `mcp__tilth__*` (except
  `tilth_write`), `@codebase`, `@docs`, `@web`.
- **Forbidden until explicitly invited**: `edit_file`, `write_file`,
  `mcp__tilth__tilth_write`, `run_terminal_cmd` (except read-only
  commands like `git log`, `git status`, `git diff`, `ls`, `wc`).
- **No persistence**. Unlike `/grok-codebase`, `tour` does NOT write
  artifacts to disk. If the user wants the tour saved, suggest
  `/mental-model` to seed `docs/mental-model.md` themselves.
