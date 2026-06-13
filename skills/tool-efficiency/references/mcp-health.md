# Pack: mcp-health

# target_param: {SERVER}      (an MCP server name, e.g. 'serena'; '%' for all)

# harness: respects harness=<all|claude|codex|opencode>

# owner: tool-efficiency

Per-MCP call volume, error rate, method spread, and idle-server detection. Run
by `duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> mcp_calls is derived from tool names starting `mcp__`; codex/opencode encode
> MCP differently, so this is claude-dominant. Apply the harness filter and note
> the caveat.

## 1. Calls + error rate for the target server

```sql
SELECT split_part(mc.tool_name, '__', 2) AS server,
       count(*) AS calls,
       sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
       round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
FROM mcp_calls mc
LEFT JOIN tool_results tr ON mc.tool_use_id = tr.tool_use_id
WHERE split_part(mc.tool_name, '__', 2) LIKE '{SERVER}'
GROUP BY server ORDER BY calls DESC;
```

## 2. Method breakdown for the target

```sql
SELECT split_part(mc.tool_name, '__', 3) AS method, count(*) AS calls
FROM mcp_calls mc
WHERE split_part(mc.tool_name, '__', 2) LIKE '{SERVER}'
GROUP BY method ORDER BY calls DESC LIMIT 20;
```

## 3. Server leaderboard (idle-server detection when {SERVER}='%')

```sql
SELECT split_part(tool_name, '__', 2) AS server,
       count(*) AS calls,
       count(DISTINCT sessionId) AS sessions,
       max(timestamp)::DATE AS last_used
FROM mcp_calls
GROUP BY server ORDER BY calls DESC;
```

## Output Format

```
## MCP Health: {SERVER}

### Volume & Errors
| Server | Calls | Errors | Error % |
|--------|-------|--------|---------|

### Method Breakdown
| Method | Calls |
|--------|-------|

### Server Leaderboard (idle detection)
| Server | Calls | Sessions | Last used |
|--------|-------|----------|-----------|

### Findings
- [High-error servers, never-used servers worth removing, lopsided method use]
- "Insufficient signal" on non-claude harnesses.
```
