# Skill-Audit Query Packs

Parameterized DuckDB query packs for auditing a single skill's behavior, used by
`skill-improver` Dimension 7. A caller (typically the `duckdb-expert` agent)
picks one pack, substitutes `{SKILL}` with the target skill name (or agent
type), runs the queries in order, and returns the pack's output format.

Prereqs (see the parent `SKILL.md`):

- Database at `~/.claude/analytics/sessions.duckdb` (run `scripts/ingest.py` first).
- All queries go through the CLI: `duckdb ~/.claude/analytics/sessions.duckdb -json -c "SQL"`.
- If a query returns empty, note it and move on. Never block on a single empty result.

Three packs: **usage**, **tools**, **friction**. Run only the one requested.

---

## Pack: `usage`

Measures invocation patterns for `{SKILL}` (skill name or agent type).

### 1. Total invocations and date range

```sql
SELECT
    count(*) AS total_invocations,
    min(timestamp)::DATE AS first_seen,
    max(timestamp)::DATE AS last_seen,
    count(DISTINCT sessionId) AS unique_sessions
FROM skill_invocations
WHERE skill_name = '{SKILL}';
```

### 2. Weekly trend (last 8 weeks)

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

### 3. Project distribution

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

### 4. Peer comparison (top 15 skills by usage)

```sql
SELECT
    skill_name,
    count(*) AS total,
    count(DISTINCT sessionId) AS sessions
FROM skill_invocations
GROUP BY skill_name
ORDER BY total DESC
LIMIT 15;
```

### 5. If the target is an agent type, also check agent_spawns

```sql
SELECT
    agent_type,
    count(*) AS spawns,
    count(DISTINCT sessionId) AS sessions
FROM agent_spawns
WHERE agent_type = '{SKILL}'
GROUP BY agent_type;
```

### Output Format

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
| ... | ... |

### Peer Ranking
- Rank N of M tracked skills
- Usage relative to median: above / at / below

### Findings
- [Notable patterns: zero usage, sharp decline, single-project concentration, etc.]
```

---

## Pack: `tools`

Compares `{SKILL}`'s declared tools against actual tool usage in the 10-minute
window after each invocation. The caller supplies the declared-tools list.

### 1. Tools used within 10-minute windows after skill invocation

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
)
SELECT
    tu.tool_name,
    count(*) AS uses
FROM tool_uses tu
JOIN skill_windows sw
    ON tu.sessionId = sw.sessionId
    AND tu.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
GROUP BY tu.tool_name
ORDER BY uses DESC;
```

### 2. Agent types spawned during skill windows

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
)
SELECT
    asp.agent_type,
    substr(asp.description, 1, 80) AS desc,
    asp.mode,
    count(*) AS spawns
FROM agent_spawns asp
JOIN skill_windows sw
    ON asp.sessionId = sw.sessionId
    AND asp.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
GROUP BY asp.agent_type, desc, asp.mode
ORDER BY spawns DESC;
```

### 3. MCP servers called during skill windows

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
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

### 4. Bash command categories during skill windows

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
)
SELECT
    split_part(tu.bash_cmd, ' ', 1) AS cmd_prefix,
    count(*) AS uses
FROM tool_uses tu
JOIN skill_windows sw
    ON tu.sessionId = sw.sessionId
    AND tu.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL
GROUP BY cmd_prefix
ORDER BY uses DESC
LIMIT 15;
```

### Output Format

```
## Tool Pattern Analytics: {SKILL}

### Declared vs Actual Tool Usage
| Tool | Declared | Actually Used | Count |
|------|----------|---------------|-------|
| Read | yes | yes | 45 |
| Bash | no | yes | 12 |
| ... | ... | ... | ... |

### Undeclared Tools (used but not in allowed-tools)
- [Tools seen in execution windows but not declared]

### Unused Declared Tools (declared but never seen)
- [Tools in allowed-tools/tools that never appear in windows]

### Agent Spawn Patterns
| Agent Type | Description | Mode | Count |
|------------|-------------|------|-------|
| ... | ... | ... | ... |

### MCP Usage
| Server | Method | Calls |
|--------|--------|-------|
| ... | ... | ... |

### Findings
- [Mismatches, surprising patterns, missing declarations]
```

---

## Pack: `friction`

Surfaces errors, permission denials, and hook interruptions during `{SKILL}`
execution windows.

### 1. Overall error rate during skill windows

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
)
SELECT
    tu.tool_name,
    count(*) AS total,
    sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) AS errors,
    round(sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) * 100.0
          / count(*), 1) AS error_pct
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
JOIN skill_windows sw
    ON tu.sessionId = sw.sessionId
    AND tu.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
GROUP BY tu.tool_name
HAVING count(*) >= 3
ORDER BY errors DESC;
```

### 2. Permission denials during skill windows

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
)
SELECT
    substr(pd.content, 1, 150) AS denial_message,
    count(*) AS occurrences
FROM permission_denials pd
JOIN skill_windows sw
    ON pd.sessionId = sw.sessionId
    AND pd.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
GROUP BY denial_message
ORDER BY occurrences DESC
LIMIT 10;
```

### 3. Common error messages during skill windows

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
)
SELECT
    tu.tool_name,
    substr(tr.content, 1, 150) AS error_content,
    count(*) AS occurrences
FROM tool_uses tu
JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
JOIN skill_windows sw
    ON tu.sessionId = sw.sessionId
    AND tu.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
WHERE tr.is_error = 'true'
GROUP BY tu.tool_name, error_content
ORDER BY occurrences DESC
LIMIT 15;
```

### 4. Stop hooks triggered during skill windows

```sql
WITH skill_windows AS (
    SELECT sessionId, timestamp,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
)
SELECT
    sh.level,
    sh.preventedContinuation,
    substr(sh.stopReason, 1, 100) AS reason,
    count(*) AS cnt
FROM stop_hooks sh
JOIN skill_windows sw
    ON sh.sessionId = sw.sessionId
    AND sh.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
GROUP BY sh.level, sh.preventedContinuation, reason
ORDER BY cnt DESC
LIMIT 10;
```

### 5. Error rate comparison (skill windows vs baseline)

```sql
WITH skill_windows AS (
    SELECT sessionId,
           timestamp::TIMESTAMP AS t_start,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t_end
    FROM skill_invocations
    WHERE skill_name = '{SKILL}'
),
in_window AS (
    SELECT
        count(*) AS total,
        sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) AS errors
    FROM tool_uses tu
    JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
    JOIN skill_windows sw
        ON tu.sessionId = sw.sessionId
        AND tu.timestamp::TIMESTAMP BETWEEN sw.t_start AND sw.t_end
),
baseline AS (
    SELECT
        count(*) AS total,
        sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) AS errors
    FROM tool_uses tu
    JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
)
SELECT
    'skill_window' AS scope,
    iw.total, iw.errors,
    round(iw.errors * 100.0 / nullif(iw.total, 0), 1) AS error_pct
FROM in_window iw
UNION ALL
SELECT
    'baseline' AS scope,
    b.total, b.errors,
    round(b.errors * 100.0 / nullif(b.total, 0), 1) AS error_pct
FROM baseline b;
```

### Output Format

```
## Friction Analytics: {SKILL}

### Error Summary
- Tool errors in skill windows: N / M total calls (X%)
- Baseline error rate: Y%
- Delta: +/- Z percentage points

### Error Breakdown by Tool
| Tool | Total | Errors | Error % |
|------|-------|--------|---------|
| ... | ... | ... | ... |

### Permission Denials
| Denial | Count |
|--------|-------|
| ... | ... |

### Common Errors
| Tool | Error | Count |
|------|-------|-------|
| ... | ... | ... |

### Hook Interruptions
| Level | Blocked? | Reason | Count |
|-------|----------|--------|-------|
| ... | ... | ... | ... |

### Findings
- [Friction patterns: high-error tools, repeated denials, hook conflicts]
```

---

## What the caller does NOT do

These packs gather data only. The caller (duckdb-expert / skill-improver) must not:

- Make improvement recommendations — `skill-improver` does that.
- Score findings — `skill-improver` scores.
- Read or judge the skill definition file (the `usage`/`friction` packs).
- Diagnose root causes of errors (the `friction` pack).
- Modify any files.
