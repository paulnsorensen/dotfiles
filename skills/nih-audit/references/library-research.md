# Phase 2 Detail: Category Queries and the Lookup-Agent Prompt

## Research query shapes by category

Deduplicate candidates that share a category, then group into research queries:

| Category | Research query shape |
|----------|---------------------|
| RETRY | "best retry/backoff library for {language}" |
| UUID | "recommended UUID library for {language}" |
| VALIDATION | "best validation library for {language}" |
| DATE | "best date/time library for {language}" |
| DEBOUNCE | "debounce/throttle library for {language}" |
| CLONE | "deep clone library for {language}" |
| ARGPARSE | "argument parsing library for {language}" |
| STRING | "string manipulation library for {language}" |
| HTTP | "HTTP client library for {language}" |
| SERIALIZATION | "serialization library for {language}" |
| ERROR | "error handling library for {language}" |
| CRYPTO | "password hashing library for {language}" |
| SECURITY | "HTML sanitization library for {language}" |
| FORMAT | "number/currency formatting library for {language}" |
| COMPARE | "deep equality library for {language}" |

## Lookup-agent dispatch template

For each category group (max 5 parallel), spawn a general-purpose agent with
focused MCP access. Library lookup primarily uses Context7 for API surface
and `gh` CLI for repo stats — not a full /briesearch call.

```
Agent(
  subagent_type="general-purpose",
  model="sonnet",
  prompt="Find well-maintained open-source libraries for: <category description>
    Language: <lang>
    Already installed (DO NOT recommend): <depManifest deps>

    Use ONLY these tools (do NOT use WebSearch or WebFetch):
    - mcp__context7__resolve-library-id and mcp__context7__query-docs
    - `gh search repos` / `gh repo view` for GitHub stats

    For each library found, return:
    - Name and latest version
    - License (flag GPL, prefer MIT/Apache-2.0/BSD)
    - Weekly downloads or crates.io downloads
    - GitHub stars
    - Last commit date
    - Contributor count
    - Whether it's stdlib, micro-library, or framework
    - One-sentence API example showing how it replaces the NIH code",
  run_in_background=true
)
```

## Collect and deduplicate

Wait for all research agents. For each candidate:

- Map the best library recommendation to the candidate
- Drop recommendations for libraries already in depManifest
- Flag stdlib alternatives (no new dep needed — highest value)
- Note if the category yielded no good alternatives (candidate drops out)
