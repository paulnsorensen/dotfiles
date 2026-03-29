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

## Query Catalog

Organized by investigation type. Use as starting points — modify for your question.

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

### Permission friction audit
What Bash commands get denied most, categorized by root cause:
```sql
SELECT
    CASE
        WHEN bash_cmd LIKE '%python3%' THEN 'python3 inline'
        WHEN bash_cmd LIKE '%cat %' AND bash_cmd LIKE '%>%' THEN 'cat redirect (use Write)'
        WHEN bash_cmd LIKE 'find %' OR bash_cmd LIKE '% find %' THEN 'find (use Glob)'
        WHEN bash_cmd LIKE 'grep %' OR bash_cmd LIKE 'egrep %' THEN 'grep (use Grep)'
        WHEN bash_cmd LIKE 'sed %' OR bash_cmd LIKE '%sed -i%' THEN 'sed (use Edit)'
        WHEN bash_cmd LIKE 'cd %' AND bash_cmd LIKE '%git%' THEN 'cd+git (use wt-git)'
        WHEN bash_cmd LIKE 'cd %' AND bash_cmd LIKE '%gh %' THEN 'cd+gh (use wt-git)'
        WHEN bash_cmd LIKE '%cargo clippy%' THEN 'cargo clippy'
        WHEN bash_cmd LIKE '%cargo fmt%' THEN 'cargo fmt'
        WHEN bash_cmd LIKE '%cargo nextest%' THEN 'cargo nextest'
        WHEN bash_cmd LIKE '%just %' THEN 'just'
        WHEN bash_cmd LIKE '%tokei%' THEN 'tokei'
        WHEN bash_cmd LIKE 'mkdir%' THEN 'mkdir'
        WHEN bash_cmd LIKE '%git add%&&%git commit%' THEN 'git add+commit (use /commit)'
        WHEN bash_cmd LIKE '%git commit%$(%' THEN 'git commit heredoc (use /commit)'
        ELSE 'other: ' || substr(bash_cmd, 1, 50)
    END AS category,
    count(*) AS denials
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash'
AND tr.is_error = 'true'
AND tr.content LIKE 'Permission to use Bash%'
GROUP BY category
ORDER BY denials DESC;
```

### Bash allowlist gap finder
Commands that succeed but require manual approval (not in allowlist, not blocked by hook):
```sql
SELECT
    split_part(bash_cmd, ' ', 1) AS cmd_prefix,
    count(*) AS uses,
    sum(CASE WHEN tr.is_error = 'true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) AS denied,
    round(sum(CASE WHEN tr.is_error = 'true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) * 100.0 / count(*), 1) AS deny_pct
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL
GROUP BY cmd_prefix
HAVING count(*) >= 5
ORDER BY denied DESC
LIMIT 20;
```

### Python3 usage by purpose
Categorizes inline python3 calls to find skill opportunities:
```sql
SELECT
    CASE
        WHEN bash_cmd LIKE '%json.load%' OR bash_cmd LIKE '%json.loads%' THEN 'JSON parse/transform'
        WHEN bash_cmd LIKE '%json.dump%' OR bash_cmd LIKE '%json.dumps%' THEN 'JSON write'
        WHEN bash_cmd LIKE '%json.tool%' THEN 'JSON pretty-print'
        WHEN bash_cmd LIKE '%re.sub%' OR bash_cmd LIKE '%re.match%' OR bash_cmd LIKE '%.replace(%' THEN 'regex/string replace'
        WHEN bash_cmd LIKE '%open(%' AND bash_cmd LIKE '%write%' THEN 'file write/update'
        WHEN bash_cmd LIKE '%open(%' AND bash_cmd LIKE '%read%' THEN 'file read/filter'
        WHEN bash_cmd LIKE '%base64%' THEN 'base64 encode/decode'
        WHEN bash_cmd LIKE '%yaml%' THEN 'YAML processing'
        WHEN bash_cmd LIKE '%subprocess%' THEN 'subprocess orchestration'
        WHEN bash_cmd LIKE '%os.path%' OR bash_cmd LIKE '%import os%' THEN 'filesystem ops'
        WHEN bash_cmd LIKE '%import re%' THEN 'regex processing'
        ELSE 'other'
    END AS purpose,
    count(*) AS cnt,
    round(count(*) * 100.0 / sum(count(*)) OVER (), 1) AS pct
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash'
AND tu.bash_cmd LIKE '%python3%'
AND tr.is_error = 'false'
GROUP BY purpose
ORDER BY cnt DESC;
```

### MCP routing for a specific skill
Shows which MCPs were called within N minutes of a skill invocation:
```sql
-- Replace 'research' with the skill name and adjust window
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = 'research'
)
SELECT
    split_part(mc.tool_name, '__', 2) AS server,
    split_part(mc.tool_name, '__', 3) AS method,
    count(*) AS calls
FROM mcp_calls mc
JOIN skill_windows sw
    ON mc.sessionId = sw.sessionId
    AND mc.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
GROUP BY server, method
ORDER BY calls DESC;
```

### Agent spawn patterns by skill
Shows which agent types each skill spawns:
```sql
SELECT
    si.skill_name,
    asp.agent_type,
    substr(asp.description, 1, 60) AS agent_desc,
    count(*) AS spawns
FROM skill_invocations si
JOIN agent_spawns asp
    ON si.sessionId = asp.sessionId
    AND asp.timestamp::TIMESTAMP BETWEEN si.timestamp::TIMESTAMP
        AND si.timestamp::TIMESTAMP + INTERVAL '10' MINUTE
GROUP BY si.skill_name, asp.agent_type, agent_desc
ORDER BY si.skill_name, spawns DESC;
```

### Hook impact analysis
Stop hooks that blocked continuation vs allowed:
```sql
SELECT
    level,
    preventedContinuation,
    substr(stopReason, 1, 100) AS reason,
    count(*) AS cnt
FROM stop_hooks
GROUP BY level, preventedContinuation, reason
ORDER BY cnt DESC
LIMIT 20;
```

### Compound command friction
Bash commands with pipes or && that trigger permission prompts:
```sql
SELECT
    substr(bash_cmd, 1, 150) AS cmd,
    count(*) AS denials
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash'
AND tr.is_error = 'true'
AND tr.content LIKE 'Permission to use Bash%'
AND (bash_cmd LIKE '%|%' OR bash_cmd LIKE '%&&%')
GROUP BY cmd
ORDER BY denials DESC
LIMIT 20;
```

### Tool usage by project
Compare tool patterns across projects:
```sql
SELECT
    regexp_extract(cwd, '.*/([^/]+)$', 1) AS project,
    tool_name,
    count(*) AS uses
FROM tool_uses
GROUP BY project, tool_name
ORDER BY project, uses DESC;
```

### Daily activity heatmap
```sql
SELECT
    timestamp::DATE AS day,
    extract(hour FROM timestamp::TIMESTAMP) AS hour,
    count(*) AS calls
FROM tool_uses
WHERE timestamp::DATE >= CURRENT_DATE - INTERVAL '14' DAY
GROUP BY day, hour
ORDER BY day DESC, hour;
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

For complex analysis, chain multiple queries. Aim to answer within 5-8 queries.
If the question needs more, present intermediate findings and ask if deeper
analysis is needed. The tables are indexed on common join columns (tool_name,
sessionId, is_error).

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
