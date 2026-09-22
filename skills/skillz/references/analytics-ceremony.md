# Analytics ceremony (`audit`, `self-update`)

Empirical usage data, best-effort.
When the database, the logs, or ingestion is missing or fails, drop the Usage lens and say so in the report.
Never block the audit on it.

1. Resolve the installed `session-analytics` skill directory from its loaded `SKILL.md` path.
2. Compute the database path with the scripts' resolver: `$SESSIONS_DB` when set; else `$XDG_CACHE_HOME/dotfiles/session-analytics/sessions.duckdb` when `XDG_CACHE_HOME` is absolute; else `~/.cache/dotfiles/session-analytics/sessions.duckdb`.
3. Dispatch **one `duckdb-expert` per pack**, in parallel, read-only. Pass absolute paths for everything; the agent applies no defaults.

   ```text
   Run analytics pack <abs-pack> for target <name>. harness=all
   pack=<abs-pack> schema=<abs-schema> conventions=<abs-conventions>
   ingest=<abs-ingest> database=<abs-database>
   ```

   Each spawn returns one ~2 KB digest. Do not collapse to one all-domains spawn.

   | Pack | Reveals |
   |---|---|
   | `skill-usage.md` | invocations, declared-vs-actual tool use, permission friction |
   | `agent-orchestration.md` | undeclared spawns, fork behavior, error rate |
   | `drift-regression.md` | declining usage, single-project concentration, hook interruptions |

4. Carry the digests into the Usage lens.

Contract paths: schema `skills/session-analytics/references/canonical-schema.md`, conventions `skills/session-analytics/references/query-conventions.md`, ingest `skills/session-analytics/scripts/ingest.py`.

Signal caveats: `skill_invocations` and `agent_spawns` are Claude-dominant; Codex and OMP lack hook and permission-denial rows; Cursor has no tool results. Read `skills/session-analytics/references/harness-coverage.md` before quoting a cross-harness comparison.
