# Query pack — reconstructing sub-agent runs

Backing queries for [[operations/subagent-dispatch-analytics]]. Run against
`${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/session-analytics/sessions.duckdb`.
First run `<session-analytics-dir>/scripts/ingest.py`.

## 1. Rebuild run trees from sidechain entries

Sub-agent turns are inlined in the parent transcript tagged `isSidechain`, not
stored as separate sessions. Walk `parentUuid` from each root to recover runs.

```sql
CREATE OR REPLACE TABLE agent_runs AS
WITH RECURSIVE roots AS (
  SELECT uuid AS root, uuid, sessionId, timestamp, message
  FROM raw_entries WHERE isSidechain AND (parentUuid IS NULL OR parentUuid = '')
), tree AS (
  SELECT root, uuid, sessionId, timestamp, message, 'user' AS type FROM roots
  UNION ALL
  SELECT t.root, e.uuid, e.sessionId, e.timestamp, e.message, e.type
  FROM raw_entries e
  JOIN tree t ON e.parentUuid = t.uuid AND e.sessionId = t.sessionId
  WHERE e.isSidechain
)
SELECT * FROM tree;
```

## 2. Label each run with its agent type and verbatim dispatch prompt

The root's first user message is the dispatch prompt; join it back to the
`Agent` tool call to recover `subagent_type`.

```sql
CREATE OR REPLACE TABLE run_meta AS
WITH rootmsg AS (
  SELECT root, sessionId, min(timestamp) AS t0,
    (SELECT json_extract_string(message, '$.content')
     FROM agent_runs a2 WHERE a2.uuid = a.root) AS prompt
  FROM agent_runs a GROUP BY root, sessionId
), disp AS (
  SELECT json_extract_string(input, '$.subagent_type') AS st,
         json_extract_string(input, '$.prompt') AS p
  FROM tool_uses WHERE tool_name = 'Agent'
)
SELECT rm.root, rm.sessionId, rm.t0, rm.prompt, d.st AS agent_type
FROM rootmsg rm
LEFT JOIN disp d ON rm.prompt LIKE d.p || '%' OR d.p LIKE rm.prompt || '%';
```

## 3. Flatten tool calls per run

```sql
CREATE OR REPLACE TABLE run_tools AS
SELECT ar.root, json_extract_string(u.value, '$.id') AS tuid,
       json_extract_string(u.value, '$.name') AS tname, ar.timestamp
FROM agent_runs ar, json_each(json_extract(ar.message, '$.content')) u
WHERE json_extract_string(u.value, '$.type') = 'tool_use';

CREATE OR REPLACE TABLE rt_ord AS
SELECT rt.*, m.agent_type,
       row_number() OVER (PARTITION BY rt.root ORDER BY rt.timestamp, rt.tuid) AS seq
FROM run_tools rt JOIN run_meta m USING (root);
```

## 4. Out-of-context rate by dispatch size

```sql
WITH last AS (
  SELECT root, message,
         row_number() OVER (PARTITION BY root ORDER BY timestamp DESC) AS rn
  FROM agent_runs WHERE type = 'assistant'
), ooc AS (
  SELECT m.root, length(m.prompt) AS plen,
         regexp_matches(l.message::VARCHAR, '(?i)status: blocked: out of (context|turn)')::INT AS ooc
  FROM last l JOIN run_meta m USING (root)
  WHERE l.rn = 1 AND m.agent_type = 'coder'
)
SELECT CASE WHEN plen < 2500 THEN 'a <2.5k'
            WHEN plen < 4000 THEN 'b 2.5-4k'
            WHEN plen < 6000 THEN 'c 4-6k'
            ELSE 'd >6k' END AS bucket,
       count(*) AS runs, sum(ooc) AS out_of_context,
       round(100.0 * avg(ooc), 1) AS ooc_pct
FROM ooc GROUP BY 1 ORDER BY 1;
```

## 5. Exploration before first write

```sql
WITH fw AS (
  SELECT root, min(seq) AS fwq FROM rt_ord
  WHERE agent_type = 'coder'
    AND tname IN ('mcp__tilth__tilth_write', 'Write', 'Edit', 'mcp__serena__replace_content')
  GROUP BY 1
), tot AS (
  SELECT root, max(seq) AS n FROM rt_ord WHERE agent_type = 'coder' GROUP BY 1
)
SELECT count(*) AS coder_runs,
       sum(CASE WHEN fw.fwq IS NULL THEN 1 ELSE 0 END) AS runs_with_zero_writes,
       round(median(fw.fwq - 1)) AS med_tools_before_first_write,
       round(median((fw.fwq - 1) * 100.0 / tot.n), 1) AS med_pct_budget_exploring
FROM tot LEFT JOIN fw USING (root);
```

## 6. File-I/O routing compliance

```sql
SELECT m.agent_type,
  sum(CASE WHEN r.tname = 'Bash'
        AND regexp_matches(tu.bash_cmd, '^(rtk )?(grep|cat|sed|find|ls|rg|awk|head|tail|wc|tree)( |$)')
      THEN 1 ELSE 0 END) AS shell_fileio,
  sum(CASE WHEN r.tname IN ('Read','Grep','Glob','Edit','Write') THEN 1 ELSE 0 END) AS builtin_fileio,
  sum(CASE WHEN r.tname LIKE 'mcp__tilth%' THEN 1 ELSE 0 END) AS tilth,
  count(*) AS total
FROM rt_ord r
JOIN run_meta m USING (root)
LEFT JOIN tool_uses tu ON r.tuid = tu.tool_use_id
WHERE m.agent_type IN ('coder','reviewer','explorer','researcher')
GROUP BY 1 ORDER BY total DESC;
```

## 7. tool-reroute hook catch rate

Mirrors the fall-through predicates in `agents/lib/tool-reroute/search.js`
(regex metacharacter in pattern, long flag, exotic short flag, pipe/redirect).

```sql
WITH g AS (
  SELECT m.agent_type, tu.bash_cmd AS c
  FROM rt_ord r JOIN run_meta m USING (root)
  JOIN tool_uses tu ON r.tuid = tu.tool_use_id
  WHERE r.tname = 'Bash' AND regexp_matches(tu.bash_cmd, '^(grep|rg|ag|ack|find) ')
)
SELECT agent_type, count(*) AS total_search_calls,
  sum(CASE WHEN NOT regexp_matches(c, '[|;&><]')
            AND NOT regexp_matches(c, ' --')
            AND NOT regexp_matches(c, ' -[a-zA-Z]*[lLcovwxEPABCefmiI]')
            AND NOT regexp_matches(regexp_extract(c, '^\w+ (?:-\S+ )*([^ ]+)', 1),
                                   '[\\.^$*+?()\[\]{}|]')
      THEN 1 ELSE 0 END) AS would_rewrite
FROM g GROUP BY 1 ORDER BY total_search_calls DESC;
```

## Gotchas

- `raw_entries.filename` is NULL for the Claude harness — use `isSidechain`, not
  a path filter, to find sub-agent turns.
- `tool_results.content` is truncated at 500 chars during ingest, so byte totals
  are floors. Use call counts for context-consumption estimates, not sums.
- `is_error` is VARCHAR `'true'`/`'false'`.
- Correlated subqueries over `agent_runs` are slow enough to time out; materialize
  `run_tools` / `rt_ord` first and join.
