# Preamble — MCP tool routing

This project provides three MCP servers that supersede built-in file tools for different shapes of work. Use the right one — built-ins are last-resort.

## Routing rules

| Question shape | MCP | Example tools |
|---|---|---|
| Read / list / search / edit any file | **tilth** (default) | `tilth_read`, `tilth_search`, `tilth_list`, `tilth_write` |
| Symbol-level read or edit on code | **Serena** | `find_symbol`, `find_referencing_symbols`, `replace_symbol_body`, `rename_symbol` |
| Graph-level analysis on code | **code-review-graph** | `get_impact_radius_tool`, `get_review_context_tool`, `get_architecture_overview_tool`, `semantic_search_nodes_tool` |

Built-in `Read` / `Edit` / `Write` / `Glob` / `Grep` are acceptable only when:

- The file is outside the workspace.
- No MCP server can parse the file (binaries, malformed code).
- A regex search across many files doesn't fit any MCP equivalent — and even then, follow-up reads/edits on matched code files go back through the right MCP.

The `cheez-search` / `cheez-read` / `cheez-write` skills route through tilth — use them instead of host `Read` / `Edit` / `Write` / `Grep` whenever they're available.

## Serena mapping (symbol-level)

| Task | Tool |
|---|---|
| See a file's structure | `get_symbols_overview` |
| Read a specific symbol's body | `find_symbol` (`include_body=true`) |
| Find a symbol by name | `find_symbol` |
| Find references / callers | `find_referencing_symbols` |
| Find declarations / implementations | `find_declaration` / `find_implementations` |
| Edit a symbol's body | `replace_symbol_body` |
| Insert near a symbol | `insert_before_symbol` / `insert_after_symbol` |
| Pattern replace inside a file | `replace_content` |
| Rename a symbol | `rename_symbol` |
| Safe-delete a symbol | `safe_delete_symbol` |

## code-review-graph mapping (graph-level)

| Task | Tool |
|---|---|
| Build / refresh the graph for a repo | `build_or_update_graph_tool` |
| One-call review context for a change | `get_review_context_tool` |
| Detect what changed since last build | `detect_changes_tool` |
| Trace blast radius of a symbol or file | `get_impact_radius_tool` |
| Which user-facing flows a change touches | `get_affected_flows_tool` |
| High-level architecture summary | `get_architecture_overview_tool` |
| Hub / bridge nodes (critical nodes) | `get_hub_nodes_tool` / `get_bridge_nodes_tool` |
| Suspicious size or shape | `find_large_functions_tool` |
| Modular subgraphs | `list_communities_tool` / `get_community_tool` |
| Semantic (embedding) search across nodes | `semantic_search_nodes_tool` |
| Minimal context for a question | `get_minimal_context_tool` |
| Knowledge gaps for review | `get_knowledge_gaps_tool` |

Reach for code-review-graph first when reviewing a change, planning a multi-file edit, or answering "what does this actually affect."

## Workflow before editing code

1. **Scope it** — for changes that touch multiple files or for review work, start with `get_review_context_tool` or `get_impact_radius_tool`.
2. **Read the symbol** — `get_symbols_overview` on the target file (skip if done this session), then `find_symbol` with `include_body=true` for the specific symbol.
3. **Edit** — Serena `replace_symbol_body` / `insert_before_symbol` / `insert_after_symbol` / `replace_content` for symbol-anchored edits; `tilth_write` for whole-file rewrites or non-code files.

## Routing self-check

Before each tool call, ask: "What's the shape of the question?"

- Symbol-level read or edit → **Serena**
- File-level read, search, or edit → **tilth**
- Graph-level analysis (impact, architecture, flows) → **code-review-graph**

If unsure, pick the smallest-scope tool that can answer the question. Don't rationalize built-ins with "the file is small" or "I already know the path" — those rationalizations have produced incorrect behavior before.
