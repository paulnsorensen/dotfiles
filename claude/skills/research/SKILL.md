---
name: research
model: sonnet
allowed-tools: WebSearch, WebFetch, Bash(rg:*), Bash(fd:*), Bash(sg:*), mcp__serena__*, mcp__plugin_context7_context7__*, mcp__plugin_context7-plugin_context7__*, mcp__octocode__*
description: >
  Inline research skill for quick single-source lookups. Combines external docs (Context7, WebSearch),
  codebase analysis (Serena), and GitHub code search (octocode) for focused answers.
  For multi-source research requiring parallel external access, use the /research command instead.
---

# research

Quick inline research for single-source lookups and focused questions.

## When to Use This Skill

- Quick library API question (one Context7 call)
- "How does X work in our codebase?" (Serena only)
- Single external concept lookup (one WebSearch)
- Fast check of GitHub usage patterns (one octocode call)

**For multi-source research** (library docs + codebase + GitHub examples), use `/research` which spawns an agent team for parallel lookups.

## Research Routing

### Library / Framework APIs → Context7 (preferred)

```
resolve-library-id(libraryName="<library>")
→ query-docs(libraryId="<id>", query="<specific question>")
```

Fall back to WebSearch + WebFetch if the library isn't indexed.

### Codebase Patterns → Serena

```
find_symbol(name_path_pattern="<pattern>", include_body=true)
get_symbols_overview(relative_path="<file>")
search_for_pattern(substring_pattern="<pattern>")
```

Use rg/fd via Bash for broader file-level searches.

### External Concepts → WebSearch + WebFetch

```
WebSearch(query="<specific technical question>")
→ WebFetch(url="<most relevant result>", prompt="Extract <specific info>")
```

### Real-World Usage → Octocode

```
mcp__octocode__search_code(query="<pattern or API usage>")
```

## Output Format

```
## Research: <Question>

### Finding
<Direct answer in 1-3 paragraphs>

### Evidence
- <Source>: <What it says>

### Implications for Our Task
- <How this affects the implementation>

### Confidence
<High/Medium/Low> — <brief justification>
```

## Anti-patterns

- Fetching docs for stable, well-known APIs (Array.map, os.path)
- Dumping raw WebFetch content into the response
- Using WebSearch when Context7 covers the library
- Searching for everything — focus on what the task actually needs
- Using octocode for GitHub ops (that's the gh skill)
- Using this for multi-source research that needs parallel lookups (use /research)
