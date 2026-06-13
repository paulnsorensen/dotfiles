# Canonical Schema

The shape every harness adapter normalizes into and every analytics pack queries
against. `ingest.py` loads one canonical row shape (the Claude envelope plus a
`harness` tag) into `~/.claude/analytics/sessions.duckdb`, then flattens it into
the tables below. **Pack authors: write SQL against these tables; never reach
into a harness's native format.**

Every session-scoped table carries a `harness` column
(`claude`/`codex`/`opencode`/`cursor`/`copilot`). Filter or group by it to
compare sources; omit it to aggregate across all reachable harnesses.

## `tool_uses`

Flattened from assistant `message.content[]` blocks where `type='tool_use'`.

| Column | Type | Description |
|--------|------|-------------|
| harness | VARCHAR | Source harness |
| tool_name | VARCHAR | Tool invoked (Bash, Read, Edit, Agent, Skill, mcp__*, or a harness-native name like `shell`/`apply_patch`) |
| tool_use_id | VARCHAR | Unique ID for joining with `tool_results` |
| input | JSON | Full input object |
| bash_cmd | VARCHAR | Extracted command (Bash only) |
| skill_name | VARCHAR | Extracted skill (Skill only — claude) |
| skill_args | VARCHAR | Extracted args (Skill only — claude) |
| agent_type | VARCHAR | Extracted subagent_type (Agent only — claude) |
| agent_desc | VARCHAR | Extracted description (Agent only) |
| agent_mode | VARCHAR | Extracted mode (Agent only) |
| grep_pattern | VARCHAR | Extracted pattern (Grep only) |
| file_path | VARCHAR | Extracted file_path (Read/Edit/Write) |
| query | VARCHAR | Extracted query (ToolSearch) |
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |
| cwd | VARCHAR | Working directory |
| gitBranch | VARCHAR | Git branch (claude only) |

## `tool_results`

Flattened from user `message.content[]` blocks where `type='tool_result'`.

| Column | Type | Description |
|--------|------|-------------|
| harness | VARCHAR | Source harness |
| tool_use_id | VARCHAR | Matches `tool_uses.tool_use_id` |
| content | VARCHAR | Result text (truncated to 500 chars) |
| is_error | VARCHAR | `'true'` if the call failed (string, not boolean) |
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |

## `stop_events`

Assistant messages where the model stopped generating. Columns: `harness`,
`stop_reason`, `timestamp`, `sessionId`, `cwd`, `gitBranch`.

## `agent_spawns`

Subset of `tool_uses` for `Agent` calls (claude). Columns: `harness`,
`agent_type` (defaults to `general-purpose`), `description`, `mode`, `timestamp`,
`sessionId`, `cwd`.

## `skill_invocations`

Subset of `tool_uses` for `Skill` calls (claude). Columns: `harness`,
`skill_name`, `args`, `timestamp`, `sessionId`, `cwd`.

## `mcp_calls`

Subset of `tool_uses` where `tool_name LIKE 'mcp__%'`. Same columns as
`tool_uses`. The name encodes server + method: `mcp__<server>__<method>`.

## `sessions`

One row per `(harness, sessionId, cwd, branch)`. Columns: `harness`,
`sessionId`, `first_seen`, `last_seen`, `project` (cwd), `branch`,
`entry_count`.

## `stop_hooks`

System entries with subtype `stop_hook_summary` (claude only — codex/opencode
emit none). Columns: `harness`, `timestamp`, `sessionId`, `hookCount`,
`hookInfos` (JSON), `hookErrors` (JSON), `preventedContinuation`, `stopReason`,
`hasOutput`, `level`.

## `permission_denials`

Pre-filtered `tool_results` for permission/hook denials (claude-dominant).
Columns: `harness`, `content`, `sessionId`, `timestamp`.

## `raw_entries`

The full unflattened canonical rows (post-adapter). Carries `harness` plus every
column in `ingest.py`'s `RAW_COLUMNS`. Use only when the materialized tables
lack a field you need.

## Type gotchas

- `is_error` is VARCHAR `'true'`/`'false'` — compare as strings.
- Timestamps are VARCHAR ISO strings — cast for date math (`timestamp::TIMESTAMP`,
  `timestamp::DATE`).
- DuckDB CLI `-json` returns every value as a string, including integers/booleans.
- Empty result sets print `[]`.
- `input` is JSON — use `json_extract_string()` for fields not already
  materialized as columns.
