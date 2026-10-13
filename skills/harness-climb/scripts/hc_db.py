"""Session-database access for harness-climb: path, refresh, and DuckDB queries."""

from __future__ import annotations

import functools
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from hc_core import InputError
from hc_stats import HARNESSES

SKILLS_DIR = Path(__file__).resolve().parents[2]
DB_PATH_SH = SKILLS_DIR / "session-analytics" / "scripts" / "db-path.sh"
INGEST_PY = SKILLS_DIR / "session-analytics" / "scripts" / "ingest.py"
IN_SCOPE = f"harness IN ({','.join(repr(h) for h in HARNESSES)})"

INGEST_TIMEOUT_S = 600


class DbError(ValueError):
    """The session database or its environment failed. The caller's input is not at fault."""


class VersionUnavailable(DbError):
    """The session database has no harness version column."""


class SchemaOutdated(DbError):
    """The session database predates the columns that the field gate reads."""


class RefreshFailed(DbError):
    """The ingest that refreshes the session database failed or timed out."""


def ensure_fresh_db() -> bool:
    """Refresh the session database with the TTL-aware ingest. True when it is fresh.

    `SESSIONS_DB` skips the ingest and counts as fresh.
    """
    if os.environ.get("SESSIONS_DB"):
        return True
    try:
        proc = subprocess.run(
            [sys.executable, str(INGEST_PY)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=INGEST_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


@functools.cache
def _settings_for(
    sessions_db: str, cache_home: str, home: str, limit: str, cwd: str
) -> tuple[Path, str]:
    """The database path and DuckDB memory limit, from one call to the shared resolver.

    The arguments are the environment the resolver reads. They key the cache.
    """
    proc = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1" && sessions_db_path && sessions_duckdb_memory_limit',
            "_",
            str(DB_PATH_SH),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    lines = proc.stdout.strip().splitlines()
    if proc.returncode != 0 or len(lines) < 2:
        raise DbError(f"cannot resolve the session database: {proc.stderr.strip()}")
    return Path(lines[0].strip()), lines[1].strip()


def _shell_settings() -> tuple[Path, str]:
    env = os.environ.get
    return _settings_for(
        env("SESSIONS_DB", ""),
        env("XDG_CACHE_HOME", ""),
        env("HOME", ""),
        env("SESSIONS_DUCKDB_MEMORY_LIMIT", ""),
        os.getcwd(),
    )


def resolve_db() -> Path:
    """The session database path, from the shared session-analytics resolver only.

    Every caller reads the database next, so a stale one is refreshed here first.
    """
    if not ensure_fresh_db():
        raise RefreshFailed("session database refresh failed")
    return _shell_settings()[0]


def duck(db: Path, sql: str) -> list[dict[str, Any]]:
    limit = _shell_settings()[1]
    try:
        proc = subprocess.run(
            [
                "duckdb",
                "-init",
                "/dev/null",
                "-readonly",
                str(db),
                "-cmd",
                f"SET memory_limit='{limit}'",
                "-json",
                "-c",
                sql,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise DbError("duckdb not installed") from exc
    if proc.returncode != 0:
        raise InputError(f"duckdb failed: {proc.stderr.strip()[:300]}")
    text = proc.stdout.strip()
    return json.loads(text) if text else []


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
            "session database predates parent_session_id/context_tokens; re-run ingest.py --force"
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
