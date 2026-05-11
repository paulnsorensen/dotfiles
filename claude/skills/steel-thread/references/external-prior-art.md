# CRG — external prior art

How others use `code-review-graph` well. Confidence per claim. `<certain>` only when verified from a primary source.

## Official skills bundled in the repo

`tirth8205/code-review-graph` ships its own `skills/` directory with at least the following SKILL.md files (visible via `code-review-graph install --platform claude`):

- `build-graph` — wraps `build_or_update_graph_tool` + verification. `<certain>` (fetched).
- `review-pr` — wraps the full PR review flow. `<certain>` (fetched).
- `review-changes`, `debug-issue`, `explore-codebase`, `refactor-safely`, `onboard-developer` — referenced in commit history (Qoder platform support PR, Apr 2026). `<speculative>` on exact filenames; structure confirmed.

**Verbatim sequencing from `skills/review-pr/SKILL.md`** (`<certain>`):

1. `get_docs_section_tool(section_name="review-pr")` — bootstrap.
2. `build_or_update_graph_tool(base="main")` — refresh.
3. `get_review_context_tool(base="main")` — fetch changed files + context.
4. `get_impact_radius_tool(base="main")` — blast radius.
5. Per-file deep dives via `query_graph_tool()` and `semantic_search_nodes_tool()`.

**Notable absence**: neither the bundled `review-pr` skill nor the README's terminology mention "steel threads" or "fuzzy concept tracing" by those names. The closest CRG primitive is the `Flow` concept exposed by `list_flows_tool` / `get_flow_tool` / `get_affected_flows_tool` — CRG calls these "execution flows", and they are pre-computed during postprocess via flow detection. `<certain>`

**Implication for your skill**: you'll be coining the "steel thread" vocabulary on top of CRG's `Flow` primitive. The mapping is: a CRG `Flow` is an end-to-end execution path through the graph from an entry-point node, scored by criticality. Use `list_flows_tool` first; fall back to `traverse_graph_tool` from a `semantic_search_nodes_tool` hit only when no existing flow matches.

## Third-party skill marketplaces

- **LobeHub Skills Marketplace** — lists `code-review-graph` as an installable skill. Recommends `claude plugin marketplace add tirth8205/code-review-graph` then `claude plugin install code-review-graph@code-review-graph`. <https://lobehub.com/skills/aradotso-trending-skills-code-review-graph> `<certain>`
- **MCP Market** — lists `intelligent-pr-review-impact-analysis` by **n24q02m** (the maintainer of the `better-code-review-graph` fork). Focuses specifically on "graph-based PR review & impact analysis" with token-efficient search and qualified call resolution. <https://mcpmarket.com/tools/skills/intelligent-pr-review-impact-analysis> `<certain>`
- **SkillsLLM** — verified listing for `code-review-graph` with security report. <https://skillsllm.com/skill/code-review-graph> `<certain>`
- **Smithery** — hosts `Token-Eater/graph-skills`, a *different* skill (lightweight graph-based orchestration for Claude Code), not a CRG wrapper. Not directly applicable but worth flagging as adjacent work. <https://smithery.ai/skills/Token-Eater/graph-skills> `<certain>`

## Forks worth knowing

- **`n24q02m/better-code-review-graph`** — fork with "critical bug fixes, configurable embeddings, qualified call resolution" and a v2.0 schema adding temporal columns (`valid_from_sha` / `valid_to_sha`). Auto-applies migration + backs up the pre-2.0 DB. Same tool surface; safer for production use as of mid-2026. <https://github.com/n24q02m/better-code-review-graph> `<certain>`

## Write-ups and blog posts

| Source | URL | What's in it | Useful for |
| --- | --- | --- | --- |
| Steven Gonsalvez — dev.to | <https://dev.to/stevengonsalvez/code-review-graph-stop-your-agent-reading-the-whole-repo-4272> | Intro framing + install. No new tool guidance beyond the README. | Background only. |
| Velvrix — Medium | <https://medium.com/@velvrix/how-i-set-up-code-review-graph-on-my-spring-boot-project-with-cursor-why-it-changed-how-i-review-ee799c55d77b> | Spring Boot + Cursor setup. Confirms `code-review-graph install --platform cursor` writes `.mcp.json` + injects `.cursorrules` + sets up auto-update hooks. Notes 5–10× token reduction. | Multi-platform install notes; not new API guidance. |
| Tirth Kanani (author) — LinkedIn | <https://www.linkedin.com/posts/tirthkanani_…> | Author's pitch: persistence across sessions ("graph survives where memory doesn't") and incremental updates < 2s on re-parse. | Mental model for *why* to call build at session start. |
| Hacker News thread | <https://news.ycombinator.com/item?id=47314090> | Benchmarks repeated, install pitfalls noted (one user filed install issues). | Skip — no new content. |
| Reddit r/ClaudeAI launch thread | <https://www.reddit.com/r/ClaudeAI/comments/1rp6pkr/> | Launch announcement: 35-repo benchmark, "5 structural questions = 412K tokens naive vs 3.4K via graph = 120× fewer". | Useful for skill description / motivation. |
| arXiv 2603.27277 — "Codebase-Memory" | <https://arxiv.org/html/2603.27277v1> | Academic paper on tree-sitter knowledge graphs for LLM code exploration via MCP. **Describes a different (14-tool) system**, not CRG — but the architectural framing (Indexing / Query / Analysis / Code tool categories) is a useful mental model. | Background on the category, not CRG-specific. |
| SpecterOps secure-review post | <https://specterops.io/blog/2026/03/26/leveling-up-secure-code-reviews-with-claude-code/> | Uses Claude Code for secure code review by tracing data flow. **Does not use CRG**, but the methodology (entry-point → method-by-method trace presented in one scrollable window) is exactly the "steel thread" pattern you're describing. Read it for *why* the pattern is valuable. | Vocabulary / framing. |

## What's *not* out there (saving you a search)

- **No public "steel thread" skill for CRG** as of fetch date (2026-05-11). The concept exists in agentic-engineering blogs (e.g., `agenticengineer.com/thinking-in-threads`) but that's about agent workflows, not CRG-specific concept tracing. `<certain>`
- **No public skill or write-up combines `semantic_search_nodes_tool` + `traverse_graph_tool` for fuzzy-concept tracing.** The 6 newer tools (hubs/bridges/gaps/surprising/suggested/traverse) shipped in a recent release and don't yet appear in third-party SKILL.md files. Your skill would be an early adopter. `<certain>`
- **No documented guidance on when to re-run `run_postprocess_tool`.** Inferred from CLI flag semantics (`--skip-postprocess` exists, so a paired re-run tool follows the same logic), but not stated in `docs/COMMANDS.md`. `<speculative>` — call it out as a caveat in your skill.

## Recommended sequencing patterns harvested from prior art

1. **Author's own sequence (from bundled `review-pr` skill, verbatim above)** — start with `get_docs_section_tool` for the relevant section, then build, then context, then impact, then deep dives. Use this as your skill's default backbone. `<certain>`
2. **Build → embed → search** — Velvrix's Spring Boot post and the README both treat semantic search as a separate phase that requires `embed_graph_tool` to have run. Don't assume embeddings exist. `<certain>`
3. **`get_minimal_context_tool` as router** — Context7's `llms.txt` example shows the response includes a `suggested_tools` array. The author's intent is that this tool routes the rest of the session. No public skill exploits this yet — it's a differentiator for your skill. `<speculative>` on intent; `<certain>` on response shape.
4. **Re-build at session start, not just on demand** — Tirth's own LinkedIn post argues the graph persists across sessions but the *cheap* incremental update should still run every session because git state may have moved. Your skill should always-rebuild before answering. `<certain>`

## Confidence cap on this file: **MEDIUM**

Reason: bundled-skill sequencing is `<certain>` (read directly from the repo). External write-ups confirm the install flow and motivation but add little new guidance. The 6 newer tools have only README-level documentation; no third-party patterns exist yet, so the "when to use" guidance for those is partially inferred from tool names + release notes.
