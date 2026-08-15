# Pack: skill-usage

# target_param: {SKILL}        (a skill name or agent type)

# harness: harness='all' by default (skill_invocations is claude-dominant — note that)

# owner: skill-improver

Measures invocation patterns for `{SKILL}`. Run by `duckdb-expert`, one spawn.
Schema: `skills/session-analytics/references/canonical-schema.md`.

## 1. Total invocations and date range

```sql
SELECT
    count(*) AS total_invocations,
    min(timestamp)::DATE AS first_seen,
    max(timestamp)::DATE AS last_seen,
    count(DISTINCT sessionId) AS unique_sessions
FROM skill_invocations
WHERE skill_name = '{SKILL}';
```

## 2. Weekly trend (last 8 weeks)

```sql
SELECT
    date_trunc('week', timestamp::DATE) AS week,
    count(*) AS invocations
FROM skill_invocations
WHERE skill_name = '{SKILL}'
  AND timestamp::DATE >= CURRENT_DATE - INTERVAL '56' DAY
GROUP BY week
ORDER BY week;
```

## 3. Project distribution

```sql
SELECT
    regexp_extract(cwd, '.*/([^/]+)$', 1) AS project,
    count(*) AS uses
FROM skill_invocations
WHERE skill_name = '{SKILL}'
GROUP BY project
ORDER BY uses DESC
LIMIT 10;
```

## 4. Peer comparison (top 15 skills by usage)

```sql
SELECT skill_name, count(*) AS total, count(DISTINCT sessionId) AS sessions
FROM skill_invocations
GROUP BY skill_name
ORDER BY total DESC
LIMIT 15;
```

## 5. If the target is an agent type, also check agent_spawns

```sql
SELECT agent_type, count(*) AS spawns, count(DISTINCT sessionId) AS sessions
FROM agent_spawns
WHERE agent_type = '{SKILL}'
GROUP BY agent_type;
```

## Output Format

```
## Usage Analytics: {SKILL}

### Invocation Summary
- Total invocations: N (across N sessions)
- Active since: YYYY-MM-DD
- Last used: YYYY-MM-DD

### Trend
- Direction: rising / stable / declining / new (<4 weeks)
- Weekly average (last 4 weeks): N
- Weekly average (prior 4 weeks): N

### Project Distribution
| Project | Uses |
|---------|------|

### Peer Ranking
- Rank N of M tracked skills
- Usage relative to median: above / at / below

### Findings
- [Notable patterns: zero usage, sharp decline, single-project concentration]
```
