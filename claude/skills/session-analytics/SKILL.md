---
name: session-analytics
description: >
  Query Claude Code's own JSONL session logs via DuckDB for usage analytics,
  tool patterns, error forensics, and routing decisions. Use when the user asks
  about their Claude usage patterns, tool frequencies, error rates, permission
  denials, agent routing, skill invocations, MCP server usage, session timelines,
  or any question about "how has Claude been working". Also trigger when the user
  says "session analytics", "query my logs", "tool usage", "how often do I use",
  "check my sessions", "analyze my usage", or asks about specific tool/agent/skill
  behavior across sessions. This skill turns ~900MB of raw JSONL into a queryable
  DuckDB database — use it instead of writing ad-hoc Python scripts to parse logs.
  Do NOT use for debugging current code issues, reading individual session
  transcripts, or questions about Claude's capabilities — this skill is for
  aggregate usage analytics across historical sessions.
model: sonnet
allowed-tools: Bash(duckdb:*), Bash(python3:*), Read
---

# session-analytics

Query Claude Code session logs. DuckDB is the database, SQL is the interface.

## How it works

Session logs live as JSONL files in `~/.claude/projects/`. Each conversation
turn is one JSON line. This skill materializes them into a DuckDB database
with pre-flattened tables so you can answer questions with single SQL queries.

## Step 1: Ensure the database exists

Run the ingestion script. It has a 1-hour TTL — it skips work if the database
is fresh. Always run this first.

```bash
python3 <skill-dir>/scripts/ingest.py
```

Use `--force` to re-ingest regardless of TTL (e.g., if the user wants the
latest data from the current session).

The database lives at `~/.claude/analytics/sessions.duckdb`.

## Step 2: Query via DuckDB CLI

All queries go through the CLI. Use `-json` for structured output you can
reason about, or omit it for human-readable tables.

```bash
duckdb ~/.claude/analytics/sessions.duckdb -json -c "SELECT ..."
```

## Schema

### `tool_uses`
Flattened from assistant message `content[]` blocks where `type = 'tool_use'`.

| Column | Type | Description |
|--------|------|-------------|
| tool_name | VARCHAR | Tool invoked (Bash, Read, Edit, Agent, Skill, mcp__*) |
| tool_use_id | VARCHAR | Unique ID for joining with tool_results |
| input | JSON | Full input object |
| bash_cmd | VARCHAR | Extracted command (Bash only) |
| skill_name | VARCHAR | Extracted skill (Skill only) |
| skill_args | VARCHAR | Extracted args (Skill only) |
| agent_type | VARCHAR | Extracted subagent_type (Agent only) |
| agent_desc | VARCHAR | Extracted description (Agent only) |
| agent_mode | VARCHAR | Extracted mode (Agent only) |
| grep_pattern | VARCHAR | Extracted pattern (Grep only) |
| file_path | VARCHAR | Extracted file_path (Read/Edit/Write) |
| query | VARCHAR | Extracted query (ToolSearch) |
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |
| cwd | VARCHAR | Working directory |
| gitBranch | VARCHAR | Git branch at time of call |

### `tool_results`
Flattened from user message `content[]` blocks where `type = 'tool_result'`.

| Column | Type | Description |
|--------|------|-------------|
| tool_use_id | VARCHAR | Matches tool_uses.tool_use_id |
| content | VARCHAR | Result text (truncated to 500 chars) |
| is_error | VARCHAR | 'true' if the tool call failed |
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |

### `stop_events`
Assistant messages where Claude stopped generating.

| Column | Type | Description |
|--------|------|-------------|
| stop_reason | VARCHAR | end_turn, stop_sequence, or max_tokens |
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |
| cwd | VARCHAR | Working directory |
| gitBranch | VARCHAR | Git branch |

### `agent_spawns`
Subset of tool_uses for Agent calls.

| Column | Type | Description |
|--------|------|-------------|
| agent_type | VARCHAR | Subagent type (defaults to 'general-purpose') |
| description | VARCHAR | Task description |
| mode | VARCHAR | Permission mode |
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |
| cwd | VARCHAR | Working directory |

### `skill_invocations`
Subset of tool_uses for Skill calls.

| Column | Type | Description |
|--------|------|-------------|
| skill_name | VARCHAR | Which skill was invoked |
| args | VARCHAR | Arguments passed |
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |
| cwd | VARCHAR | Working directory |

### `mcp_calls`
Subset of tool_uses for MCP server calls (tool_name starts with `mcp__`).

Same columns as `tool_uses`. The tool_name encodes the server and method:
`mcp__<server>__<method>` (e.g., `mcp__context7__query-docs`).

### `sessions`
One row per unique (sessionId, cwd, branch) combination.

| Column | Type | Description |
|--------|------|-------------|
| sessionId | VARCHAR | Session identifier |
| first_seen | VARCHAR | Earliest timestamp |
| last_seen | VARCHAR | Latest timestamp |
| project | VARCHAR | Working directory |
| branch | VARCHAR | Git branch |
| entry_count | INTEGER | Total JSONL entries in session |

### `stop_hooks`
System entries with subtype `stop_hook_summary`.

| Column | Type | Description |
|--------|------|-------------|
| timestamp | VARCHAR | ISO timestamp |
| sessionId | VARCHAR | Session identifier |
| hookCount | INTEGER | Number of hooks that ran |
| hookInfos | JSON | Array of {command, durationMs} |
| hookErrors | JSON | Array of error strings |
| preventedContinuation | BOOLEAN | Whether the hook blocked Claude |
| stopReason | VARCHAR | Reason text |
| hasOutput | BOOLEAN | Whether hook produced output |
| level | VARCHAR | suggestion, warning, etc. |

### `permission_denials`
Pre-filtered tool_results for permission-related failures.

| Column | Type | Description |
|--------|------|-------------|
| content | VARCHAR | The denial message |
| sessionId | VARCHAR | Session identifier |
| timestamp | VARCHAR | ISO timestamp |

### `raw_entries`
The full unflattened JSONL data. Use only when the materialized tables
don't have what you need.

## Example queries

### Tool usage frequency
```sql
SELECT tool_name, count(*) AS uses
FROM tool_uses
GROUP BY tool_name
ORDER BY uses DESC;
```

### Error rate by tool
```sql
SELECT
    tu.tool_name,
    count(*) AS total,
    sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) AS errors,
    round(sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) * 100.0 / count(*), 1) AS error_pct
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
GROUP BY tu.tool_name
ORDER BY errors DESC;
```

### Permission denials by tool
```sql
SELECT
    -- Extract tool name from "Permission to use X has been denied"
    regexp_extract(content, 'Permission to use (\w+)', 1) AS tool,
    count(*) AS denials
FROM permission_denials
WHERE content LIKE 'Permission to use%'
GROUP BY tool
ORDER BY denials DESC;
```

### How /research routes between sources
```sql
-- What agents does /research spawn?
SELECT agent_type, description, count(*) AS cnt
FROM agent_spawns
WHERE sessionId IN (
    SELECT DISTINCT sessionId FROM skill_invocations
    WHERE skill_name = 'research'
)
AND timestamp >= (
    SELECT min(timestamp) FROM skill_invocations
    WHERE skill_name = 'research'
)
GROUP BY agent_type, description
ORDER BY cnt DESC;
```

### MCP server usage breakdown
```sql
SELECT
    split_part(tool_name, '__', 2) AS server,
    split_part(tool_name, '__', 3) AS method,
    count(*) AS calls
FROM mcp_calls
GROUP BY server, method
ORDER BY calls DESC;
```

### MCP errors
```sql
SELECT
    tu.tool_name,
    substr(tr.content, 1, 120) AS error,
    count(*) AS cnt
FROM mcp_calls tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tr.is_error = 'true'
GROUP BY tu.tool_name, error
ORDER BY cnt DESC
LIMIT 20;
```

### Skill usage over time
```sql
SELECT
    skill_name,
    timestamp::DATE AS day,
    count(*) AS uses
FROM skill_invocations
GROUP BY skill_name, day
ORDER BY day DESC, uses DESC;
```

### Busiest sessions
```sql
SELECT
    s.sessionId,
    s.project,
    s.branch,
    s.first_seen,
    s.last_seen,
    (SELECT count(*) FROM tool_uses tu WHERE tu.sessionId = s.sessionId) AS tool_calls
FROM sessions s
ORDER BY tool_calls DESC
LIMIT 10;
```

### Tool calls by hour (UTC)
```sql
SELECT
    extract(hour FROM timestamp::TIMESTAMP) AS hour,
    count(*) AS calls
FROM tool_uses
GROUP BY hour
ORDER BY hour;
```

### Most common Bash commands
```sql
SELECT
    substr(bash_cmd, 1, 80) AS cmd,
    count(*) AS uses
FROM tool_uses
WHERE tool_name = 'Bash' AND bash_cmd IS NOT NULL
GROUP BY cmd
ORDER BY uses DESC
LIMIT 20;
```

### Files read most often
```sql
SELECT file_path, count(*) AS reads
FROM tool_uses
WHERE tool_name = 'Read' AND file_path IS NOT NULL
GROUP BY file_path
ORDER BY reads DESC
LIMIT 15;
```

### Stop hook errors
```sql
SELECT
    unnest(json_extract(hookErrors, '$[*]'))::VARCHAR AS error,
    count(*) AS cnt
FROM stop_hooks
WHERE json_array_length(hookErrors) > 0
GROUP BY error
ORDER BY cnt DESC;
```

## Query patterns

When answering user questions:

1. Run `python3 <skill-dir>/scripts/ingest.py` first (fast if cached)
2. Translate the question into SQL against the schema above
3. Use `duckdb ~/.claude/analytics/sessions.duckdb -json -c "..."` to execute
4. Present results as markdown tables when there are 3+ rows. For single-value
   answers, state the number directly. Lead with the answer, then show the
   query if the user might want to modify it.
5. For follow-up questions, skip ingestion — the database persists

For complex analysis, chain multiple queries. The tables are indexed on
common join columns (tool_name, sessionId, is_error).

When filtering by project, use `LIKE '%keyword%'` on the `cwd` column since
full paths are verbose (`/Users/paul/conductor/workspaces/tern-lisbon/...`).

Timestamps are ISO 8601 strings stored as VARCHAR. Cast to TIMESTAMP for
date math: `timestamp::TIMESTAMP`, `timestamp::DATE`, or use `extract()`.

## Gotchas

- Empty DuckDB CLI JSON results return `[{]` not `[]` — handle both in parsing
- `is_error` in tool_results is VARCHAR `'true'`/`'false'`, not a boolean — use
  string comparison: `WHERE is_error = 'true'`, not `WHERE is_error = true`
- Timestamps are VARCHAR — cast explicitly for date math, don't assume native
  TIMESTAMP type
- The `input` column in tool_uses is full JSON — use `json_extract_string()` to
  pull specific fields not already materialized as columns
- Subagent JSONL files live in `subagents/` subdirectories — they're included in
  ingestion but have no direct user interaction (no stop events, no denials)
- DuckDB CLI `-json` mode returns all values as strings, including integers and
  booleans — parse accordingly when processing output
