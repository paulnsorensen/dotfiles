# MCP schema loading: the per-harness token tax

The `harnesses` field on an `agents/mcp/registry.yaml` entry is not just a
*compatibility* lever (does this MCP make sense here) — it is a **per-request
token-budget** lever. The reason is that harnesses differ in *when* they send
an MCP server's tool schemas to the model.

## The split: Claude defers; Codex, Cursor, and Copilot eager-load

Measured and sourced in the 2026-06 research artifact under
`.cheese/research/mcp-schema-loading/`:

| Harness | MCP tool-schema loading | Consequence |
|---|---|---|
| **Claude Code** | **Lazy / deferred by default** since v2.1.x (2026-01-14). Only tool *names* enter context at session start; full JSON schemas fetched on demand via `ToolSearch`. `ENABLE_TOOL_SEARCH` controls it (`true`/`false`/`auto`/`auto:N`); `alwaysLoad: true` opts a server out. Disabled on Vertex / non-first-party `ANTHROPIC_BASE_URL`. | A big MCP set costs ~names-only until used (~85% schema-token cut). |
| **Codex CLI** | **Eager** — lazy load is an open FR (#9266, #14507), unshipped. | Full schema cost every request. |
| **Cursor** | **Eager** + hard 40-tool cap (tools 41+ silently dropped). | Full cost + invisible tools past 40. |
| **Copilot CLI** | **Eager** — compaction-based context mgmt, no deferral. | Full cost; large sets trigger compaction loops. |

**Claude Code is the outlier.** The other three `ap` render targets pay the
configured schema cost on every request, whether or not the model calls a tool.

## Why this drives registry membership

Because three of four targets eager-load, an irrelevant MCP is dead weight on
those harnesses. The `harnesses` list is therefore both a compatibility and a
token-budget decision.

Measured tool-schema footprint of the full MCP set, **after the 2026-06 tool-surface
trim** (~55k tokens; the three trimmed servers carry their pre-trim count in parens):

| MCP | tools | tokens | share |
|---|---|---|---|
| todoist | ~45 | ~38,000 | 69% |
| serena | 9 (was 12) | ~4,050 | 7% |
| tilth | 7 | ~3,500 | 6% |
| tavily | 5 | ~2,100 | 4% |
| hallouminate | 8 (was 9)¹ | ~2,050 | 4% |
| context7 | 2 | ~1,200 | 2% |

The trims reduce the eager-harness coding set from roughly 22.8k to 17.05k
tokens per request — about 5.75k saved on Codex, Cursor, and Copilot, in
addition to the Todoist exclusion.

¹ The hallouminate `globalize_markdown` drop (9→8, ~250 tokens) ships separately
upstream and is **not** applied by this repo's config; the table row above already
reflects that post-upstream count, and once it lands it brings the eager set to
~16.8k.

On Claude the trim is token-neutral (deferred via `ToolSearch`) but still removes
broken/redundant tools from the candidate pool.

## The Todoist decision (worked example)

Todoist alone is **62%** of the footprint and is irrelevant to coding. It is
scoped out of every harness with an explicit empty membership list:

```yaml
todoist:
  ...
  harnesses: []   # renders into nothing
```

`harnesses: []` (empty, **not** absent) is the mechanism: in
`agent-profile/agent_profile/renderers/base.py`, `item_harnesses` falls back to
the default set (`_MCP_DEFAULT`) only when `harnesses` is *missing* (`None`); an
explicit empty list projects to zero harnesses. The entry stays in the registry
(documented, reversible) but renders nowhere.

Todoist is not lost: the **`todo` profile** (`profiles/todo/profile.yaml`)
defines it **inline** in its own `mcps:` block, independent of the registry
default — so the closed-world productivity session still gets it while every
coding harness sheds the 38k tokens.

## Takeaways for future edits

- Adding an MCP to the default set taxes Codex, Cursor, and Copilot on every
  request, not just when used.
- For an MCP that is only occasionally relevant, prefer scoping it to a dedicated
  profile (inline `mcps:`) over the default set — see Todoist / [[agents-dir]].
- Claude Code's lazy behavior can mask the cost — a set that feels free in Claude
  may be expensive everywhere else.

See [[agents-dir]] for the registry's `harnesses` field, [[agent-profile]] for
how renderers project it per harness, and [[../harnesses/index]] for each
harness's native config surface.
