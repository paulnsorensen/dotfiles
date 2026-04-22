---
name: fetch
model: sonnet
context: fork
allowed-tools: WebSearch, WebFetch, gh, Task(subagent_type="general-purpose"), mcp__context7__resolve-library-id, mcp__context7__query-docs, mcp__tavily__tavily_search, mcp__tavily__tavily_extract, mcp__tavily__tavily_research, mcp__serper__*
description: >
  Fetch external documentation or code while protecting the main context window.
  Use Context7 (preferred, free) for library docs. Use Tavily for technical concepts
  and best practices. Use Serper for factual lookups and Google SERP features.
  Use `gh` CLI for GitHub operations. Cost-aware routing:
  free → cheap → expensive. Governs: when to skip and use training data, when to
  fetch inline vs delegate to a subagent.
---

# fetch

External knowledge with context window hygiene. Five sources, one budget.

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

## Source Routing (cost-aware)

Try free tools first, then cheap, then expensive:

| Priority | Source | Cost | Use When |
|----------|--------|------|----------|
| 1 | Context7 | Free (1K calls/mo) | Library/framework API question |
| 2 | Codebase (Grep/Read/tilth) | Free | Local code patterns |
| 3 | Serper | ~$0.001/query | Factual lookups, SERP features, news |
| 4 | Tavily search | ~$0.003-0.008/query | Technical concepts, best practices |
| 5 | Tavily research | ~$0.12-2.00/call | Deep multi-source exploration (user must request) |
| 6 | gh search / gh repo view | Free | GitHub code search and repo metadata |
| 7 | WebSearch/WebFetch | Varies | Legacy fallback if MCPs are down |

---

## Library Documentation

### Context7 (preferred — free, version-aware)

Use Context7 first for any supported library. Returns curated, version-specific
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

Fall back to Tavily if the library isn't in Context7's index.

### Tavily (preferred fallback — AI-optimized search)

Use Tavily when Context7 doesn't cover the library or when you need technical
concepts beyond API reference docs. Returns AI-processed, markdown-formatted content.

```
tavily_search(query="<natural language question>", search_depth="basic"|"advanced")
```

| search_depth | Cost | Use When |
|---|---|---|
| basic | 1 credit | Quick lookup, well-known topic |
| advanced | 2 credits | Deep technical question, version-specific |

**Cost-saving tip**: `tavily_search(..., include_raw_content=true)` returns full
page markdown inline, combining search + extract in one call. Avoids a separate
`tavily_extract` call.

Use `tavily_extract(urls=[...], query="<question>")` only when you already have
a specific URL to read (e.g., from a Serper result).

**DO NOT** use `tavily_research` unless the user explicitly asks for deep research.
It costs 15-250 credits per call.

### Serper (Google SERP features — cheapest paid option)

Use Serper when you need Google's structured SERP data: Knowledge Graph entries,
answer boxes, People Also Ask, or when a keyword-optimized Google search will
find the answer faster than AI search.

```
google_search(q="<keyword query>", gl="us", hl="en")
```

Serper returns URLs and snippets, not extracted content. If you need page text,
follow up with `scrape(url="<url>")`.

Best for:

- Factual lookups where Google's answer box has the answer
- Discovering related questions via People Also Ask
- Entity information via Knowledge Graph
- Quick sanity checks ("is X deprecated?")

### WebSearch + WebFetch (legacy fallback)

Use only if Tavily and Serper MCPs are unavailable. These are the least
structured option.

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

### gh CLI for GitHub search

Use `gh search code`, `gh search repos`, and `gh repo view` to search GitHub from
the command line. Bounded output, no MCP surface cost.

Use when:

- Searching for real-world usage examples of an API (`gh search code '<query>'`)
- Inspecting a specific repo's README/structure (`gh repo view owner/repo`)
- Finding popular implementations (`gh search repos '<topic>' --sort stars`)
### gh skill (GitHub ops)

Use the `gh` skill for GitHub operations (PRs, issues, releases, CI checks). The
gh skill uses GitHub MCP tools by default (sandbox-safe), with `gh` CLI as fallback.

### Tavily extract / Serper scrape (read specific pages)

For reading a specific URL's content:

- `tavily_extract(urls=["<url>"], query="<question>")` — AI-processed, relevance-ranked chunks
- `scrape(url="<url>", includeMarkdown=true)` — raw page content with JSON-LD metadata

Tavily extract is better for long pages (it reranks by relevance). Serper scrape
is cheaper and includes structured metadata.

### Subagent (deep exploration)

Delegate to `general-purpose` agent when:

- Exploration requires reading 3+ files
- Tracing a call chain across multiple modules
- Unfamiliar codebase with unclear entry points

Tell the subagent to **return a summary**, not raw file contents.

---

## Context Budget Quick Reference

| Situation | Action | Cost |
|---|---|---|
| Training data is sufficient | Skip fetch entirely | Free |
| Narrow library API question | Context7 inline | Free |
| Factual lookup, entity info | Serper google_search | ~$0.001 |
| Technical concept, best practice | Tavily search (basic) | ~$0.003 |
| Deep technical question | Tavily search (advanced) | ~$0.006 |
| Need to read a specific URL | Tavily extract or Serper scrape | ~$0.001-0.003 |
| GitHub code search / examples | `gh search code` inline | Free |
| Local code search | Grep / Read | Free |
| Broad or multi-concept docs | general-purpose subagent | Varies |
| Main context already heavy | Always delegate, never inline | — |

---

## What You Don't Do

- Modify code or files — only fetch and return information
- Search local code — use Grep, Read, or LSP for that
- Run GitHub operations (PRs, issues) — use the gh skill
- Use tavily_research without explicit user request — it costs 15-250 credits

## Anti-patterns

- Fetching docs for `Array.prototype.filter` or other stable stdlib APIs
- Using WebSearch/WebFetch when Tavily or Serper can do the job better
- Using Tavily when Serper (cheaper) or Context7 (free) can answer the question
- Using tavily_research for a narrow question (tavily_search is 100× cheaper)
- Reading full file content before searching for what you need
- Fetching 5 files inline when a subagent would isolate the bloat
- Using WebFetch for authenticated GitHub repos — use the gh skill / gh CLI
- Calling any search tool when training data is clearly sufficient

## Gotchas

- Context7 `resolve-library-id` sometimes returns the wrong library for ambiguous names — verify the resolved ID
- Serper returns URLs and snippets, not content — follow up with `scrape` if you need page text
- Tavily `include_raw_content=true` saves a separate extract call — use it for single-page reads
- WebFetch on JavaScript-heavy sites returns empty content — try Tavily extract or Serper scrape instead
- Sub-agent summaries can lose critical version-specific details — request explicit version numbers
- Large MCP responses (>25K tokens) get truncated — write to `/tmp/` and analyze via file read
