# Pack: prompt-analysis

# target_param: {KEYWORD}     (a substring to focus on; '%' for all prompts)

# harness: respects harness=<all|claude|codex|opencode>

# owner: prompts

Recurring user-prompt shapes, repeated asks, and session openers. A "user
prompt" is a user message whose content is plain text (not a tool_result
array). Run by `duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> User text prompts live in `raw_entries` where `type='user'` and
> `json_type(message->'$.content') = 'VARCHAR'`. Apply the harness filter.

## 1. Prompt volume + slash-command vs freeform split

```sql
WITH prompts AS (
    SELECT json_extract_string(message, '$.content') AS txt, sessionId, timestamp
    FROM raw_entries
    WHERE type = 'user' AND message IS NOT NULL
      AND json_type(json_extract(message, '$.content')) = 'VARCHAR'
)
SELECT
    CASE WHEN txt LIKE '/%' THEN 'slash-command' ELSE 'freeform' END AS shape,
    count(*) AS n
FROM prompts
WHERE txt LIKE '%{KEYWORD}%'
GROUP BY shape;
```

## 2. Most-used slash commands

```sql
SELECT lower(split_part(trim(json_extract_string(message, '$.content')), ' ', 1)) AS cmd,
       count(*) AS uses
FROM raw_entries
WHERE type = 'user' AND message IS NOT NULL
  AND json_type(json_extract(message, '$.content')) = 'VARCHAR'
  AND trim(json_extract_string(message, '$.content')) LIKE '/%'
GROUP BY cmd ORDER BY uses DESC LIMIT 20;
```

## 3. Session openers (first user prompt per session)

```sql
WITH prompts AS (
    SELECT sessionId, timestamp,
           json_extract_string(message, '$.content') AS txt,
           row_number() OVER (PARTITION BY sessionId ORDER BY timestamp) AS rn
    FROM raw_entries
    WHERE type = 'user' AND message IS NOT NULL
      AND json_type(json_extract(message, '$.content')) = 'VARCHAR'
)
SELECT substr(txt, 1, 80) AS opener, count(*) AS n
FROM prompts WHERE rn = 1
GROUP BY opener ORDER BY n DESC LIMIT 15;
```

## Output Format

```
## Prompt Analysis: {KEYWORD}

### Shape
- Slash-command prompts: N  ·  Freeform: N

### Top Slash Commands
| Command | Uses |
|---------|------|

### Common Openers
| Opener (truncated) | Count |
|--------------------|-------|

### Findings
- [Repeated manual asks that a skill could automate; opener patterns]
- "Insufficient signal" if prompt volume is low.
```
