# Harness Coverage

Which coding-agent harnesses the analytics layer ingests, where their session
logs live, and how each is parsed. `ingest.py` runs one **normalizing adapter**
per harness; every adapter is discovery-gated and best-effort. A harness with no
accessible logs is recorded here and skipped non-fatally — full coverage of what
is reachable, not parsing the unparseable.

Every canonical table carries a `harness` column (`claude` / `codex` /
`opencode` / `cursor` / `copilot`) so one query can compare sources. See
`canonical-schema.md` for the table shapes.

## Coverage status

| Harness | Log location | Format | Adapter | Status |
|---------|-------------|--------|---------|--------|
| claude | `~/.claude/projects/**/*.jsonl` | JSONL, one turn per line; assistant/user `message.content[]` blocks | `claude_normalize` (pass-through, already canonical) | parsed |
| codex | `~/.codex/sessions/**/*.jsonl` | JSONL rollout; `session_meta` + `response_item`/`event_msg` payloads | `codex_normalize` | parsed |
| opencode | `~/.local/share/opencode/opencode.db` | SQLite; `part` table rows with `type='tool'`, joined to `session.directory` | `opencode_normalize` | parsed |
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

### opencode

SQLite at `opencode.db` (older builds used JSON files under `storage/`; the
adapter targets the DB). A `part` row with `data.type='tool'` carries
`{tool, callID, state:{status, input, output}}`:

- the part → an assistant `tool_use` (tool name verbatim, `state.input` as input);
- when `state.output` is present (or `status='error'`) → a paired user
  `tool_result` (`is_error='true'` on error).

`session.directory` supplies `cwd`. Opened read-only (`mode=ro`).

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
"insufficient signal"), and codex/opencode lack Claude's hook + permission-denial
entries, so `stop_hooks` / `permission_denials` are effectively claude-only.
Packs must degrade gracefully rather than fabricate.
