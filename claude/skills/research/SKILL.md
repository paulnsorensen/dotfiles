---
name: research
description: >
  Multi-source research orchestrator. Spawns parallel fetch sub-agents for
  Context7 (library docs), Tavily (technical content), Serper (facts/SERP),
  codebase analysis, and Octocode (GitHub patterns). Fetchers write findings
  to scratch files; a single synthesis sub-agent reads them and returns a
  compact answer, keeping the caller's context clean. Use when the user
  invokes /research, asks "research X", needs 2+ sources for a decision, or
  is choosing between libraries/approaches. This is a SKILL, not an agent —
  it runs inline so the fetcher sub-agents are first-level agents, avoiding
  nested-agent depth issues.
  Do NOT use for single-source lookups (use /fetch for library docs alone) or
  codebase-only questions (use Grep/Read directly).
model: sonnet
allowed-tools: Agent, Bash, Write
---

# research

Multi-source research. Route sources once, spawn in parallel, synthesize in a
sub-agent with mechanical confidence scoring.

## Context Discipline

This skill runs **inline** in the caller's context so its fetcher `Agent()`
calls are first-level and work (Claude Code only permits 1 level of sub-agent
nesting). To keep the caller's context clean despite running inline:

1. **Fetchers write to scratch files, not the chat.** Each fetcher writes its
   findings to a per-run scratch directory and returns only a one-line
   `done: <path>` or `unavailable: <reason>`.
2. **A single synthesis sub-agent (opus) reads the scratch files.** The raw
   fetcher output is read and discarded inside the synthesis sub-agent; only
   the compact synthesis lands in the caller's context.
3. **The skill deletes the scratch directory** after synthesis (kept only in
   `--report` mode for debuggability).

Net effect: caller sees ~5 "fetcher done" lines plus one compact synthesis.
No evidence tables, snippets, or URLs bloat the main context.

## What the Skill Emits to the Caller

The skill prints exactly these blocks to the caller's context — nothing else:

1. **Routing decision** block from Phase 2 (small, bounded).
2. **Fetcher status** map from Phase 3 (one line per routed source).
3. **Synthesis block** from Phase 4, emitted verbatim from the synthesis
   sub-agent.
4. A single line "Report saved to `<path>`" if `--report` was set.

Do NOT print: fetcher narration, intermediate debug output, raw scratch-file
contents, or scratch file paths except inside the FETCHER STATUS block
(where `done: <path>` is bounded internal bookkeeping). If something doesn't
fit the four blocks above, it stays silent.

## Phase 0: Argument Parsing and Setup

Parse `$ARGUMENTS` for these flags:

- `--report` or `--report <filepath>` — Save findings as a markdown report.
  Default path: `.claude/research/<slugified-topic>.md` (create dir if needed).

Everything after flag extraction is the **research question**.

Compute the scratch directory for this run:

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-<slug>"
RUN_DIR="$(pwd)/.claude/research/tmp/${RUN_ID}"
mkdir -p "$RUN_DIR"
```

Where `<slug>` is a 4-6 word kebab-case of the topic. The `RUN_DIR` value is
passed to every fetcher and to the synthesis sub-agent.

## Phase 1: Classify the Question

Identify:

- **Primary topic** — what are we researching?
- **Question type** — factual lookup? how-to? comparison? pattern search?
- **Complexity** — simple fact, focused question, or deep analysis?
- **Constraints** — version-specific? performance? architecture?

## Phase 2: Route Sources (DECIDE ONCE)

Select sources using the decision tree below. Output an **explicit committed
list** — these are the sources you will spawn in Phase 3. No "maybe," no
"if needed," no re-decision later.

### Decision tree

```
Is it about a specific library API?
  YES → Context7 (+ Octocode for real-world usage if needed)

Is it a factual lookup, entity, or "what/who/when" question?
  YES → Serper (fast, structured, cheap)

Is it a "how should I..." or best practices question?
  YES → Tavily (synthesized content) + maybe Serper (for People Also Ask breadth)

Is it about patterns in our codebase?
  YES → Codebase Fetcher (+ Octocode if comparing to industry patterns)

Is it about how open-source projects solve X?
  YES → Octocode (+ Tavily if needing written analysis/articles about the approach)
```

### When each source wins

| Source | Best for | Cost |
|--------|----------|------|
| **Context7** | Specific library API, config, version migration | Free (1K/mo) |
| **Serper** | Facts, entities, recency, "what/who/when" | ~$0.001/query |
| **Tavily** | How-to, best practices, technical analysis | ~$0.003-0.008/query |
| **Codebase** | Internal patterns and constraints | Free |
| **Octocode** | Real-world OSS usage patterns | Free |

### Scaling effort to complexity

| Complexity | Sources | Example |
|-----------|---------|---------|
| Simple fact | 1-2 | "What's the latest version of Prisma?" |
| Focused how-to | 2-3 | "How do I set up connection pooling in sqlx?" |
| Comparison | 3-4 | "What are the tradeoffs between Axum and Actix?" |
| Deep research | 4-5 | "How should we architect real-time notifications?" |

### Output of Phase 2

Write out the committed routing decision in chat:

```
ROUTING DECISION:
- Tavily: YES (transformed query: "<query>")
- Serper: YES (transformed query: "<query>")
- Context7: NO (not a library API question)
- Codebase: NO (external question)
- Octocode: NO
```

## Phase 3: Execute Fetchers (SPAWN EVERY ROUTED SOURCE)

**HARD RULE** — the cardinal rule of this skill:

> **If a source was committed in Phase 2, you MUST spawn it in Phase 3.**
> "Marginal value," "local evidence is enough," "would add little" are NOT
> reasons to skip. Those judgments belonged in Phase 2 routing. Once committed,
> execution is mechanical.
>
> If you find yourself wanting to skip a committed source mid-execution, STOP.
> Either (a) spawn it anyway, or (b) explicitly back out — say "I'm revising
> the routing decision because <reason>" and re-do Phase 2 with the new plan.
> Silent skipping is the #1 failure mode of this skill.

### Spawn pattern

Launch all committed fetchers in a **single message** with parallel `Agent`
calls. Use `subagent_type="general-purpose"`, `model="haiku"`, and pass the
fetcher prompt templates below.

**Every fetcher prompt MUST instruct the sub-agent to:**

1. Call only the specified MCP tools. **Do NOT use WebSearch or WebFetch.**
   Sub-agents default to those fallbacks, which produce weaker results.
2. **Write findings to `<RUN_DIR>/<source>.md`** (absolute path) using the
   schema below.
3. **Return to the skill only one of these two lines:**
   - `done: <RUN_DIR>/<source>.md`
   - `unavailable: <one-line reason>`

   Nothing else. No evidence tables, no URLs, no snippets in the return text.

### Scratch file schema

Each fetcher writes a markdown file with this shape:

```markdown
# <source> — <topic>
_Confidence: <0-100>_  _Status: <ok|unavailable>_

## Direct answer
<1-2 sentences>

## Evidence
<quotes, snippets, key facts — whatever the source schema asks for>

## Sources
- <URLs, file:line refs, library IDs>
```

### Query transformation

Each source performs best with a different query format:

| Source | Query style | Example |
|--------|-------------|---------|
| Context7 | Library + focused API question | `libraryName="express"`, `query="rate limiting middleware"` |
| Serper | Short Google keywords | `"express 5 rate-limit middleware 2026"` |
| Tavily | Natural language question | `"How to implement rate limiting in Express 5 with middleware best practices"` |
| Codebase | Symbol / pattern description | `"rate limiting middleware"` |
| Octocode | Technical terms + signatures | `"express rate-limit middleware"` |

### Fetcher prompts

Substitute `<RUN_DIR>` with the absolute path computed in Phase 0.

#### Context7 Fetcher

```
You are fetching library documentation via Context7.
Do NOT use WebSearch or WebFetch. Use ONLY the MCP tools below.

Steps:
1. Call mcp__context7__resolve-library-id(libraryName="<library>", query="<question>")
2. Call mcp__context7__query-docs(libraryId="<resolved-id>", query="<focused question>")
3. Max 3 Context7 calls total.
4. Write findings to <RUN_DIR>/context7.md using the scratch file schema
   (Direct answer, Evidence with code/version caveats, Sources).
5. Return ONLY: "done: <RUN_DIR>/context7.md"

If the MCP returns no results or errors:
- Write a 1-line note to <RUN_DIR>/context7.md: "Context7 unavailable: <reason>"
- Return ONLY: "unavailable: <reason>"
- Do NOT fall back to local knowledge.

Do not print evidence, URLs, or snippets in your return message.
```

#### Serper Fetcher

```
You are retrieving structured Google SERP data via Serper.
Do NOT use WebSearch or WebFetch. Use ONLY the MCP tools below.

Tools:
- mcp__serper__google_search(q="<keywords>", gl="us", hl="en")
- mcp__serper__scrape(url="<url>")

Query style: SHORT keyword queries.
BAD:  "How do I implement rate limiting in Express 5 with middleware?"
GOOD: "express 5 rate-limit middleware 2026"

Steps:
1. Search with keyword query
2. Check answerBox and knowledgeGraph for direct answers
3. Note peopleAlsoAsk if relevant
4. If a result needs deeper content, use mcp__serper__scrape(url="<url>")
5. Max 3 Serper calls total.
6. Write findings to <RUN_DIR>/serper.md using the scratch file schema
   (answerBox/KG answer, top 2-3 organic results with snippets, URLs).
7. Return ONLY: "done: <RUN_DIR>/serper.md"

If the MCP returns no results or errors:
- Write a 1-line note to <RUN_DIR>/serper.md: "Serper unavailable: <reason>"
- Return ONLY: "unavailable: <reason>"
- Do NOT fall back to local knowledge.

Do not print evidence, URLs, or snippets in your return message.
```

#### Tavily Fetcher

```
You are researching technical concepts via Tavily AI search.
Do NOT use WebSearch or WebFetch. Use ONLY the MCP tools below.

Tools:
- mcp__tavily__tavily_search(query="<natural language>", search_depth="basic"|"advanced")
- mcp__tavily__tavily_extract(urls=["..."], query="<question>")

Query style: NATURAL LANGUAGE.
BAD:  "express rate-limit 2026"
GOOD: "How to implement rate limiting in Express 5 with middleware best practices"

Depth:
- Quick factual → search_depth="basic" [1 credit]
- How-to/analysis → search_depth="advanced" [2 credits]
- Full page content → add include_raw_content=true
- DO NOT use tavily_research (15-250 credits) without explicit coordinator OK.

Steps:
1. Search with appropriate depth
2. If snippets insufficient, extract from 1 promising URL
3. Max 3 Tavily calls.
4. Write findings to <RUN_DIR>/tavily.md using the scratch file schema
   (Direct answer, key supporting detail or code pattern, Source URLs).
5. Return ONLY: "done: <RUN_DIR>/tavily.md"

If the MCP returns no results or errors:
- Write a 1-line note to <RUN_DIR>/tavily.md: "Tavily unavailable: <reason>"
- Return ONLY: "unavailable: <reason>"
- Do NOT fall back to local knowledge.

Do not print evidence, URLs, or snippets in your return message.
```

#### Codebase Fetcher

```
You are analyzing the local codebase for patterns and usage.
Do NOT use WebSearch or WebFetch.

Question: <question>

Use Grep, Glob, and Read to discover:
- How is this pattern used in our code?
- What constraints exist?
- Precedents or similar code?

Steps:
1. Run the searches needed to answer.
2. Write findings to <RUN_DIR>/codebase.md using the scratch file schema
   (Findings, file:line references, confidence).
3. Return ONLY: "done: <RUN_DIR>/codebase.md"

If you find nothing relevant:
- Write "No relevant patterns found" to <RUN_DIR>/codebase.md with confidence 25.
- Return ONLY: "done: <RUN_DIR>/codebase.md"

Do not print findings or file contents in your return message.
```

#### Octocode Fetcher

```
You are searching GitHub for real-world OSS patterns.
Do NOT use WebSearch or WebFetch. Use ONLY the octocode MCP tools.

Topic: <topic>
Question: <question>

Find:
- 2-3 popular public repo examples
- How they solve this problem
- Observable best practices

Steps:
1. Use the octocode MCP tools to find relevant repos and code.
2. Write findings to <RUN_DIR>/octocode.md using the scratch file schema
   (Key patterns as bullets, 1-2 code snippets with repo links).
3. Return ONLY: "done: <RUN_DIR>/octocode.md"

If the MCP returns no results or errors:
- Write a 1-line note to <RUN_DIR>/octocode.md: "Octocode unavailable: <reason>"
- Return ONLY: "unavailable: <reason>"
- Do NOT fall back to local knowledge.

Empty results are NOT failures. If octocode runs but finds no matches for a
niche query, write "No public examples found" to the scratch file with
confidence 25 and return "done: <RUN_DIR>/octocode.md".

Do not print evidence, URLs, or snippets in your return message.
```

### Collect fetcher results

All fetchers run in parallel via a single-message batch of `Agent` calls. Each
returns one short line. Assemble a status map:

```
FETCHER STATUS:
- context7: done: <RUN_DIR>/context7.md
- serper:   done: <RUN_DIR>/serper.md
- tavily:   unavailable: MCP not reachable
- codebase: done: <RUN_DIR>/codebase.md
- octocode: done: <RUN_DIR>/octocode.md
```

Do NOT read the scratch files yourself. They go to the synthesis sub-agent.

## Phase 4: Synthesis Sub-Agent

Spawn **one** `Agent` call with `subagent_type="general-purpose"`,
`model="opus"`. The synthesis sub-agent is the part that thinks hard — it
reads every scratch file, cross-checks sources, applies the mechanical cap,
and emits a compact answer. Give it permission and budget to reason
carefully; do not constrain it to a fast-and-loose summary.

### Synthesis prompt template

```
You are the synthesis stage of a multi-source research run. Think carefully
before writing — this is the reasoning-heavy part of the pipeline.

Question: <original research question>

Fetcher status (from the skill):
- context7: <done|unavailable|not-routed> [path or reason]
- serper:   ...
- tavily:   ...
- codebase: ...
- octocode: ...

Read each "done" file with the Read tool. Ignore "unavailable" and
"not-routed" entries for content purposes but count them in the cap below.

Task:

1. Build an evidence table with one row per ROUTED source (not just "done"
   ones). Columns: Source | Finding (1 sentence) | Score (0-100) | Notes.
   For sources marked unavailable or not-routed, put "N/A — <reason>" in
   Score.

2. Apply the MECHANICAL confidence cap:
   - failures = count of rows where Score is "N/A" OR Notes contain
     `not spawned`, `unavailable`, `failed`, `skipped`, `not fetched`, `error`
   - If failures > 0:
     * Overall Confidence starts with `≤49 (INCOMPLETE — <N> sources missing)`
     * Prepend synthesis with: `⚠️ INCOMPLETE RESEARCH — <names> not reached.`
     * This cap is non-negotiable. Do not reclassify failures as intentional.
   - Else:
     * 3+ sources agree → 85-100
     * 2 sources agree → 60-84
     * Disagreement → cap at 49 and note why
     * 1 source only → inherit that source's score

3. Emit the synthesis in exactly this format:

   ## Research: <Question>

   [⚠️ INCOMPLETE RESEARCH line if applicable]

   ### Finding
   <1-3 paragraphs, synthesized from all available sources. No raw snippets.>

   ### Evidence by Source
   | Source | Finding | Score | Notes |
   |---|---|---|---|
   | ... |

   ### Implications
   <How this affects the caller's task, 2-4 sentences.>

   ### Overall Confidence
   **<score>** — <justification based on source agreement and completeness>

Keep the synthesis tight. The caller does NOT need to see raw evidence —
only the distilled answer, the table, and the confidence line.

Do not reference the scratch file paths in the synthesis. Cite concrete
URLs / file:line refs / library doc refs from the scratch files instead.
```

### Receive the synthesis

The sub-agent returns the full synthesis block. Pass it through to the user
verbatim (do not re-summarize).

## Phase 5: Report File (if --report)

If `--report` was specified in Phase 0:

1. Write the synthesis (from Phase 4) plus a Sources appendix to the target
   path. The Sources appendix is assembled by reading the scratch files with
   `Bash` + `grep '^- '` on their `## Sources` blocks — this is the ONE place
   the skill reads scratch content, and only for structured URL extraction.

2. Report layout:

   ```markdown
   # Research Report: <Topic>
   _Generated: <YYYY-MM-DD>_

   <full synthesis from Phase 4>

   ## Sources
   ### Documentation
   - <Context7 doc refs>

   ### Web
   - <URLs from Serper/Tavily>

   ### Codebase
   - <file:line references>

   ### Open Source
   - <GitHub repo/file links from Octocode>
   ```

   Only include source sections that have entries.

3. Tell the user where the report was saved.

## Phase 6: Cleanup

- If `--report` was NOT used: `rm -rf "$RUN_DIR"` — scratch files are
  throwaway. The synthesis already lives in the caller's message history.
- If `--report` WAS used: keep `RUN_DIR` for debuggability, but move it under
  `.claude/research/archive/<RUN_ID>/` so `tmp/` stays clean.

## What This Skill Never Does

- Read scratch files in the skill's own context (only the synthesis sub-agent
  reads them, plus a narrow grep-for-URLs pass in `--report` mode)
- Write application code or implement solutions — it informs, never acts
- Use `tavily_research` (15-250 credits) without explicit user request
- Spawn all 5 sources for a simple factual question
- Skip a source that was committed in Phase 2 — see the HARD RULE in Phase 3
- Silently downgrade the confidence cap when sources fail — the cap is mechanical
- Use WebSearch or WebFetch in sub-agents (they must use assigned MCPs)
- Substitute for a domain agent — research feeds implementation, doesn't replace it

## Gotchas

- **The cardinal sin**: Silent source failure. If a sub-agent can't reach its
  MCP (not loaded, auth expired, network), it returns vague local-only text.
  The mechanical cap inside the synthesis sub-agent is what prevents this
  from sneaking through. Trust the algorithm, not intuition about "marginal
  value."
- **Context protection relies on the skill not reading scratch files.** If
  you find yourself calling `Read` on a fetcher output, stop — that raw data
  belongs in the synthesis sub-agent's context, not yours.
- **Synthesis model must be opus.** Haiku and sonnet cut corners on
  cross-source reasoning and cap arithmetic. If opus is unavailable, abort
  the run and tell the user — do not silently downgrade to sonnet or haiku.
  Silent-downgrade is the same class of failure as silent source skipping:
  the user can't tell the pipeline ran degraded.
- **Routing ≠ execution**: Phase 2 is where you decide which sources to use.
  Phase 3 is where you spawn them. Once Phase 2 commits, Phase 3 has no
  discretion. Mixing the two is the #1 failure mode.
- **Serper vs Tavily**: Serper returns URLs + metadata. Tavily returns content.
  "What is X?" → Serper. "How should I use X?" → Tavily.
- **Serper needs short keywords**; Tavily wants natural language. Wrong style
  = worse results.
- **`tavily_research` is expensive** (15-250 credits vs 1-2 for
  `tavily_search`). Only when the user explicitly opts in.
- **`include_raw_content`** on Tavily search combines search + extract in one
  call — saves a `tavily_extract` call.
- **Context7 name ambiguity**: the fetcher must verify the resolved library
  matches the question and note it in the scratch file.
- **Flat delegation**: sub-agents cannot spawn further sub-agents. Each
  fetcher calls MCP tools directly; the synthesis sub-agent calls Read only.
- **Wrap-up budget**: after ~30 tool calls in the skill (including sub-agent
  waits), proceed to synthesis with what you have.
