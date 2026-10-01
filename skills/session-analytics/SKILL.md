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

Interactive log queries, plus the data layer other analytics skills build on.
The contracts live in `references/`: `canonical-schema.md` (table shapes —
read before writing SQL), `harness-coverage.md`, `query-conventions.md`
(pack authoring for `duckdb-expert` packs), and
`calibration.md` (shared confidence/severity model).

Run `<skill-dir>/scripts/query.sh <report> [harness]`. Reports: `tools`,
`errors`, `mcp`, `skills`, `sessions`, `bash`, `denials`, `allowlist-gaps`,
`python3`, `hooks`, `compound`, `projects`, `heatmap`, `latency` (model
round-trips, batching, and quota stops per model). The script ingests
(1-hour TTL) and handles a missing/empty database itself.
The `latency` report is not a Codex inference-speed measurement. Codex native timing, user, model, and `event_msg` records are outside the canonical schema.

Anything not covered: `scripts/query.sh sql "SELECT ..."` with the canonical
schema. Chain queries; aim to answer within 5-8, then present intermediate
findings and ask before going deeper.

Presentation: lead with the answer; markdown tables for 3+ rows, a plain
number for single values; show the query only if the user may want to modify
it. Filter projects with `LIKE '%keyword%'` on `cwd` (full paths are verbose).

SQL gotchas (hand-written queries): `is_error` is VARCHAR `'true'`/`'false'`;
timestamps are VARCHAR — cast (`timestamp::TIMESTAMP`); `input` is JSON —
`json_extract_string()`; Cursor has no tool_results — exclude it from
error-rate queries; `-json` output returns all values as strings.
An empty latency report or zero errors is not evidence of speed or no failures. Inspect native Codex JSONL read-only when the canonical report lacks signal.
