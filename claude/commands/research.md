---
name: research
description: Multi-source research coordinator. Spawns 4 parallel fetch subagents for library docs, external concepts, codebase patterns, and real-world examples. Synthesizes findings into a coherent answer.
argument-hint: <research question or topic>
---

Research: **$ARGUMENTS**

Use the research agent (subagent_type: research) to conduct the investigation. The agent handles spawning 4 parallel fetch subagents and synthesizing results.

The research agent will conduct parallel multi-source investigation, fetching from:
- **Context7**: Library documentation and APIs
- **WebSearch/WebFetch**: External concepts and best practices
- **Serena**: Codebase patterns and usage
- **Octocode**: Real-world GitHub examples

Results are synthesized into a single coherent answer with evidence from all sources.

---

## When to Use

✅ **Use this agent** for questions needing 2+ sources:
- "How do I set up authentication in Express 5?" (docs + examples + patterns)
- "What's the best pattern for rate limiting?" (web + GitHub + codebase)
- "How do we handle X in our codebase, and what do other projects do?" (Serena + Octocode)

❌ **Don't use** for single-source questions:
- "What does `Array.map` do?" (training data is fine)
- "How does our auth module work?" (use Serena directly, inline)
- "Show me React useEffect docs" (use fetch skill directly)

---

## Output Format

The agent returns findings organized by source:

```markdown
## Research: <Question>

### Finding
<Direct answer synthesized from all sources>

### Evidence by Source
| Source | Finding | Confidence |
|---|---|---|
| Docs (Context7) | <what we learned> | High/Medium/Low |
| Web (WebSearch) | <what we learned> | High/Medium/Low |
| Codebase (Serena) | <what we learned> | High/Medium/Low |
| GitHub (Octocode) | <what we learned> | High/Medium/Low |

### Implications for Our Task
- <How this affects implementation>
- <Constraints or opportunities>

### Overall Confidence
<High/Medium/Low> — <brief justification>
```
