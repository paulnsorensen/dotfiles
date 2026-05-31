# Pack: permission-friction

# target_param: {TOOL}        (usually 'Bash'; '%' for all tools)

# harness: claude-dominant — denials/hooks barely exist on codex/opencode

# owner: tool-efficiency

Permission denials, allowlist gaps, and compound-command friction. Run by
`duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> Denials and stop-hooks are recorded almost exclusively for claude. On a
> codex/opencode filter, expect empty results — report "insufficient signal",
> not "no friction".

## 1. Denial categories (root-cause buckets)

```sql
SELECT
    CASE
        WHEN bash_cmd LIKE '%python3%' THEN 'python3 inline'
        WHEN bash_cmd LIKE 'find %' OR bash_cmd LIKE '% find %' THEN 'find (use Glob)'
        WHEN bash_cmd LIKE 'grep %' OR bash_cmd LIKE 'egrep %' THEN 'grep (use Grep)'
        WHEN bash_cmd LIKE 'sed %' OR bash_cmd LIKE '%sed -i%' THEN 'sed (use Edit)'
        WHEN bash_cmd LIKE 'cd %' AND bash_cmd LIKE '%git%' THEN 'cd+git (use wt-git)'
        WHEN bash_cmd LIKE '%git add%&&%git commit%' THEN 'git add+commit (use /commit)'
        ELSE 'other: ' || substr(bash_cmd, 1, 40)
    END AS category,
    count(*) AS denials
FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash' AND tr.is_error = 'true'
  AND tr.content LIKE 'Permission to use Bash%'
GROUP BY category ORDER BY denials DESC;
```

## 2. Allowlist gap finder (succeed-but-prompted prefixes)

```sql
SELECT split_part(bash_cmd, ' ', 1) AS cmd_prefix, count(*) AS uses,
       sum(CASE WHEN tr.is_error='true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) AS denied
FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL
GROUP BY cmd_prefix HAVING count(*) >= 5
ORDER BY denied DESC LIMIT 20;
```

## 3. Compound-command friction (pipes / && that get denied)

```sql
SELECT substr(bash_cmd, 1, 120) AS cmd, count(*) AS denials
FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name = 'Bash' AND tr.is_error = 'true'
  AND tr.content LIKE 'Permission to use Bash%'
  AND (bash_cmd LIKE '%|%' OR bash_cmd LIKE '%&&%')
GROUP BY cmd ORDER BY denials DESC LIMIT 15;
```

## Output Format

```
## Permission Friction: {TOOL}

### Denial Categories
| Category | Denials |
|----------|---------|

### Allowlist Gaps (high-use, often-denied prefixes)
| Prefix | Uses | Denied |
|--------|------|--------|

### Compound-Command Friction
| Command | Denials |
|---------|---------|

### Findings
- [Allowlist entries to add, raw-bash that should route to a skill/dedicated tool]
- "Insufficient signal" on non-claude harnesses.
```
