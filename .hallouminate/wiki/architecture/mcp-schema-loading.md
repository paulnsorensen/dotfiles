# MCP schema loading: the per-harness token tax

The `harnesses` field on an `agents/mcp/registry.yaml` entry is not just a
*compatibility* lever (does this MCP make sense here) — it is a **per-request
token-budget** lever. The reason is that harnesses differ in *when* they send
an MCP server's tool schemas to the model.

## The split: Claude defers, everyone else eager-loads

Measured + sourced 2026-06 (research artifacts under
`.cheese/research/mcp-schema-loading/` and
`.cheese/research/opencode-mcp-eager-load/`):

| Harness | MCP tool-schema loading | Consequence |
|---|---|---|
| **Claude Code** | **Lazy / deferred by default** since v2.1.x (2026-01-14). Only tool *names* enter context at session start; full JSON schemas fetched on demand via `ToolSearch`. `ENABLE_TOOL_SEARCH` controls it (`true`/`false`/`auto`/`auto:N`); `alwaysLoad: true` opts a server out. Disabled on Vertex / non-first-party `ANTHROPIC_BASE_URL`. | A big MCP set costs ~names-only until used (~85% schema-token cut). |
| **opencode** | **Eager** — `SessionTools.resolve` adds every connected server's `mcp.tools()` defs to the LLM tool array every turn. `tools:{x:false}` / `permission` blocks *execution*, **not** prompt injection. No ToolSearch equivalent (sst/opencode#23045). | Full schema cost every request. |
| **Codex CLI** | **Eager** — lazy load is an open FR (#9266, #14507), unshipped. | Full schema cost every request. |
| **Cursor** | **Eager** + hard 40-tool cap (tools 41+ silently dropped). | Full cost + invisible tools past 40. |
| **Copilot CLI** | **Eager** — compaction-based context mgmt, no deferral. | Full cost; large sets trigger compaction loops. |

**Claude Code is the outlier, not the norm.** The intuition "MCP tools are cheap
because they load on demand" is *Claude-specific*. On the other four harnesses,
every configured MCP tool schema is paid for on every single request whether or
not the model ever calls it.

## Why this drives registry membership

Because four of the five render targets eager-load, an MCP that is irrelevant to
coding is dead weight measured in tens of thousands of tokens *per request* on
those harnesses. So the `harnesses` list is a budget decision: keep an MCP out
of harnesses that would pay for schemas they never use.

Measured tool-schema footprint of the full MCP set (~61k tokens / 112 tools):

| MCP | tokens | share |
|---|---|---|
| todoist | ~38,000 | 62% |
| code-review-graph | ~8,300 | 14% |
| serena | ~5,400 | 9% |
| tilth | ~3,500 | 6% |
| hallouminate | ~2,300 | 4% |
| tavily | ~2,100 | 3% |
| context7 | ~1,200 | 2% |

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

- Adding an MCP to the default `harnesses` set taxes opencode / codex / cursor /
  copilot on **every request**, not just when used. Budget accordingly.
- For an MCP that is only occasionally relevant, prefer scoping it to a dedicated
  profile (inline `mcps:`) over the default set — see Todoist / [[agents-dir]].
- Claude Code's lazy behavior can mask the cost — a set that feels free in Claude
  may be expensive everywhere else.

See [[agents-dir]] for the registry's `harnesses` field, [[agent-profile]] for
how renderers project it per harness, and [[../harnesses/index]] for each
harness's native config surface.
