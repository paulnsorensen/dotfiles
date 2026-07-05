# Pack: token-economics

# target_param: {TOOL}        (a tool/server; '%' for all)

# harness: depends entirely on whether the harness logs token fields

# owner: tool-efficiency

# signal: MIXED — real per-turn signal on claude; none on harnesses that omit usage

Token accounting per session/turn — **only where the logs record it**. Run by
`duckdb-expert`, one spawn. Schema:
`skills/session-analytics/references/canonical-schema.md`.

> **Signal caveat (record in every digest):** token data is **per assistant turn,
> not per tool call** — claude logs carry a rich `message.usage`
> (`input_tokens`, `output_tokens`, `cache_*`), so claude-scoped findings are
> real; codex `token_count` events are session-level rate-limit info (no per-turn
> cost) and opencode usage is not surfaced by the current adapter, so on those
> harnesses this degrades to `<don't know>` / "insufficient signal". The
> canonical schema does not materialize a token column — query
> `raw_entries.message.usage` directly. Do NOT estimate cost from token counts
> (no price table here); report token volume, not dollars — see the platform
> spec's non-goal.

## 1. Probe: does raw_entries carry any usage payload?

```sql
SELECT harness,
       count(*) FILTER (WHERE json_extract(message, '$.usage') IS NOT NULL) AS with_usage,
       count(*) AS total
FROM raw_entries
WHERE message IS NOT NULL
GROUP BY harness;
```

## 2. If usage exists, total tokens per session (claude shape)

```sql
-- Only meaningful if probe (1) shows with_usage > 0. Otherwise skip.
SELECT sessionId,
    sum(CAST(json_extract_string(message, '$.usage.input_tokens') AS BIGINT)) AS input_tokens,
    sum(CAST(json_extract_string(message, '$.usage.output_tokens') AS BIGINT)) AS output_tokens,
    sum(CAST(json_extract_string(message, '$.usage.cache_read_input_tokens') AS BIGINT)) AS cache_read
FROM raw_entries
WHERE type = 'assistant' AND json_extract(message, '$.usage') IS NOT NULL
GROUP BY sessionId ORDER BY output_tokens DESC LIMIT 10;
```

## 3. Proxy: call volume as a cost stand-in (last resort, labelled)

```sql
SELECT tool_name, count(*) AS calls
FROM tool_uses
WHERE tool_name LIKE '{TOOL}'
GROUP BY tool_name ORDER BY calls DESC LIMIT 15;
```

## Output Format

```
## Token Economics: {TOOL}

### Signal Check
- Usage fields present in logs: yes / no  (per harness)
- claude usually yes (per-turn); codex/opencode usually no → "insufficient signal".

### Token Aggregates (only if usage present — per session, NOT per tool)
| Session | Input | Output | Cache read |
|---------|-------|--------|-----------|

### Call-Volume Proxy (labelled NOT cost)
| Tool | Calls |
|------|-------|

### Findings
- Token volume only — never a dollar estimate. Surface real findings when probe
  (1) returns with_usage > 0 (typically claude); else "insufficient signal".
```
