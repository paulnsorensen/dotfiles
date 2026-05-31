# Pack: drift-regression

# target_param: {SKILL}

# harness: harness='all' (skill_invocations is claude-dominant — note that)

# owner: skill-improver

Detects behavioral drift over time for `{SKILL}`: usage decay, error-rate
regression, and friction creep that static audit can't see. Run by
`duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

## 1. Usage decay (recent vs prior 4 weeks)

```sql
WITH inv AS (SELECT timestamp::DATE AS d FROM skill_invocations WHERE skill_name = '{SKILL}')
SELECT
    sum(CASE WHEN d >= CURRENT_DATE - INTERVAL '28' DAY THEN 1 ELSE 0 END) AS recent_4w,
    sum(CASE WHEN d >= CURRENT_DATE - INTERVAL '56' DAY
             AND d <  CURRENT_DATE - INTERVAL '28' DAY THEN 1 ELSE 0 END) AS prior_4w
FROM inv;
```

## 2. Error-rate regression in skill windows over time

```sql
WITH w AS (
    SELECT sessionId, timestamp::DATE AS day, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT date_trunc('week', w.day) AS week,
       count(*) AS calls,
       round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
JOIN w ON tu.sessionId = w.sessionId AND tu.timestamp::TIMESTAMP BETWEEN w.t0 AND w.t1
GROUP BY week ORDER BY week;
```

## 3. New error signatures in the last 2 weeks

```sql
WITH w AS (
    SELECT sessionId, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t1,
           timestamp::DATE AS day
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT substr(tr.content, 1, 120) AS error, count(*) AS occ,
       min(w.day) AS first_seen
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
JOIN w ON tu.sessionId = w.sessionId AND tu.timestamp::TIMESTAMP BETWEEN w.t0 AND w.t1
WHERE tr.is_error = 'true'
GROUP BY error HAVING min(w.day) >= CURRENT_DATE - INTERVAL '14' DAY
ORDER BY occ DESC LIMIT 10;
```

## Output Format

```
## Drift / Regression Analytics: {SKILL}

### Usage Trajectory
- Recent 4 weeks: N invocations
- Prior 4 weeks: N invocations
- Verdict: growing / stable / decaying / dormant

### Error-Rate Trend
| Week | Calls | Error % |
|------|-------|---------|
- Direction: improving / stable / regressing

### New Error Signatures (last 2 weeks)
| Error | Count | First seen |
|-------|-------|-----------|

### Findings
- [Decay worth retiring/merging, error regression, newly-appeared failures]
- "Insufficient signal" if <4 weeks of data or all-empty.
```
