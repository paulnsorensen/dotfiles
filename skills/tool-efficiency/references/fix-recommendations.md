# Pack: fix-recommendations

# target_param: {TOOL}        (a tool name; '%' to scan all tools)

# harness: allowlist/denial queries are claude-dominant; tool-error queries span all harnesses

# owner: tool-efficiency

Turns the raw error/friction signal into concrete, actionable fixes for `{TOOL}`
— allowlist entries to add, raw-bash to route to a dedicated tool, and MCP
servers to repair or retire. Advisory only: it recommends the fix, it never
applies it. Run by `duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> Denials and allowlist gaps are recorded almost exclusively for claude. On a
> codex/opencode filter, expect those sections empty — report "insufficient
> signal", not "nothing to fix". The high-error-tool and MCP queries span all
> harnesses.

## 1. High-error tools — swap or fix the call shape

Tools failing ≥40% of the time with ≥3 calls. A 100% rate usually means a
malformed/stale tool name (e.g. `tilth_read` instead of `mcp__tilth__tilth_read`).

```sql
SELECT tu.tool_name, count(*) AS calls,
       sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
       round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name LIKE '{TOOL}'
GROUP BY tu.tool_name
HAVING count(*) >= 3
   AND sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*) >= 40
ORDER BY error_pct DESC, calls DESC LIMIT 15;
```

## 2. Allowlist adds (high-use prefixes that keep getting denied)

```sql
SELECT split_part(bash_cmd, ' ', 1) AS cmd_prefix, count(*) AS uses,
       sum(CASE WHEN tr.is_error='true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) AS denied
FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL
GROUP BY cmd_prefix
HAVING sum(CASE WHEN tr.is_error='true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) >= 2
ORDER BY denied DESC LIMIT 15;
```

→ For each row, recommend `Bash(<prefix>:*)` in the allowlist (only when the
prefix is a safe, read-mostly command — never blanket-allow destructive verbs).

## 3. Raw-bash that should route to a dedicated tool/skill

```sql
SELECT
    CASE
        WHEN bash_cmd LIKE 'find %' OR bash_cmd LIKE '% find %' THEN 'find -> Glob / cheez-search'
        WHEN bash_cmd LIKE 'grep %' OR bash_cmd LIKE 'egrep %' OR bash_cmd LIKE 'rg %' THEN 'grep/rg -> cheez-search'
        WHEN bash_cmd LIKE 'cat %' AND bash_cmd NOT LIKE '%>%' THEN 'cat -> cheez-read'
        WHEN bash_cmd LIKE 'sed %' OR bash_cmd LIKE '%sed -i%' THEN 'sed -> cheez-write / Edit'
        WHEN bash_cmd LIKE '%python3%json%' THEN 'python3 json -> jq'
        WHEN bash_cmd LIKE '%git add%' AND bash_cmd LIKE '%git commit%' THEN 'git add+commit -> /commit'
        ELSE NULL
    END AS swap,
    count(*) AS uses
FROM tool_uses tu
WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL
GROUP BY swap HAVING swap IS NOT NULL
ORDER BY uses DESC;
```

## 4. MCP servers — repair (high error) or retire (idle)

```sql
SELECT split_part(mc.tool_name, '__', 2) AS server,
       count(*) AS calls,
       sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
       round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
FROM mcp_calls mc JOIN tool_results tr ON mc.tool_use_id = tr.tool_use_id
GROUP BY server ORDER BY error_pct DESC, calls ASC LIMIT 20;
```

→ High error_pct = repair candidate (broken call shape / dead server). Very low
`calls` across all sessions = retire candidate (paying context cost for nothing).

## Output Format

```
## Fix Recommendations: {TOOL}

### Swap / Fix Call Shape (high-error tools)
| Tool | Calls | Errors | Error % | Suggested fix |
|------|-------|--------|---------|---------------|

### Allowlist Adds
| Prefix | Uses | Denied | Suggested entry |
|--------|------|--------|-----------------|

### Route Raw-Bash to a Tool
| Pattern | Uses | Route to |
|---------|------|----------|

### MCP Repair / Retire
| Server | Calls | Error % | Action |
|--------|-------|---------|--------|

### Findings
- Concrete, ranked fixes. Each cites the metric above.
- "Insufficient signal" for any section with <2 supporting rows.
- Advisory only — names the fix; the human applies it.
```
