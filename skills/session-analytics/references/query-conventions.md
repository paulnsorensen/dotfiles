# Query & Pack-Authoring Conventions

Conventions every analytics **pack** relies on. A pack is a skill-owned file at
`skills/<skill>/references/<domain>.md` describing one analytics domain. The
`duckdb-expert` agent runs exactly one pack per spawn, reading the *queries* from
the pack and the *schema* from `canonical-schema.md` (in this data layer).

## Pack file shape

```
# Pack: <domain>
# target_param: {SKILL|TOOL|AGENT|...}   — the placeholder queries substitute
# harness: <how the pack uses the harness filter>
# queries: ordered list of {name, sql}   — sql references the canonical schema
# output_format: a markdown template the digest fills

## 1. <query name>
```sql
SELECT ... FROM tool_uses WHERE ... ;
```

...

## Output Format

```
<markdown template — what the ~2 KB digest looks like>
```

```

Keep a pack to ~4-6 queries. The digest the agent returns must fit ~2 KB.

## Harness filtering

Every spawn carries a `harness=<all|claude|codex|opencode|cursor|copilot>`
parameter. In pack SQL:

- `harness='all'` → omit the harness predicate (aggregate every reachable source).
- a specific harness → add `WHERE harness = '<name>'` (or `AND harness = ...`).

State in the pack header which mode it expects. Domains that depend on
claude-only fields (`stop_hooks`, `permission_denials`, `skill_invocations`,
`agent_spawns`) should say so and degrade to "insufficient signal" on other
harnesses rather than report zero as if it were meaningful.

## Substitution

Queries use a single placeholder named in `target_param` (e.g. `{SKILL}`,
`{TOOL}`, `{AGENT}`). The caller substitutes the literal target before running.
Quote it as a string literal in SQL (`WHERE skill_name = '{SKILL}'`).

## Empty results

If a query returns `[]`, note "no data" for that section and continue — never
block on one empty result. A pack that returns all-empty should say
"insufficient signal", not invent findings.

## Running queries

All queries go through the CLI:

```bash
duckdb ~/.claude/analytics/sessions.duckdb -json -c "SQL"
```

Ensure the DB exists first (`python3 <session-analytics>/scripts/ingest.py`;
1-hour TTL, fast if cached). `-json` for machine-readable output.

## Signal-quality honesty

Three domains are known low/medium-signal and must degrade gracefully:

- `token-economics` — token/cost fields are usually absent from logs.
- `routing-accuracy` — no intent ground-truth exists; correlational at best.
- `knowledge-gaps` — medium-signal inference.

Record the caveat in the pack and emit "insufficient signal" rather than
fabricate a confident finding. This pairs with the confidence axis in
`calibration.md` (`<don't know>` is never surfaced).
