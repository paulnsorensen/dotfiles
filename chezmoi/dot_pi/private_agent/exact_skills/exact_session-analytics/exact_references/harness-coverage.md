# Harness Coverage

Which coding-agent harnesses the analytics layer ingests, where their session
logs live, and how each is parsed. `ingest.py` runs one **normalizing adapter**
per harness; every adapter is discovery-gated and best-effort. A harness with no
accessible logs is recorded here and skipped non-fatally — full coverage of what
is reachable, not parsing the unparseable.

Every canonical table carries a `harness` column (`claude` / `codex` / `omp` /
`pi` / `cursor` / `copilot`) so one query can compare sources. See
`canonical-schema.md` for the table shapes.

## Coverage status

| Harness | Log location | Format | Adapter | Status |
|---------|-------------|--------|---------|--------|
| claude | `~/.claude/projects/**/*.jsonl` | JSONL, one turn per line; assistant/user `message.content[]` blocks | `claude_normalize` (pass-through, already canonical) | parsed |
| codex | `~/.codex/sessions/**/*.jsonl` | JSONL rollout; `session_meta` + `response_item`/`event_msg` payloads | `codex_normalize` | parsed |
| omp | `~/.omp/agent/sessions/<flattened-project-dir>/*.jsonl` | JSONL; `session` header + `message` entries with `toolCall` / `toolResult` | `omp_normalize` | parsed |
| pi | `~/.pi/agent/sessions/<flattened-project-dir>/*.jsonl` | JSONL; `session` header + `message` entries with `toolCall` / `toolResult` | `pi_normalize` | parsed |
| cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | SQLite blob, undocumented schema, fragile across versions | none | **no accessible logs** |
| copilot | `~/.copilot/` | holds `skills/` + `mcp-config.json` only; no local transcript found | none | **no accessible logs** |

## Per-harness format notes

### claude

Native format is already the canonical envelope (`type`, `timestamp`,
`sessionId`, `cwd`, `gitBranch`, `message.content[]`). The adapter only tags
`harness='claude'`. Subagent JSONL lives in `subagents/` subdirectories — picked
up by the recursive walk, but those turns have no direct user interaction (no
stop events, no denials).

### codex

Rollout JSONL. Each line is `{timestamp, type, payload}`:

- `session_meta` — `payload.id` (session id) + `payload.cwd`. Threaded onto every
  following row in the file.
- `turn_context` — refreshes `payload.cwd`.
- `response_item / function_call` and `custom_tool_call` → an assistant
  `tool_use` block. The tool name (`shell`, `apply_patch`, custom tools) is kept
  verbatim; `arguments` is JSON-parsed into `input`.
- `response_item / function_call_output` → a user `tool_result` block.

Codex has no `Skill` / `Agent` tool primitives, so `skill_invocations` and
`agent_spawns` stay claude-centric. `reasoning` items (encrypted) are dropped.

### omp and pi

OMP and upstream Pi use the same session envelope, with one JSONL file per
session under a flattened-path project directory (for example,
`-Dev-dotfiles`). The `session` header entry (`{type:'session', id, cwd,
timestamp}`) supplies sessionId + cwd for every row. `message` entries:

- assistant `toolCall` content blocks → `tool_use` (`arguments` becomes `input`,
  so `bash_cmd` extracts from `input.command`); `text`/`thinking` blocks pass
  through;
- role `toolResult` → a user `tool_result` block, joined on `toolCallId`;
- role `user` passes through.

Error flag: every `toolResult` message carries a **msg-level `isError` boolean**
— one convention for builtin and MCP tools. For MCP tools a duplicate flag lives
at `details.xdev.inner.isError`; verified perfectly consistent with the
msg-level flag across all sessions, so the adapter reads only the msg-level one.

OMP-specific caveats:

- **MCP naming** is a third scheme: `mcp__tilth_search` = `mcp__` + server +
  *single* underscore + tool. These rows land in `mcp_calls` (the `mcp__%`
  prefix filter matches), but any query that splits server/method on a
  double-underscore separator will misparse omp names — split on the prefix +
  first `_` instead when filtering `harness='omp'`.
- **Shaken content**: context-compacted tool results are stored as a stub like
  `[shaken ~275 tokens — recover: artifact://46 (region 2)]`. Kept verbatim —
  content-based metrics (result length, error-text matching) undercount for
  shaken rows.
- **Tool-call id reuse**: `toolCall` ids (`write_0|fc_...`) are not globally
  unique — a small fraction (~0.3%) repeat across sessions, so session-agnostic
  `tool_use_id` joins can slightly overcount; join on `sessionId` too when
  exactness matters.

### cursor — no accessible logs

Chat is persisted in `state.vscdb`, an opaque SQLite blob whose schema is
undocumented and changes between Cursor versions. No stable adapter exists; the
discover step returns `[]` and the run continues. Re-evaluate if Cursor ships a
documented export.

### copilot — no accessible logs

The GitHub Copilot CLI keeps no local session transcript we can locate
(`~/.copilot` holds only `skills/` and `mcp-config.json`). Discover returns `[]`.
Re-evaluate if a transcript store appears.

## Signal-quality caveats

Some metrics are only reliable on harnesses that record the underlying field —
e.g. token/cost data is absent from most logs (`token-economics` degrades to
"insufficient signal"), and Codex/OMP/Pi lack Claude's hook and permission-denial
entries, so `stop_hooks` and `permission_denials` are effectively Claude-only.
Packs must degrade gracefully rather than fabricate.
