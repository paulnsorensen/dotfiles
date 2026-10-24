"""Session-database access for harness-climb: path, refresh, and DuckDB queries."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from hc_core import InputError
from hc_stats import HARNESSES

PACKAGE = ("uvx", "agent-session-analytics==0.2.0")
IN_SCOPE = f"harness IN ({','.join(repr(h) for h in HARNESSES)})"
PACKAGE_TIMEOUT_S = 600


class DbError(ValueError):
    """The session database or its environment failed. The caller's input is not at fault."""


class VersionUnavailable(DbError):
    """The session database has no harness version column."""


class SchemaOutdated(DbError):
    """The session database predates the columns that the field gate reads."""


class RefreshFailed(DbError):
    """The ingest that refreshes the session database failed or timed out."""


def _package(*args: str, db: Path | None = None) -> Any:
    env = os.environ.copy()
    if db is not None:
        env["SESSIONS_DB"] = str(db)
    try:
        proc = subprocess.run(
            [*PACKAGE, *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=PACKAGE_TIMEOUT_S,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DbError("session analytics package unavailable") from exc
    if proc.returncode:
        if args[0] == "sql" and proc.returncode == 5:
            raise InputError("session analytics SQL rejected")
        raise DbError("session analytics database unavailable")
    try:
        return json.loads(proc.stdout)
    except (TypeError, ValueError) as exc:
        raise DbError("session analytics returned invalid JSON") from exc


def ensure_fresh_db() -> bool:
    """Let package SQL refresh its default database before readers start."""
    if os.environ.get("SESSIONS_DB"):
        return True
    try:
        rows = _package("sql", "SELECT 1 AS ready")
    except DbError:
        return False
    return rows == [{"ready": 1}]


def resolve_db() -> Path:
    """Return the package-resolved path after its default database refresh."""
    if not ensure_fresh_db():
        raise RefreshFailed("session database refresh failed")
    result = _package("db-path")
    if not isinstance(result, dict):
        raise DbError("session analytics returned an invalid database path")
    path = result.get("path")
    if not isinstance(path, str) or not path or not Path(path).is_absolute():
        raise DbError("session analytics returned an invalid database path")
    return Path(path)


def duck(db: Path, sql: str) -> list[dict[str, Any]]:
    rows = _package("sql", "--", sql, db=db)
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise DbError("session analytics returned invalid SQL rows")
    return rows


def load_rows(
    db: Path, gate: dict[str, Any], start: float, end: float
) -> list[dict[str, Any]]:
    """Per-session rows for claude and codex between `start` and `end`."""
    has_version = duck(
        db,
        "SELECT count(*) AS n FROM information_schema.columns WHERE table_name = 'sessions' AND column_name = 'version'",
    )[0]["n"]
    if not has_version:
        raise VersionUnavailable("sessions table has no version column")
    current = duck(
        db,
        "SELECT count(*) AS n FROM information_schema.columns WHERE (table_name = 'sessions' AND column_name = 'parent_session_id') OR (table_name = 'model_turns' AND column_name = 'context_tokens')",
    )[0]["n"]
    if current != 2:
        raise SchemaOutdated(
            f"session database predates parent_session_id/context_tokens; run {' '.join(PACKAGE)} ingest --force"
        )
    version = "arg_max(version, last_seen) FILTER (WHERE version IS NOT NULL)"
    query = gate["targeted_query"].strip().rstrip(";")
    sql = f"""
    WITH s AS (
        SELECT harness, sessionId, epoch(CAST(min(first_seen) AS TIMESTAMPTZ)) AS start, {version} AS version
        FROM sessions WHERE {IN_SCOPE} GROUP BY harness, sessionId
        HAVING max(parent_session_id) IS NULL),
    tg AS (SELECT harness, sessionId, avg(value) AS target FROM ({query}) AS q GROUP BY harness, sessionId),
    er AS (SELECT harness, sessionId, avg(CASE WHEN is_error = 'true' THEN 1.0 ELSE 0.0 END) AS tool_error_rate
           FROM tool_results WHERE {IN_SCOPE} GROUP BY harness, sessionId),
    pd AS (SELECT harness, sessionId, count(*) AS permission_denials FROM permission_denials GROUP BY harness, sessionId),
    sh AS (SELECT harness, sessionId, count(*) AS stop_hook_blocks FROM stop_hooks WHERE preventedContinuation GROUP BY harness, sessionId),
    tk AS (SELECT harness, sessionId, avg(coalesce(context_tokens, 0) + coalesce(output_tokens, 0)) AS tokens_per_turn
           FROM model_turns WHERE {IN_SCOPE} GROUP BY harness, sessionId)
    SELECT s.harness, s.sessionId AS session, s.start, s.version, tg.target, er.tool_error_rate,
           coalesce(pd.permission_denials, 0) AS permission_denials,
           coalesce(sh.stop_hook_blocks, 0) AS stop_hook_blocks, tk.tokens_per_turn
    FROM s LEFT JOIN tg USING (harness, sessionId) LEFT JOIN er USING (harness, sessionId)
    LEFT JOIN pd USING (harness, sessionId) LEFT JOIN sh USING (harness, sessionId)
    LEFT JOIN tk USING (harness, sessionId)
    WHERE s.start >= {float(start)} AND s.start < {float(end)}
    """
    return duck(db, sql)
