# Pack: session-shape

# target_param: {PROJECT}     (a project/cwd substring; '%' for all recent)

# harness: respects harness=<all|claude|codex|opencode>

# owner: work-recovery (report-only)

Recent sessions, their timeline, and size — used to pick a recovery target. Run
by `duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`. **No scoring** — this
pack only describes.

> Apply the harness filter. Match the project substring on `project` (cwd).

## 1. Recent sessions (most recent first)

```sql
SELECT harness, sessionId,
       regexp_extract(project, '.*/([^/]+)$', 1) AS proj,
       branch, first_seen, last_seen, entry_count
FROM sessions
WHERE project LIKE '%{PROJECT}%'
ORDER BY last_seen DESC LIMIT 20;
```

## 2. Activity volume per session (tool calls)

```sql
SELECT s.sessionId,
       regexp_extract(s.project, '.*/([^/]+)$', 1) AS proj,
       (SELECT count(*) FROM tool_uses tu WHERE tu.sessionId = s.sessionId) AS tool_calls
FROM sessions s
WHERE s.project LIKE '%{PROJECT}%'
ORDER BY tool_calls DESC LIMIT 20;
```

## 3. Last activity timestamp (staleness)

```sql
SELECT sessionId, max(timestamp) AS last_activity
FROM tool_uses
WHERE cwd LIKE '%{PROJECT}%'
GROUP BY sessionId ORDER BY last_activity DESC LIMIT 20;
```

## Output Format

```
## Session Shape: {PROJECT}

### Recent Sessions
| Harness | Session (short) | Project | Branch | Span | Entries |
|---------|-----------------|---------|--------|------|---------|

### Busiest (by tool calls)
| Session (short) | Project | Tool calls |
|-----------------|---------|-----------|

### Notes
- Highlight the most recent / most active session as the likely recovery target.
- "No sessions match" if empty — do not invent.
```
