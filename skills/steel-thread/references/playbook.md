# Steel-thread playbook — worked examples

Each example shows the actual sequence: flows first, semantic search as
fallback, two-axis vocabulary, and the coverage caveat at the end.

## Example 1: "Find the steel thread of AI extractors"

**Phase 0** — `build_or_update_graph_tool` + `embed_graph_tool` if not done.

**Phase 1** — `get_minimal_context_tool(task="trace AI extractors end-to-end")`.
Read the `top_flows` and `top_communities` it returns. If a flow named
something like `extractDocument` or `TaxExtraction` appears, jump to Phase 2.

**Phase 2** — `list_flows_tool(sort_by="node_count", limit=30)`. Filter by
"extract", "ai", "document". For each hit:

```
get_flow_tool(flow_id=<id>, include_source=False)
```

If flows cover the thread, you're mostly done — render and stop.

**Phase 4 (fallback)** — If no flow matched, run two-axis semantic search.

Behaviour-axis queries:

```
"AI extractor extract structured data from document using LLM"
"extractor pipeline parse invoice receipt document"
"tax-api extractor classify categorize transaction"
"Anthropic Claude prompt schema zod extract"
```

These surface the dense legacy/domain cluster: `DocumentExtractionController`,
`DocumentExtractionService`, per-domain extractors in
`libs/platform/ai/src/application/extractors/`, Temporal activities, warden
mapping services.

Surface-axis queries:

```
"ai extractions endpoint route handler new POST"
"extractors route /ai/extractions register fastify endpoint"
"extractor controller register routes contract"
```

These surface the contract/route layer that behaviour queries miss —
including freshly-added stable API surfaces (e.g. `AiExtractorsContract` +
`registerExtractorRoutes`). If behaviour-axis results all cluster in one
directory and the user mentioned an API change, the surface axis is where
the new code lives.

**Cross-check** — `git log --author="<name>" --since="<window>" --oneline --
'*ai*' '*extract*'`. Commit messages name the new surface in plain English
even when your queries don't.

## Example 2: "What's the blast radius if I change function X?"

```
query_graph_tool(pattern="callers_of", target="X")    # direct callers
get_impact_radius_tool(changed_files=["<path/to/X>"], max_depth=2)
get_affected_flows_tool(changed_files=["<path/to/X>"])
```

Impact radius = structural blast at N hops. Affected flows = user-facing
scenarios that traverse it. If `get_hub_nodes_tool` lists X, drop `max_depth`
to 1 first — otherwise it'll hit `CRG_MAX_IMPACT_NODES=500` and truncate.

## Example 3: "Map the upload-and-process flow end-to-end"

Flows-first applies cleanly here:

1. `list_flows_tool(sort_by="node_count", kind="Function", limit=30)`.
2. Filter names for "upload", "process", "ingest". The longest matching flow
   is your spine.
3. `get_flow_tool(flow_id=<picked>, include_source=False)` — step-by-step.
4. For each step's file, `get_community_tool` of the containing community to
   see siblings that should plausibly participate.
5. `get_surprising_connections_tool` — anything appears that doesn't match
   the flow? That's a side thread (auth, validation, audit log).

## Example 4: "Is the new endpoint I just added in this steel thread?"

You almost certainly missed it on the first pass if you only queried
behaviour vocabulary. Two fixes:

1. **Always** run a surface-axis query when the user mentions recent work:
   route, endpoint, contract, controller, register, handler, POST/GET.
2. **Always** run `git log --author=<them> --since="<recent>" --oneline` to
   anchor the surface query vocabulary in real commit messages.
3. **Then** `detect_changes_tool(base="<their fork point>")` to confirm CRG
   sees the new code as changed.

If you missed it on the first pass, admit it and re-run. Don't paper over.

## Example 5: "Re-orient on a repo I haven't touched in months"

```
list_graph_stats_tool                                # is the graph still there?
get_architecture_overview_tool                       # community names + coupling
list_communities_tool(sort_by="size", min_size=5)    # filter out tiny clusters
get_hub_nodes_tool                                   # load-bearing symbols
get_bridge_nodes_tool                                # cross-community seams
generate_wiki_tool                                   # persist this orientation
```

## Example 6: "Review this PR"

Mirror CRG's bundled `review-pr` sequence:

```
get_docs_section_tool(section_name="review-pr")
build_or_update_graph_tool(base="main")
get_review_context_tool(base="main", include_source=True)
get_impact_radius_tool(base="main", max_depth=2)
# per-file deep dives:
query_graph_tool(pattern="callers_of", target="<changed symbol>")
semantic_search_nodes_tool(query="<concept>", kind="Function", limit=10)
get_suggested_questions_tool                          # seed reviewer follow-up
```

## Sequencing rules of thumb

- **Always** Phase 0 (build + embed) before Phase 1+ — unless the same
  session already did it and no commits have landed.
- **Always** `get_minimal_context_tool` next — it's the runtime router.
  Its `suggested_tools` array is the author's intended plan.
- **Always** `list_flows_tool` before traversal — CRG already did the work.
- **Always** Phase 6 (impact) when the user said "change", "refactor",
  "blast radius", "what would break", "what's affected".
- **Never** trust a semantic top-hit as an entry point without
  `query_graph_tool(pattern="callers_of", ...)` confirmation.
- **Never** report a complete map without naming the queries you ran.

## Output template

Every steel-thread map ends with the same shape. Don't omit sections — say
"none found" if a layer doesn't apply.

```markdown
## Steel thread: <concept> — end-to-end

### Entry point(s)
- **<surface>** — `<file:line>` — `<symbol>`
  - e.g. HTTP route, CLI command, Temporal workflow start, scheduled job
- **<legacy vs new>** — mark explicitly when both exist

### Workflow / orchestration
- `<file:line>` — `<symbol>` — what it does in one line
- (Temporal workflows, queue handlers, sagas)

### Domain / business logic
- `<file:line>` — `<symbol>` — one line
- (services, use-cases, aggregates)

### Infrastructure / persistence
- `<file:line>` — `<symbol>` — one line
- (repositories, external clients, DB schemas)

### Side threads (auth, validation, audit, feature flags)
- `<file:line>` — `<symbol>` — why it intersects
- Run `get_surprising_connections_tool` to populate this section.

### Coverage caveat
- **Queries run (verbatim):**
  - `list_flows_tool(sort_by="node_count", ...)`
  - `semantic_search_nodes_tool("<behaviour query>", kind="Function")`
  - `semantic_search_nodes_tool("<surface query>", kind="Function")`
  - `query_graph_tool(pattern="callers_of", target="<symbol>")`
  - `detect_changes_tool(base="<ref>")` (if applicable)
- **What would NOT have been surfaced:**
  - Threads whose names don't match the behaviour/surface vocabulary above.
  - Code added since `<commit-sha-from-Phase-0>` if Phase 0 was skipped.
  - Cross-language edges if the repo includes non-tree-sitter-parsed files.
- **Confidence:** `<HIGH | MEDIUM | LOW>` — one line of justification.
```

If you're rendering a steel thread without the **Coverage caveat** block,
you're overclaiming. The block is the whole point of the skill — it's how
the user knows what *not* to trust about the map.

## When to skip CRG entirely

- Single-symbol "who calls Z" with a known exact symbol → use the Serena MCP (`mcp__serena__find_referencing_symbols`).
- "Where is the file named X.ts" → use `/scout` (filesystem).
- Dead code or unwired spec → use `/ghostbuster`.
- The graph DB is missing or stale and the question is genuinely tiny → just
  read the file.
