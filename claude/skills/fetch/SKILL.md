---
name: fetch
model: sonnet
description: >
  Fetch external documentation or code while protecting the main context window.
  Use WebSearch/WebFetch for library docs. Use gh CLI or WebFetch for external
  GitHub repos. Governs: when to skip and use training data, when to fetch
  inline vs delegate to a subagent.
---

# fetch

External knowledge with context window hygiene. Two sources, one budget.

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

### Inline (short, targeted)

Use `WebSearch` to find the official docs URL, then `WebFetch` with a focused query.

| Good queries | Bad queries |
|---|---|
| "useEffect cleanup return signature" | "explain React" |
| "Prisma upsert with where clause" | "how does Prisma work" |
| "Next.js App Router middleware config" | "Next.js authentication" |

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

Use the `gh` skill for GitHub operations (PRs, issues, releases, CI checks).

For reading raw file contents from public repos:
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
| Narrow, specific doc question | Inline WebSearch → WebFetch |
| Broad or multi-concept docs | `general-purpose` subagent |
| Local code search | Scout skill or Grep |
| External repo, 1–2 targeted files | Inline WebFetch |
| External repo, deep exploration | `general-purpose` subagent |
| Main context already heavy | Always delegate, never inline |

---

## Anti-patterns

- Fetching docs for `Array.prototype.filter` or other stable stdlib APIs
- Reading full file content before searching for what you need
- Fetching 5 files inline when a subagent would isolate the bloat
- Using WebFetch for authenticated GitHub repos (use `gh` skill instead)
- Calling WebSearch when training data is clearly sufficient
