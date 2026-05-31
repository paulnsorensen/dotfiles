# Pack: error-forensics

# target_param: {TOOL}        (a tool name; '%' to scan all tools)

# harness: respects harness=<all|claude|codex|opencode>

# owner: tool-efficiency

Error rate vs baseline and recurring failure signatures for `{TOOL}`. Run by
`duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> Apply the harness filter: `all` → no predicate; else add `AND tu.harness = '<harness>'`.

## 1. Error rate for the target vs the global baseline

```sql
WITH target AS (
    SELECT count(*) AS total,
           sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors
    FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
    WHERE tu.tool_name LIKE '{TOOL}'
),
baseline AS (
    SELECT count(*) AS total,
           sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors
    FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
)
SELECT 'target' AS scope, total, errors,
       round(errors*100.0/nullif(total,0),1) AS error_pct FROM target
UNION ALL
SELECT 'baseline', total, errors,
       round(errors*100.0/nullif(total,0),1) FROM baseline;
```

## 2. Recurring error signatures

```sql
SELECT substr(tr.content, 1, 150) AS error, count(*) AS occ
FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
WHERE tu.tool_name LIKE '{TOOL}' AND tr.is_error = 'true'
GROUP BY error ORDER BY occ DESC LIMIT 15;
```

## 3. Error rate by tool (when {TOOL} = '%')

```sql
SELECT tu.tool_name, count(*) AS total,
       sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
       round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
GROUP BY tu.tool_name HAVING count(*) >= 5
ORDER BY errors DESC LIMIT 20;
```

## Output Format

```
## Error Forensics: {TOOL}

### Error Rate
- Target: N errors / M calls (X%)
- Baseline: Y%
- Delta: +/- Z points

### Recurring Failures
| Error | Count |
|-------|-------|

### Per-Tool (when scanning all)
| Tool | Total | Errors | Error % |
|------|-------|--------|---------|

### Findings
- [Tools fighting the environment, repeated avoidable failures]
- "Insufficient signal" if <5 calls.
```
