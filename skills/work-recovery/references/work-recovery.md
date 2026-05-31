# Pack: work-recovery

# target_param: {SESSION}     (a sessionId)

# harness: respects harness=<all|claude|codex|opencode>

# owner: work-recovery (report-only)

Reconstructs the working state of one session: goal, files touched, last
verified state, next step. Run by `duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`. **No scoring** — this
pack only reconstructs.

> Match on `sessionId = '{SESSION}'`. The harness filter is usually redundant
> once a session is pinned, but apply it if given.

## 1. Goal — opening user prompts (chronological)

```sql
SELECT timestamp, substr(json_extract_string(message, '$.content'), 1, 300) AS prompt
FROM raw_entries
WHERE sessionId = '{SESSION}' AND type = 'user' AND message IS NOT NULL
  AND json_type(json_extract(message, '$.content')) = 'VARCHAR'
ORDER BY timestamp LIMIT 5;
```

## 2. Files touched (reads vs edits/writes)

```sql
SELECT file_path,
       sum(CASE WHEN tool_name = 'Read' THEN 1 ELSE 0 END) AS reads,
       sum(CASE WHEN tool_name IN ('Edit','Write','MultiEdit','NotebookEdit') THEN 1 ELSE 0 END) AS writes
FROM tool_uses
WHERE sessionId = '{SESSION}' AND file_path IS NOT NULL
GROUP BY file_path ORDER BY writes DESC, reads DESC LIMIT 25;
```

## 3. Last verified state — last test/build/git commands

```sql
SELECT timestamp, substr(bash_cmd, 1, 120) AS cmd
FROM tool_uses
WHERE sessionId = '{SESSION}' AND tool_name = 'Bash' AND bash_cmd IS NOT NULL
  AND (bash_cmd LIKE '%test%' OR bash_cmd LIKE '%build%' OR bash_cmd LIKE '%cargo%'
       OR bash_cmd LIKE '%pytest%' OR bash_cmd LIKE '%bats%' OR bash_cmd LIKE 'git %'
       OR bash_cmd LIKE '%just %')
ORDER BY timestamp DESC LIMIT 10;
```

## 4. Next step — the last few actions taken

```sql
SELECT timestamp, tool_name,
       coalesce(substr(bash_cmd, 1, 80), file_path, skill_name, agent_type) AS detail
FROM tool_uses
WHERE sessionId = '{SESSION}'
ORDER BY timestamp DESC LIMIT 10;
```

## Output Format

```
## Work Recovery: {SESSION}

### Goal (quoted from opening prompts)
- "<first prompt, truncated>"

### Files Touched
| File | Reads | Edits/Writes |
|------|-------|--------------|

### Last Verified State
| When | Command |
|------|---------|
- (or "no test/build/git command recorded")

### Next Step (last actions, reverse-chronological)
| When | Tool | Detail |
|------|------|--------|
- The single most likely next action, stated plainly.
```
