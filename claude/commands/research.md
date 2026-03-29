---
name: research
description: Multi-source research coordinator. Spawns parallel fetch subagents for library docs, external concepts, codebase patterns, and real-world examples. Synthesizes findings into a coherent answer.
argument-hint: [--report [filepath]] <research question or topic>
---

## Argument Parsing

Parse `$ARGUMENTS` for these flags before passing to the research agent:

- `--report` or `--report <filepath>` — Save findings as a markdown report with sources. If no filepath given, default to `.claude/research/<slugified-topic>.md` (create the directory if needed).

Everything after flag extraction is the **research question**.

## Execution

1. **Spawn the research agent** (subagent_type: research) with the research question. The agent handles parallel fetch subagents and synthesis.

2. **If `--report` was specified**, write the agent's synthesized output to the target filepath as a markdown file. The report MUST include:
   - Title and date
   - The synthesized finding
   - The full Evidence by Source table (source, finding, confidence score, cost)
   - A **Sources** section at the bottom listing every URL, doc reference, file path, or repo link cited by any fetcher — one per line, grouped by source type
   - Implications section if present

   Use this structure:
   ```markdown
   # Research Report: <Topic>
   _Generated: <YYYY-MM-DD>_

   <synthesized finding from agent>

   ## Evidence by Source
   <evidence table from agent>

   ## Implications
   <implications from agent, if any>

   ## Sources
   ### Documentation
   - <Context7 doc refs>

   ### Web
   - <URLs from Serper/Tavily results>

   ### Codebase
   - <file:line references>

   ### Open Source
   - <GitHub repo/file links from Octocode>
   ```

   Only include source sections that have entries. Tell the user where the report was saved.

3. **Always display** the synthesized answer in the conversation regardless of whether `--report` was used.
