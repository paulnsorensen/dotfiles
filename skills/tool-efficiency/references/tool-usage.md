# Pack: tool-usage

# target_param: {TOOL}        (a tool name or a Bash command prefix)

# harness: respects harness=<all|claude|codex|opencode>; 'all' omits the predicate

# owner: tool-efficiency

Frequency, project spread, and tool-vs-task fit for `{TOOL}`. Run by
`duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> Apply the spawn's harness filter: `all` → no predicate; else add
> `AND harness = '<harness>'` to each query.

## 1. Overall frequency + rank among all tools

```sql
SELECT tool_name, count(*) AS uses,
       round(count(*) * 100.0 / sum(count(*)) OVER (), 1) AS pct_of_all
FROM tool_uses
GROUP BY tool_name ORDER BY uses DESC LIMIT 20;
```

## 2. Usage of the target over time (weekly)

```sql
SELECT date_trunc('week', timestamp::DATE) AS week, count(*) AS uses
FROM tool_uses
WHERE tool_name = '{TOOL}'
GROUP BY week ORDER BY week;
```

## 3. Project distribution

```sql
SELECT regexp_extract(cwd, '.*/([^/]+)$', 1) AS project, count(*) AS uses
FROM tool_uses
WHERE tool_name = '{TOOL}'
GROUP BY project ORDER BY uses DESC LIMIT 10;
```

## 4. If the target is Bash: top command prefixes (task fit)

```sql
SELECT split_part(bash_cmd, ' ', 1) AS cmd_prefix, count(*) AS uses
FROM tool_uses
WHERE tool_name = 'Bash' AND bash_cmd IS NOT NULL
GROUP BY cmd_prefix ORDER BY uses DESC LIMIT 20;
```

## Output Format

```
## Tool Usage: {TOOL}

### Frequency
- Total uses: N  ·  Rank: N of M tools  ·  Share of all calls: X%

### Trend
| Week | Uses |
|------|------|

### Project Distribution
| Project | Uses |
|---------|------|

### Task Fit (Bash only)
| Command prefix | Uses |
|----------------|------|

### Findings
- [Overuse where a dedicated tool/skill exists; single-project concentration]
```
