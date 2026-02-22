---
name: research
model: sonnet
allowed-tools: WebSearch, WebFetch, Bash(rg:*), Bash(fd:*), Bash(sg:*), mcp__serena__*, mcp__plugin_context7_context7__*, mcp__plugin_context7-plugin_context7__*, mcp__octocode__*, Task(subagent_type="general-purpose")
description: >
  Research skill for requirements gathering. Combines external docs (Context7, WebSearch),
  codebase analysis (Serena), and GitHub code search (octocode) to answer
  research questions and gather context for feature development.
---

# research

Multi-source research for requirements gathering and context building. Three modes, one synthesized answer.

## When to Use

- Pasteurize phase needs external context (library APIs, prior art, design patterns)
- Requirements are unclear and need research to clarify
- Need to combine external knowledge with codebase understanding
- General-purpose research for any development question

## Research Routing

### 1. Library / Framework APIs → Context7 (preferred)

For version-specific library docs:

```
resolve-library-id(libraryName="<library>")
→ query-docs(libraryId="<id>", query="<specific question>")
```

Fall back to WebSearch + WebFetch if the library isn't indexed.

### 2. Codebase Patterns → Serena

For understanding existing code:

```
find_symbol(name_path_pattern="<pattern>", include_body=true)
get_symbols_overview(relative_path="<file>")
search_for_pattern(substring_pattern="<pattern>")
```

Use rg/fd via Bash for broader file-level searches.

### 3. External Concepts / Prior Art → WebSearch + WebFetch

For design patterns, architecture references, or general technical research:

```
WebSearch(query="<specific technical question>")
→ WebFetch(url="<most relevant result>", prompt="Extract <specific info>")
```

### 4. Real-World Usage Examples → Octocode

For finding how others have solved similar problems:

```
mcp__octocode__search_code(query="<pattern or API usage>")
```

### 5. Deep Exploration → Subagent

When research requires reading 3+ external sources or tracing complex call chains:

```
Task(subagent_type="general-purpose", prompt="Research <topic>. Return a focused summary of findings.")
```

Tell subagents to return **summaries**, not raw content.

## Output Format

Return synthesized, actionable findings — not raw dumps:

```
## Research: <Question>

### Finding
<Direct answer to the question in 1-3 paragraphs>

### Evidence
- <Source 1>: <What it says>
- <Source 2>: <What it says>

### Implications for Our Task
- <How this affects the implementation>
- <Constraints or opportunities discovered>

### Confidence
<High/Medium/Low> — <brief justification>
```

## Anti-patterns

- Fetching docs for stable, well-known APIs (Array.map, os.path)
- Dumping raw WebFetch content into the response
- Using WebSearch when Context7 covers the library
- Searching for everything — focus on what the task actually needs
- Using octocode for GitHub ops (that's the gh skill)
