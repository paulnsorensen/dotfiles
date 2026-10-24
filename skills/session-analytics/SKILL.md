---
name: session-analytics
description: >
  Query coding-agent session logs (Claude, Codex, oh-my-pi, Cursor) via DuckDB.
  Use for /session-analytics or questions about tool/skill/agent usage across
  past sessions.
model: sonnet
effort: medium
allowed-tools: Bash, Read
---

# session-analytics

Interactive log queries and report SQL for the published `agent-session-analytics` package.
The package owns log discovery, ingestion, database placement, and the canonical schema.
Read its current schema with `uvx agent-session-analytics==0.2.0 schema` before writing SQL.
The local `references/` files explain report use, coverage limits, query conventions,
and calibration. They do not define the engine contract.

Run `<skill-dir>/scripts/query.sh <report> [harness]`. Reports: `tools`,
`errors`, `mcp`, `skills`, `sessions`, `bash`, `denials`, `allowlist-gaps`,
`python3`, `hooks`, `compound`, `projects`, `heatmap`, `latency` (model
round-trips, batching, and quota stops per model). The script uses the package's
one-hour freshness check and reports a missing database as a failure.
Use `uvx agent-session-analytics==0.2.0 ingest --force` to rebuild explicitly.
The `latency` report is not a Codex inference-speed measurement. Codex timing and user records stay omitted. The ingest keeps `token_count` events and `cli_version`. Codex `tool_calls` and `stop_reason` are NULL.

Anything not covered: `scripts/query.sh sql "SELECT ..."` with the canonical
schema. Chain queries; aim to answer within 5-8, then present intermediate
findings and ask before going deeper.

Presentation: lead with the answer; markdown tables for 3+ rows, a plain
number for single values; show the query only if the user may want to modify
it. Filter projects with `LIKE '%keyword%'` on `cwd` (full paths are verbose).

SQL gotchas (hand-written queries): `is_error` is VARCHAR `'true'`/`'false'`;
timestamps are VARCHAR — cast (`timestamp::TIMESTAMP`); `input` is JSON —
`json_extract_string()`; Cursor has no tool_results — exclude it from
error-rate queries; DuckDB `-json` preserves booleans and numbers.
An empty latency report or zero errors is not evidence of speed or no failures. Inspect native Codex JSONL read-only when the canonical report lacks signal.
