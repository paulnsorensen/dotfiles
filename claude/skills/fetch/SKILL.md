---
name: fetch
model: sonnet
context: fork
allowed-tools: WebSearch, WebFetch, gh, Task(subagent_type="general-purpose"), mcp__context7__resolve-library-id, mcp__context7__query-docs, mcp__octocode__*
description: >
  Fetch external documentation or code while protecting the main context window.
  Use Context7 (preferred) or WebSearch/WebFetch for library docs. Use octocode
  for GitHub code search, gh CLI for GitHub ops. Governs: when to skip and use
  training data, when to fetch inline vs delegate to a subagent.
---

# fetch

External knowledge with context window hygiene. Three sources, one budget.

## Should I fetch at all?

**Skip — use training data** when:
- Stable, well-known API: `Array.map`, `os.path`, `console.log`, HTTP status codes
- Single-line answer you're confident in
- Already fetched this in the current session
- The question is conceptual, not version-specific

**Fetch** when:
- Library version matters (Next.js 15 vs 14, React 19 hooks, Prisma 6)
- API is niche or fast-changing (auth libraries, ORMs, cloud SDKs, AI APIs)
- The user explicitly asks for current or latest docs
- You're generating code that will actually be run (not just explained)

---

## Library Documentation

### Context7 (preferred — targeted, version-aware)

Use Context7 first for any supported library. It returns curated, version-specific
code examples with minimal context overhead.

```
resolve-library-id(libraryName="<library>", query="<specific question>")
→ query-docs(libraryId="<id>", query="<specific question>")
```

| Good queries | Bad queries |
|---|---|
| "useEffect cleanup return signature" | "explain React" |
| "Prisma upsert with where clause" | "how does Prisma work" |
| "Next.js App Router middleware config" | "Next.js authentication" |

Fall back to WebSearch/WebFetch if the library isn't in Context7's index.

### WebSearch + WebFetch (fallback)

Use `WebSearch` to find the official docs URL, then `WebFetch` with a focused query.

### Subagent (broad or uncertain scope)

Delegate to `general-purpose` agent when:
- Broad question spanning multiple concepts
- Unsure how large the response will be
- Multiple related pages need cross-referencing

```
Task(subagent_type="general-purpose", prompt="Look up <specific question> in <library> docs. Return a focused summary.")
```

---

## External Code (GitHub / packages)

### Octocode (code search)

Use octocode MCP for searching GitHub code — finding implementations, usage examples,
or how a pattern is used across public repos.

```
mcp__octocode__search_code(query="<pattern>", ...)
```

Use octocode when:
- Searching for real-world usage examples of an API
- Finding how an open-source library implements something internally
- Looking for patterns across multiple repos

### gh skill (GitHub ops)

Use the `gh` skill for GitHub operations (PRs, issues, releases, CI checks). The gh skill uses GitHub MCP tools by default (sandbox-safe), with `gh` CLI as fallback for CI/diff operations.

### WebFetch (raw file contents)

For reading specific files from public repos:
```
WebFetch(url="https://raw.githubusercontent.com/owner/repo/main/path/to/file")
```

### Subagent (deep exploration)

Delegate to `general-purpose` agent when:
- Exploration requires reading 3+ files
- Tracing a call chain across multiple modules
- Unfamiliar codebase with unclear entry points

```
Task(subagent_type="general-purpose", prompt="In <repo>, trace how X calls Y. Return a summary only.")
```

Tell the subagent to **return a summary**, not raw file contents.

---

## Context Budget Quick Reference

| Situation | Action |
|---|---|
| Training data is sufficient | Skip fetch entirely |
| Narrow, specific doc question | Context7 inline |
| Library not in Context7 index | WebSearch → WebFetch inline |
| Broad or multi-concept docs | `general-purpose` subagent |
| GitHub code search / usage examples | Octocode inline |
| Local code search | Scout skill or Grep |
| External repo, 1–2 targeted files | Inline WebFetch |
| External repo, deep exploration | `general-purpose` subagent |
| Main context already heavy | Always delegate, never inline |

---

## What You Don't Do

- Modify code or files — only fetch and return information
- Search local code — use scout, Grep, or LSP for that
- Run GitHub operations (PRs, issues) — use the gh skill

## Anti-patterns

- Fetching docs for `Array.prototype.filter` or other stable stdlib APIs
- Using WebSearch when Context7 covers the library
- Reading full file content before searching for what you need
- Fetching 5 files inline when a subagent would isolate the bloat
- Using WebFetch for authenticated GitHub repos (use `gh` skill / GitHub MCP instead)
- Using octocode for GitHub ops (PRs, issues) — that's the `gh` skill's job (via MCP)
- Calling WebSearch when training data is clearly sufficient

## Gotchas

- Context7 `resolve-library-id` sometimes returns the wrong library for ambiguous names — verify the resolved ID
- WebFetch on JavaScript-heavy sites returns empty content — try WebSearch as fallback
- Sub-agent summaries can lose critical version-specific details — request explicit version numbers
- Large MCP responses (>25K tokens) get truncated — write to `/tmp/` and analyze via file read
