---
name: research
description: Multi-source research coordinator. Spawns parallel fetch subagents for library docs, external concepts, codebase patterns, and real-world examples. Synthesizes findings into a coherent answer.
argument-hint: <research question or topic>
---

Research: **$ARGUMENTS**

Use the research agent (subagent_type: research) to conduct the investigation.

The agent spawns 2-4 parallel haiku subagents (Context7, WebSearch, Codebase via LSP, Octocode), synthesizes findings into one answer with an Evidence table and overall 0-100 confidence score. See `claude/agents/research.md` for full protocol.
