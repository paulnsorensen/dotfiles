---
name: research
description: Multi-source research using an agent team for parallel external lookups, codebase analysis, and synthesis.
argument-hint: <research question or topic>
---

Research: **{{request}}**

Spawn an agent team for parallel multi-source research. Use this for questions that need 2+ sources (library docs, codebase analysis, GitHub examples). For quick single-source lookups, use the research skill inline instead.

---

## Team Structure

### Lead (you)
- **Owns**: Synthesis, Serena codebase analysis, final answer
- **Tools**: Serena MCP, Read, Grep, Glob (codebase tools)
- Coordinate teammates, merge findings, resolve contradictions

### Teammate: docs-fetcher
- **Role**: External documentation and web research
- **Tools**: Context7 MCP, WebSearch, WebFetch
- **Prompt pattern**: "Find documentation for <library/concept>. Specific question: <question>. Return a focused summary with code examples if available."

### Teammate: code-searcher
- **Role**: GitHub code search for real-world usage patterns
- **Tools**: Octocode MCP (githubSearchCode, githubGetFileContent, githubViewRepoStructure)
- **Prompt pattern**: "Search GitHub for real-world examples of <pattern/API usage>. Focus on popular repos with good practices. Return 3-5 relevant code snippets with context."

---

## When to Use a Team vs Inline

| Situation | Approach |
|---|---|
| Quick API question, single library | Inline (research skill) |
| "How does X work in our codebase?" | Inline (Serena only) |
| Library docs + codebase patterns | Team (docs-fetcher + lead) |
| External patterns + GitHub examples + codebase | Full team |
| Architecture decision needing prior art | Full team |

---

## Workflow

1. **Assess** — Does this need a team? If it's a single-source lookup, use the research skill inline.
2. **Dispatch** — Launch relevant teammates in parallel via Task tool with `agentTeam: true`:
   ```
   Task(subagent_type="general-purpose", prompt="<teammate prompt>", agentTeam: true)
   ```
3. **Analyze locally** — While teammates work, do your own Serena/codebase analysis
4. **Synthesize** — Merge all findings into a single coherent answer

---

## Output Format

```
## Research: <Question>

### Finding
<Direct answer in 1-3 paragraphs>

### Evidence
| Source | Finding |
|---|---|
| Codebase (Serena) | <what our code shows> |
| Docs (Context7/Web) | <what documentation says> |
| GitHub examples | <what real-world code does> |

### Implications for Our Task
- <How this affects the implementation>
- <Constraints or opportunities discovered>

### Confidence
<High/Medium/Low> — <brief justification>
```
