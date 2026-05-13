---
name: steel-thread
model: opus
effort: high
allowed-tools: Read, Bash(git log:*), Bash(git diff:*), Bash(git status:*), Bash(ls:*), Bash(rg:*), Agent, Skill
description: >
  Map a concept end-to-end through a layered codebase using the code-review-graph
  (CRG) MCP. Always rebuilds and re-embeds the graph before answering so
  semantic search reflects current code. Prefers CRG's native `Flow` primitive
  (which IS a steel thread) over hand-rolled traversal. Queries along both
  behaviour and surface vocabularies when no flow matches, traverses from the
  densest hub, cross-checks with impact radius, and routes via
  `get_minimal_context_tool`'s `suggested_tools` array. Use when the user asks
  to trace a concept, find an entry point, map a feature across layers,
  estimate blast radius of a planned change, find which contract/route/handler
  reaches a given service, or asks "did you check whether I just added X".
  Triggers on: /steel-thread, "trace this through", "map the X flow", "blast
  radius for Y", "what touches Z", "find the entry point for", "where does X
  get called from", "is there a new endpoint I added", "what's affected by
  this change". Do NOT use for single-symbol lookups (use /lookup), filesystem
  search (use /scout), or dead code detection (use /ghostbuster).
license: MIT
---

# /steel-thread

Trace a concept from entry point through every layer of the architecture using
CRG. Prefer CRG's pre-computed `Flow` primitive — it *is* a steel thread, by
CRG's own definition. Fall back to fuzzy → precise only when no flow matches.

**Target**: $ARGUMENTS — a concept ("ai extractors"), a model ("Invoice"), a
feature ("draft email preview"), a change ("the PR I just opened"), or a
question ("what's the blast radius if I change this function").

## Hard rules

1. **Re-build + re-embed before querying** unless the graph was rebuilt this
   session AND no commits have landed since. New code without an embedding is
   invisible to semantic search and you will confidently miss it.
2. **Flows first.** A CRG `Flow` is the pre-computed steel thread. Always
   `list_flows_tool` before reaching for `traverse_graph_tool` or
   `semantic_search_nodes_tool`. Only fall back when no flow matches the
   concept.
3. **Let `get_minimal_context_tool` route the session.** It returns
   `top_communities`, `top_flows`, and a `suggested_tools` array. Trust that
   array over your own guess about what to call next.
4. **Query along two axes** when falling back to semantic search. Embeddings
   cluster by both behaviour and surface vocabulary. Run at least one query
   for each:
   - **Behaviour:** what the code *does* — domain verbs, model names, business
     concepts.
   - **Surface:** how the code is *reached* — routes, contracts, endpoints,
     adapters, handlers, repositories.
   Disjoint result sets reveal new layers, parallel rewrites, or contract
   surfaces the user just added.
5. **Pair every semantic hit with a precise relationship query** before
   claiming it's the entry point. Use `query_graph_tool` with `callers_of`,
   `callees_of`, `imports_of`, `importers_of`, `children_of`, `tests_for`,
   `inheritors_of`, or `file_summary`. Semantic search ranks by similarity,
   not by being-the-root-of-a-call-tree.
6. **State coverage explicitly.** End every steel-thread map with a one-line
   caveat naming the queries you ran and what would not have been surfaced.
7. **Test names beat function names as anchors.** When triangulating, weight
   test-name hits — they describe the contract crisply.

## Flow

### Phase 0 — Freshen the graph

```
build_or_update_graph_tool(base="HEAD~1")            # incremental, ~2s on 2900-file repo
list_graph_stats_tool                                # sanity-check non-empty
embed_graph_tool                                     # only if semantic search will be used
```

Skip only if **all** of the following hold:

- Graph was built+embedded earlier in this session.
- `git log -1 --format=%H` matches what you saw last.
- `git status --porcelain` is empty (no uncommitted edits — CRG only sees
  what's on disk, but uncommitted edits in the user's branch are exactly
  what the question is often *about*).

If `summary` from `build_or_update_graph_tool` reports >50 files changed, do
`full_rebuild=True`. If you used `postprocess="none"` or `"minimal"`, follow
with `run_postprocess_tool` before any flow/community/hub call.

### Phase 1 — Route via `get_minimal_context_tool`

```
get_minimal_context_tool(task="<the user's actual question>", base="HEAD~1")
```

Returns `top_communities`, `top_flows`, `risk`, and a `suggested_tools` array.
**The `suggested_tools` array IS your plan.** Run those before reaching for
anything else. If the response includes top_flows that match the concept, jump
straight to Phase 2.

### Phase 2 — Flows first (CRG's native steel thread)

```
list_flows_tool(sort_by="node_count", limit=30, detail_level="minimal")
```

Filter flow names against the concept. For backend threads, **sort by
`node_count`, not the default `criticality`** — criticality biases toward
frontend roots (App, Login, etc.) and buries backend threads.

If a flow matches:

```
get_flow_tool(flow_id=<id>, include_source=False)    # structural summary first
get_flow_tool(flow_id=<id>, include_source=True)     # only when reading actual code
```

If no flow matches, the concept is either (a) too new for postprocess to have
discovered, (b) cross-cutting (auth, logging, validation) and not a single
chain, or (c) inside one community rather than spanning layers. Continue to
Phase 3.

### Phase 3 — Communities (when flows didn't match)

```
list_communities_tool(sort_by="size")
get_community_tool(community_name="<topic>", include_members=False)
```

A steel thread that isn't a flow is usually one community. Set
`include_members=True` only after narrowing — large communities can be
hundreds of nodes.

### Phase 4 — Two-axis semantic search (fallback)

```
semantic_search_nodes_tool(query="<behaviour verbs>", kind="Function", limit=15)
semantic_search_nodes_tool(query="<surface vocab>",   kind="Function", limit=15)
```

Compare top hits. Overlap = core of the thread. Disjoint = legacy + new
contract pair (or two parallel implementations).

Optional: also run with `kind="Test"` — test names are often crisper anchors
than implementation names.

### Phase 5 — Drill in from the anchor

Pick the best-anchored symbol from Phase 4. Then:

```
query_graph_tool(pattern="callers_of",   target="<symbol>")
query_graph_tool(pattern="callees_of",   target="<symbol>")
query_graph_tool(pattern="file_summary", target="<file>")
```

For wider exploration with a token budget. The tool finds its own start node
via semantic match on `query`:

```
traverse_graph_tool(query="<concept or symbol>", mode="bfs", depth=3, token_budget=3000)
```

Inspect `start_node` in the response — if CRG picked the wrong seed, re-query
with a more specific string. Max `depth` is hard-capped at 6 (different from
`CRG_MAX_BFS_DEPTH=15`, which gates flow tracing only).

For hubs (when the thread crosses load-bearing nodes):

```
get_hub_nodes_tool                                   # global hubs
get_bridge_nodes_tool                                # cross-community seams
```

### Phase 6 — Impact estimation (planned-change mode)

When the user is asking about blast radius:

```
get_impact_radius_tool(changed_files=["<paths>"], max_depth=2)
get_affected_flows_tool(changed_files=["<paths>"])
```

If the user asks about "recent" or "what did I add", use change-aware mode:

```
detect_changes_tool(base="<ref>", detail_level="standard")
get_affected_flows_tool(base="<ref>")
get_review_context_tool(base="<ref>", include_source=True, max_lines_per_file=200)
```

Always cross-reference with `git log --author=<user> --since="<window>"
--oneline` — CRG is structural; git is authoritative for *who* and *when*.

Caps to know:

- `CRG_MAX_IMPACT_NODES=500`, `CRG_MAX_IMPACT_DEPTH=2`, `CRG_MAX_BFS_DEPTH=15`.
  Raise via env if results truncate; lower on monorepos to avoid timeouts.

### Phase 7 — Architectural sanity-check

```
get_architecture_overview_tool                       # community map + coupling warnings
get_surprising_connections_tool                      # non-obvious cross-cutting edges
```

`get_surprising_connections_tool` catches what topical search would never
find. Run it once at the end of any steel-thread map to confirm you didn't
miss a side-thread (audit log, feature flag, validation pipeline).

### Phase 8 — Render the map

Output a top-down ASCII diagram from entry point → workflow → domain →
infrastructure. For each layer:

- Name the file(s) and the key symbol(s).
- Mark legacy vs new surfaces explicitly when both exist.
- Note any side threads (alternative paths, validators, grounding checks).
- Close with the coverage caveat: "Queries run: A, B, C. Threads not matching
  those vocabularies won't appear here."

## Canonical sequences

### Steel-thread trace (the default)

```
build_or_update_graph_tool → list_graph_stats_tool → embed_graph_tool
  → get_minimal_context_tool(task="<concept>")
  → list_flows_tool(sort_by="node_count") + filter by concept
  → get_flow_tool(flow_id=<best match>, include_source=False)
  → render
```

### "Blast radius if I change X"

```
build_or_update_graph_tool
  → query_graph_tool(pattern="callers_of", target="X")
  → get_impact_radius_tool(changed_files=["<X's file>"])
  → get_affected_flows_tool(changed_files=["<X's file>"])
```

### "What did I just add" / "review this PR"

Mirrors CRG's bundled `review-pr` skill (verbatim):

```
get_docs_section_tool(section_name="review-pr")      # CRG's own docs
  → build_or_update_graph_tool(base="main")
  → get_review_context_tool(base="main")
  → get_impact_radius_tool(base="main")
  → per-file: query_graph_tool + semantic_search_nodes_tool
```

### "Re-orient on a repo I haven't touched in months"

```
list_graph_stats_tool → get_architecture_overview_tool → list_communities_tool
  → get_hub_nodes_tool + get_bridge_nodes_tool
  → generate_wiki_tool                               # persist for future sessions
```

## Anti-patterns

- **Skipping `list_flows_tool` and going straight to traversal.** CRG already
  computed the steel threads during postprocess — don't reconstruct them.
- **`sort_by="criticality"` on `list_flows_tool`.** Buries backend threads
  under frontend roots. Use `node_count` for backend mapping.
- **Single-axis semantic query.** If every top hit lives in one directory,
  you over-fit the embedding cluster. Broaden vocabulary or switch axes.
- **Trusting an old embedding.** If you didn't run Phase 0, you're answering
  about yesterday's repo.
- **Treating semantic top-hit as entry point.** Always confirm via
  `query_graph_tool(pattern="callers_of", ...)`.
- **Reporting completeness when only one axis was queried.** Be explicit about
  what your queries could not have surfaced.
- **Ignoring `suggested_tools` from `get_minimal_context_tool`.** It's the
  author's intended router. Use it.
- **User mentioned recent work and you didn't run `detect_changes_tool`.**
  Semantic search over an embedding that predates the work is the canonical
  way to confidently miss what they just added. Composite of (a) skipping
  Phase 0 and (c) trusting semantic top-hit. If the user said "I just added
  X", "did you check whether I added Y", "the PR I just opened", or "recent",
  `detect_changes_tool(base="<their fork point>")` is non-optional.

## MCP Prompts (workflow scaffolds)

CRG exposes five MCP prompts that pre-compose tool sequences. Worth knowing
when designing higher-level workflows:

- `review_changes` — structured code review with blast-radius analysis.
- `architecture_map` — system-design overview + coupling analysis.
- `debug_issue` — trace execution flows + identify root causes.
- `onboard_developer` — generate architecture + community docs.
- `pre_merge_check` — risk assessment before merging a PR.

If the user's question fits one of these scaffolds, invoke the prompt rather
than hand-composing.

## Outputs to disk

`generate_wiki_tool` writes `.code-review-graph/wiki/*.md` — one page per
community. Worth running once per repo to persist orientation across sessions.
Regenerate after major refactors or community-shifting changes (or use
`force=True`).

## Caveat on tool surface

CRG v2.x has 28 MCP tools. All signatures referenced in this skill have been
verified against the live MCP schemas via Claude Code's `ToolSearch` on
2026-05-11. Context7 (`/tirth8205/code-review-graph`) corroborates the older
tools but does not yet index the 6 newer ones (`traverse_graph_tool`,
`get_hub_nodes_tool`, `get_bridge_nodes_tool`,
`get_surprising_connections_tool`, `get_suggested_questions_tool`,
`get_knowledge_gaps_tool`) — the MCP server is canonical for those. If a call
errors with `InputValidationError`, re-load the schema via `ToolSearch` and
update this skill.

## References

- `references/api.md` — per-tool reference: schemas, params, gotchas,
  sequencing. Confidence cap HIGH on documented tools, MEDIUM on the 6 newer
  ones.
- `references/playbook.md` — two-axis search recipe with worked examples
  (AI extractors trace, blast radius, "find what I just added").
- `references/external-prior-art.md` — bundled CRG skills, marketplaces,
  forks, blog posts, and the verbatim canonical `review-pr` sequence.

## See also

- `/xray` — design verification via dependency graph. Uses `sg`/ast-grep, not
  CRG. Complementary: `/xray` for *did this implementation satisfy the spec*;
  `/steel-thread` for *where does this concept actually live and what touches
  it*.
- `/lookup` — single-symbol code intelligence. Faster for "what's the
  signature of Y" or "who calls Z" when you already have the exact symbol.
- `/ghostbuster` — dead code / stale spec detection. Disjoint concern.
- `/briesearch` — for researching the external CRG API surface or new
  releases when this skill's `references/api.md` falls behind.
