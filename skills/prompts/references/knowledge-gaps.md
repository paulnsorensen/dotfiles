# Pack: knowledge-gaps

# target_param: {KEYWORD}     (a topic substring; '%' to scan broadly)

# harness: respects harness=<all|claude|codex|opencode>

# owner: prompts

# signal: MEDIUM — a recurring topic is not proof of a missing capability

Topics that recur in user prompts without a resolving skill/tool — candidate
gaps where a new skill or doc might help. Run by `duckdb-expert`, one spawn.
Schema: `skills/session-analytics/references/canonical-schema.md`.

> **Signal caveat (record in every digest):** this is inference, not
> measurement. A topic recurring across sessions *suggests* a gap; it does not
> prove one (the user may resolve it manually, or it may be one-off context).
> Tag findings `<speculative>` and degrade to "insufficient signal" when counts
> are low.

## 1. Recurring freeform-prompt keywords matching the topic

```sql
WITH prompts AS (
    SELECT sessionId, json_extract_string(message, '$.content') AS txt
    FROM raw_entries
    WHERE type = 'user' AND message IS NOT NULL
      AND json_type(json_extract(message, '$.content')) = 'VARCHAR'
)
SELECT count(*) AS mentions, count(DISTINCT sessionId) AS sessions
FROM prompts
WHERE txt NOT LIKE '/%' AND lower(txt) LIKE lower('%{KEYWORD}%');
```

## 2. Did any skill fire in sessions that mention the topic?

```sql
WITH topic_sessions AS (
    SELECT DISTINCT sessionId
    FROM raw_entries
    WHERE type = 'user' AND message IS NOT NULL
      AND json_type(json_extract(message, '$.content')) = 'VARCHAR'
      AND lower(json_extract_string(message, '$.content')) LIKE lower('%{KEYWORD}%')
)
SELECT si.skill_name, count(*) AS fired
FROM skill_invocations si JOIN topic_sessions t ON si.sessionId = t.sessionId
GROUP BY si.skill_name ORDER BY fired DESC LIMIT 15;
```

## 3. Repeated-question proxy: same opener shape across sessions

```sql
WITH openers AS (
    SELECT json_extract_string(message, '$.content') AS txt,
           row_number() OVER (PARTITION BY sessionId ORDER BY timestamp) AS rn
    FROM raw_entries
    WHERE type = 'user' AND message IS NOT NULL
      AND json_type(json_extract(message, '$.content')) = 'VARCHAR'
)
SELECT substr(lower(txt), 1, 50) AS opener_prefix, count(*) AS sessions
FROM openers WHERE rn = 1 AND txt NOT LIKE '/%'
GROUP BY opener_prefix HAVING count(*) >= 3
ORDER BY sessions DESC LIMIT 15;
```

## Output Format

```
## Knowledge Gaps: {KEYWORD}   (medium signal — inference, not proof)

### Topic Recurrence
- Mentions: N across N sessions

### Coverage
- Skills that fired in topic sessions: <list or "none">
- If a topic recurs but no skill fires → candidate gap.

### Repeated Openers
| Opener prefix | Sessions |
|---------------|----------|

### Findings (tagged `<speculative>`)
- [Candidate missing skills/docs; recurring manual workflows]
- "Insufficient signal" when mentions < 3 sessions.
```
