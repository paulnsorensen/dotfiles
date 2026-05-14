# code-review-graph (CRG) — MCP API surface

Reference for a Claude Code skill that wraps `code-review-graph` (a.k.a. `crg`, `tirth8205/code-review-graph` on GitHub, `code-review-graph` on PyPI).

- **Repo**: <https://github.com/tirth8205/code-review-graph>
- **Docs (canonical for tool params)**: `docs/COMMANDS.md` in the repo
- **PyPI**: <https://pypi.org/project/code-review-graph/>
- **Tool count**: 28 as of v2.x (README confirms; 22 in earlier releases — the 6 added later are the hubs/bridges/gaps/surprising/suggested/traverse cluster).
- **Confidence cap**: `<certain>` on every signature in this file — verified against the live MCP schemas via Claude Code's `ToolSearch` on 2026-05-11. Context7 (`/tirth8205/code-review-graph`) corroborated the older tools but does not yet index the 6 newer ones, so the MCP server itself is the only canonical source for those. Behavioural descriptions (what each tool *does* on its inputs) are paraphrased from the MCP schema descriptions and the CRG `docs/FEATURES.md` page — high confidence on the tools' purposes, medium confidence on edge-case semantics.

---

## Phase 1 — Graph lifecycle (build → embed → postprocess → stats)

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `build_or_update_graph_tool` | Build or incrementally update the SQLite graph from tree-sitter parse. | `full_rebuild: bool=False`, `repo_root: str?`, `base: str="HEAD~1"`, `postprocess: "full"\|"minimal"\|"none"` | **Always call first** at the start of any session that touches recent code. Use `full_rebuild=True` only after major refactors or after pulling a long-lived branch; otherwise incremental is < 2s on a 2,900-file repo. | Schema migrated in v2.0 (adds `valid_from_sha`/`valid_to_sha` temporal columns); auto-applies + backs up DB to `<graph_db>.pre-2.0.bak`. If `postprocess="none"` is used for speed, flows/communities/hubs become stale — callers must explicitly `run_postprocess_tool` later. |
| `embed_graph_tool` | Compute vector embeddings for nodes so `semantic_search_nodes_tool` works. | `repo_root: str?`, `model: str?` (falls back to `CRG_EMBEDDING_MODEL` env). | Only required before semantic search. Skip when you only need structural queries (callers/callees/imports). Re-run after a full rebuild *if* you want the new nodes searchable. | Requires the `[embeddings]` extra (`pip install code-review-graph[embeddings]`) — server returns a clear error if missing. Slow on large repos; budget separately from build. |
| `run_postprocess_tool` | Run post-processing (flow detection, community detection, FTS index) on the existing graph. Signatures are always computed regardless of these flags. | `flows: bool=True`, `communities: bool=True`, `fts: bool=True`, `repo_root: str?`. `<certain>` (verified against live MCP schema 2026-05-11.) | Reach for it after a `build` with `postprocess="none"`/`"minimal"`, or when flows/communities feel stale after many incremental updates. Set the flags to `False` individually to skip a specific computation. | Hub/bridge computation isn't gated by this tool — those are computed on demand by `get_hub_nodes_tool` / `get_bridge_nodes_tool`. Earlier briesearch claimed the params were `no_flows`/`no_communities` (inverted polarity) — that was wrong. |
| `list_graph_stats_tool` | Graph size + health (node/edge counts per kind, last build time). | `repo_root: str?` | Cheap sanity check after build. Use it to verify the graph isn't empty (parse silently dropped all files) before trusting any other query. | None notable. |

**Recommended sequence for a fresh session on recent code:** `build_or_update_graph_tool` → `list_graph_stats_tool` (sanity) → `embed_graph_tool` (if semantic search will be used) → analysis tools. After a `--skip-postprocess` build, also call `run_postprocess_tool` before flows/communities/hubs.

---

## Phase 2 — Search & traversal (entry points into the graph)

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `get_minimal_context_tool` | Ultra-compact context (~100 tokens) summarising current change + suggested next tools. | `task: str = ""` (optional but recommended — e.g. `"review PR #42"`, `"debug login timeout"`), `base: str="HEAD~1"`, `changed_files: list[str]?`, `repo_root: str?`. `<certain>` (verified against live MCP schema.) | **Always call this immediately after `build_or_update_graph_tool`** at the top of a task. Returns graph stats, `risk` score, `top_communities`, `top_flows`, `suggested_tools` — use the array to plan the rest of the session. | `task` is optional with empty default — pass it anyway, the router uses it. |
| `semantic_search_nodes_tool` | Embedding-backed search by name or meaning. | `query: str`, `kind: "File"\|"Class"\|"Function"\|"Type"\|"Test"`, `limit: int=20`, `model: str?` | First reach for fuzzy concept ("user authentication", "order tax calc") when you don't know the symbol name. Pair with `kind="Function"` or `"Class"` to narrow. | Requires embeddings (`embed_graph_tool`) to have run. Falls back to text-only if missing — silently degraded quality. |
| `query_graph_tool` | Predefined structural queries. | `pattern: "callers_of"\|"callees_of"\|"imports_of"\|"importers_of"\|"children_of"\|"tests_for"\|"inheritors_of"\|"file_summary"`, `target: str` | Use when you already have a symbol or file path and want exact relationships. Faster + more precise than `traverse_graph_tool` for one-hop questions. | `target` accepts node name, qualified name (`MyClass.my_method`), or file path. Qualified names disambiguate when names collide. |
| `traverse_graph_tool` | BFS/DFS from the **best-matching node for a query string** (semantic-anchored) with a token budget. | `query: str` (required — finds the start node), `depth: int=3` (max 6), `mode: "bfs"\|"dfs"` (default `"bfs"`), `token_budget: int=2000`, `repo_root: str?`. `<certain>` (verified against live MCP schema.) | Reach for it when one-hop `query_graph_tool` isn't enough — e.g. tracing a "steel thread" from an entry point through multiple layers. The token budget is the differentiator: it stops expanding when it would blow context. | **There is no `start_node` or `direction` param.** Earlier briesearch claim was wrong. The starting node is *found* via semantic match on `query`; inspect `start_node` in the response and re-query if CRG picked the wrong seed. Max depth is hard-capped at 6 (different from `CRG_MAX_BFS_DEPTH=15`, which gates flow tracing). |
| `find_large_functions_tool` | Find functions/classes exceeding a line-count threshold. | `min_lines: int=50`, `kind`, `file_path_pattern: str?`, `limit: int=50` | Refactoring triage; not for steel-thread tracing. Useful for `get_knowledge_gaps_tool` follow-up. | None notable. |

**Steel-thread tracing pattern (flows-first)**: `list_flows_tool` (Phase 3) is the primary call — CRG already discovered the steel threads. Only fall back to `semantic_search_nodes_tool(query="<concept>", kind="Function")` → `query_graph_tool(pattern="callers_of"|"callees_of", target=<symbol>)` for one-hop precision, or `traverse_graph_tool(query="<concept>", mode="bfs", depth=…, token_budget=…)` for multi-hop fan-out, when no flow matches. See `playbook.md` for worked examples and SKILL.md for the canonical sequence.

---

## Phase 3 — Execution flows (CRG's native "steel threads")

CRG's `Flow` concept *is* the steel-thread abstraction. Use these instead of hand-rolling traversals when possible.

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `list_flows_tool` | List execution flows sorted by criticality. | `sort_by: "criticality"\|"depth"\|"node_count"\|"file_count"\|"name"`, `limit: int=50`, `kind: str?`, `repo_root: str?` | Reach here first when the user asks "trace X through the architecture". Flows are pre-computed via flow detection in postprocess — cheaper than reconstructing from `traverse_graph_tool`. | Becomes stale after big builds without postprocess. Re-run `run_postprocess_tool` if `list_graph_stats_tool` shows new code but flow count hasn't changed. |
| `get_flow_tool` | Detail of one flow. | `flow_id: int?` (from `list_flows_tool`), `flow_name: str?` (partial match), `include_source: bool=False` | Use after `list_flows_tool` to drill into a chosen flow. `include_source=True` when the next step is reading the actual functions; `False` for structural summary only. | Pick exactly one of `flow_id` or `flow_name`. Name match is partial — disambiguate with `flow_id` if multiple hits. |
| `get_affected_flows_tool` | Flows impacted by a set of changed files. | `changed_files: list[str]?` (auto-detected from git), `base: str="HEAD~1"`, `repo_root: str?` | The blast-radius equivalent for flows: "which user-facing scenarios break if I touch these files?". Pair with `get_impact_radius_tool` (file-level) for full picture. | Auto-detects via `git diff base..HEAD`; pass explicit `changed_files` for hypothetical/planned changes. |

---

## Phase 4 — Communities & architecture (codebase-shape view)

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `list_communities_tool` | List Leiden-clustered communities. | `sort_by: "size"\|"cohesion"\|"name"="size"`, `min_size: int=0`, `repo_root: str?` | Use for "give me the shape of this codebase" or as a triage step before deep dives. | Recomputed by postprocess; stale after `--skip-postprocess` builds. |
| `get_community_tool` | One community's detail. | `community_name: str?` (partial), `community_id: int?`, `include_members: bool=False`, `repo_root: str?` | Use after `list_communities_tool` to dive into one cluster. Set `include_members=True` only when you need the full node list — large communities can be hundreds of nodes. | Either name or id; not both. |
| `get_architecture_overview_tool` | High-level architecture diagram derived from community structure. | `repo_root: str?` | Reach for it at session start as orientation, OR when generating onboarding docs. Cheaper than reading every community. | One-shot; no incremental updates within a session. |
| `get_hub_nodes_tool` | Most-connected nodes (total in+out degree) — architectural hotspots. | `top_n: int=10`, `repo_root: str?`. `<certain>` (verified.) | Use to prioritise review when blast radius is large: hubs are the "if this breaks, everything breaks" set. | **Automatically excludes File nodes** (built-in, not a param). There is no `exclude_tests` flag — earlier briesearch claim was wrong. |
| `get_bridge_nodes_tool` | Chokepoints via betweenness centrality. | `top_n: int=10`, `repo_root: str?`. `<certain>` (verified.) | Use to identify coupling risks: bridges are nodes that, if removed, partition the graph. Different from hubs — a bridge can have low degree but high betweenness. | Uses sampling approximation for graphs > 5000 nodes (auto, not configurable). |

---

## Phase 5 — Change-aware (the core CRG value prop)

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `detect_changes_tool` | Primary code-review tool: maps git diff to affected functions, flows, communities, test gaps; returns risk scores. | `base: str="HEAD~1"`, `changed_files: list[str]?`, `include_source: bool=False`, `max_depth: int=2`, `repo_root: str?` | **Use as the primary entry point for any "review this PR / commit" task.** Subsumes much of what `get_impact_radius_tool` + `get_affected_flows_tool` do, with risk scoring. | `include_source=False` by default — flip to `True` if the next step is writing review comments referencing code. |
| `get_impact_radius_tool` | Blast radius of changed files (file-level). | `changed_files: list[str]?`, `max_depth: int=2`, `base: str="HEAD~1"`, `repo_root: str?` | Use when you want raw blast radius without the risk scoring overhead. Pair with `get_affected_flows_tool` for the flow-level view. | Capped by `CRG_MAX_IMPACT_NODES=500` and `CRG_MAX_IMPACT_DEPTH=2`. Raise via env if cap-truncated. |
| `get_review_context_tool` | Token-optimised review context (changed files + dependents + source snippets). | `changed_files: list[str]?`, `max_depth: int=2`, `include_source: bool=True`, `max_lines_per_file: int=200`, `base: str="HEAD~1"` | Reach for it when you need the actual code + structural summary in one call to hand to an LLM for review. | Default `include_source=True` (opposite of `detect_changes_tool`). Cap `max_lines_per_file` aggressively on large files. |
| `get_suggested_questions_tool` | Auto-generated review questions from graph analysis. Covers: bridge nodes needing tests, untested hubs, surprising cross-community coupling, thin communities, untested hotspots. | `repo_root: str?` only. `<certain>` (verified.) | Use as a session-end nudge: "what should I ask about this change?". Good for prompting reviewer follow-up. | No `focus_area` param exists (earlier briesearch claim wrong). Output quality depends on community/flow freshness. |
| `get_knowledge_gaps_tool` | Identify structural weaknesses: isolated nodes (disconnected), thin communities (< 3 members), untested hotspots (high-degree nodes without tests), single-file communities. | `repo_root: str?` only. `<certain>` (verified.) | Use during refactoring planning or onboarding: "what's poorly tested or weakly connected?". | No `gap_type` param (earlier briesearch claim wrong). Stale after `--skip-postprocess` builds. |
| `get_surprising_connections_tool` | Unexpected coupling, scored by composite: cross-community (+0.3), cross-language (+0.2), peripheral-to-hub (+0.2), cross-test-boundary (+0.15), unusual edge kinds (+0.15). | `top_n: int=15`, `repo_root: str?`. `<certain>` (verified.) | Use during architecture review or before a planned extraction: surfaces dependencies that violate intended layering. | No `threshold` param (earlier briesearch claim wrong) — scoring is internal. Output is heuristic; present with a caveat. |

---

## Phase 6 — Refactor

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `refactor_tool` | Plan a refactor: rename preview, dead code detection, or suggestions. | `mode: "rename"\|"dead_code"\|"suggest"="rename"`, `old_name: str?`, `new_name: str?`, `kind: str?`, `file_pattern: str?`, `repo_root: str?` | Use *before* doing any edits: `mode="rename"` previews call sites; `mode="dead_code"` lists removable symbols; `mode="suggest"` is the broadest. | Returns a `refactor_id` that feeds into `apply_refactor_tool`. Don't edit files manually after preview — re-run preview after each edit batch. |
| `apply_refactor_tool` | Apply a previously previewed refactor. | `refactor_id: str` (required), `repo_root: str?` | Use only after reviewing the `refactor_tool` preview output. | Writes to the filesystem. Treat as destructive — verify diff after. |

---

## Phase 7 — Multi-repo

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `list_repos_tool` | List registered repos in the multi-repo registry. | (none) | Use at session start when you suspect the user is working across multiple repos. | Empty result is common — registry is opt-in via `crg register`. |
| `cross_repo_search_tool` | Search across all registered repos. | `query: str`, `kind: str?`, `limit: int=20` | Use for org-wide queries ("where is `OrderTaxCalculator` used across services?"). | Each repo must have been built + embedded individually first. |

---

## Phase 8 — Wiki / docs

| Tool | What it does | Key params | When to reach for it vs alternatives | Gotchas |
| --- | --- | --- | --- | --- |
| `generate_wiki_tool` | Generate or regenerate markdown wiki pages from communities. | `repo_root: str?`, `force: bool=False` | One-time generation per major build. Use for onboarding docs. | `force=True` regenerates even unchanged pages — expensive on large repos. |
| `get_wiki_page_tool` | Retrieve one wiki page. | `community_name: str` (required), `repo_root: str?` | Cheap lookup after generation; use as documentation lookup during reviews. | Lookup by community name only. |
| `get_docs_section_tool` | Retrieve a CRG documentation section. | `section_name: "usage"\|"review-delta"\|"review-pr"\|"commands"\|"legal"\|"watch"\|"embeddings"\|"languages"\|"troubleshooting"` (required) | Use sparingly — this is CRG's own docs, not the user's code. Useful for "how do I configure embeddings?" | Hard-coded section enum; unknown names error out. |

---

## MCP Prompts (workflow templates) — 5 total

These are pre-built prompt templates exposed via MCP, useful as scaffolds when designing the skill's slash commands:

| Prompt | Purpose |
| --- | --- |
| `review_changes` | Structured code review with blast-radius analysis |
| `architecture_map` | System-design overview + coupling analysis |
| `debug_issue` | Trace execution flows + identify root causes |
| `onboard_developer` | Generate architecture + community docs |
| `pre_merge_check` | Risk assessment before merging a PR |

---

## Environment variables worth knowing

| Var | Default | Purpose |
| --- | --- | --- |
| `CRG_PARSE_WORKERS` | `min(cpu_count, 8)` | Parallel parse worker count |
| `CRG_SERIAL_PARSE` | `""` | Set to `1` to disable parallel parsing |
| `CRG_MAX_IMPACT_NODES` | `500` | Cap on impact-radius result size |
| `CRG_MAX_IMPACT_DEPTH` | `2` | Max BFS depth for impact |
| `CRG_MAX_BFS_DEPTH` | `15` | Max BFS depth for flow tracing |
| `CRG_MAX_SEARCH_RESULTS` | `20` | Default search result cap |
| `CRG_BFS_ENGINE` | `sql` | `sql` or `networkx` for impact BFS |
| `CRG_DEPENDENT_HOPS` | `2` | N-hop dependent discovery depth |
| `CRG_EMBEDDING_MODEL` | (none) | Default embedding model name |

Raise `CRG_MAX_IMPACT_NODES` / `_DEPTH` for deep blast-radius questions on small repos; lower them on monorepos to avoid timeouts.

---

## Sequencing patterns

### Session start (always)

1. `build_or_update_graph_tool` (incremental — cheap).
2. `list_graph_stats_tool` (sanity).
3. `get_minimal_context_tool(task="<user's ask>")` → use `suggested_tools` to route.

### "Trace concept X end-to-end" (steel thread)

1. `list_flows_tool(sort_by="node_count")` → does CRG already have a flow for X? (Backend threads bury under `sort_by="criticality"`.)
2. If yes: `get_flow_tool(flow_id=…, include_source=False)` → structural first, then `include_source=True` only if you need the code.
3. If no flow matches: `semantic_search_nodes_tool(query="X", kind="Function")` → candidate entry points (two-axis: behaviour + surface vocab).
4. `query_graph_tool(pattern="callers_of", target=<symbol>)` to confirm entry-point status, or `pattern="callees_of"` for one-hop downstream.
5. `traverse_graph_tool(query="<concept or symbol>", mode="bfs", depth=3, token_budget=3000)` when one-hop isn't enough. The tool finds its own start node from `query` — inspect `start_node` in the response and re-query if it picked the wrong seed.

### "Impact of planned change to file Y"

1. `get_impact_radius_tool(changed_files=["Y"])` for file blast radius.
2. `get_affected_flows_tool(changed_files=["Y"])` for flow blast radius.
3. `get_hub_nodes_tool` if Y appears in the result — flags high-risk dependents.

### "Review this PR"

1. `detect_changes_tool(base="main")` (handles diff + risk + flows in one shot).
2. `get_review_context_tool(base="main", include_source=True)` for code-level snippets.
3. `get_suggested_questions_tool` to seed reviewer follow-up.

### After a `--skip-postprocess` build

- Run `run_postprocess_tool` before any flow/community/hub/bridge call, OR accept stale data with a caveat.
