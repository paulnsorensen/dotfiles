# Pack: routing-accuracy

# target_param: {SKILL}       (the router/entry skill, e.g. 'cheese')

# harness: respects harness; skill_invocations is claude-dominant

# owner: prompts

# signal: LOW — no intent ground-truth. Findings are correlational at most

Did a useful skill fire after a routing decision? `{SKILL}` is typically a
router (`cheese`) or any skill you want to check the downstream of. Run by
`duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> **Signal caveat (record in every digest):** there is no recorded "intended"
> skill, so we cannot prove the *right* skill fired — only what fired next. Every
> finding here is `<speculative>` at best. Do NOT claim a routing error without
> the downstream evidence, and prefer "insufficient signal".

## 1. What fires within 5 minutes after {SKILL}

```sql
WITH r AS (
    SELECT sessionId, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '5' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT si.skill_name AS downstream, count(*) AS n
FROM skill_invocations si JOIN r ON si.sessionId = r.sessionId
    AND si.timestamp::TIMESTAMP > r.t0 AND si.timestamp::TIMESTAMP <= r.t1
WHERE si.skill_name <> '{SKILL}'
GROUP BY downstream ORDER BY n DESC LIMIT 15;
```

## 2. Routings with NO downstream skill (possible dead-ends)

```sql
WITH r AS (
    SELECT sessionId, timestamp, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '5' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT count(*) AS routings_with_no_downstream
FROM r WHERE NOT EXISTS (
    SELECT 1 FROM skill_invocations si
    WHERE si.sessionId = r.sessionId AND si.skill_name <> '{SKILL}'
      AND si.timestamp::TIMESTAMP > r.t0 AND si.timestamp::TIMESTAMP <= r.t1
);
```

## 3. Same-skill re-fire within window (possible mis-route + retry)

```sql
WITH r AS (
    SELECT sessionId, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '5' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT count(*) AS immediate_refires
FROM skill_invocations si JOIN r ON si.sessionId = r.sessionId
    AND si.timestamp::TIMESTAMP > r.t0 AND si.timestamp::TIMESTAMP <= r.t1
WHERE si.skill_name = '{SKILL}';
```

## Output Format

```
## Routing Accuracy: {SKILL}   (correlational — no ground truth)

### Downstream Skills
| Downstream skill | Times |
|------------------|-------|

### Dead-ends
- Routings with no downstream skill: N of M

### Re-fires
- Immediate {SKILL} re-fires within 5 min: N

### Findings (all `<speculative>` at most)
- [Possible mis-routes: high dead-end rate, frequent re-fire]
- "Insufficient signal — no intent ground-truth" is the expected default.
```
