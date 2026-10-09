"""Session database: the pre-read refresh and the production load_rows SQL."""

from __future__ import annotations

import argparse
import json
import os
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from .support import (
    DAY,
    HAVE_DUCKDB,
    T0,
    RepoCase,
    call,
    gate_json,
    hc_db,
    hc_denylist,
    hc_field_gate,
    make_db,
)

AFTER = T0 + DAY
SESSIONS_DDL = (
    "CREATE TABLE sessions (harness VARCHAR, sessionId VARCHAR, first_seen VARCHAR, "
    "last_seen VARCHAR, project VARCHAR, branch VARCHAR, version VARCHAR, entry_count BIGINT)"
)
OTHER_DDL = (
    (
        "CREATE TABLE tool_results (harness VARCHAR, tool_use_id VARCHAR, content VARCHAR, "
        "is_error VARCHAR, is_error_explicit BOOLEAN, timestamp VARCHAR, sessionId VARCHAR)"
    ),
    "CREATE TABLE permission_denials (harness VARCHAR, content VARCHAR, sessionId VARCHAR, timestamp VARCHAR)",
    (
        "CREATE TABLE stop_hooks (harness VARCHAR, timestamp VARCHAR, sessionId VARCHAR, hookCount BIGINT, "
        "hookInfos VARCHAR, hookErrors VARCHAR, preventedContinuation BOOLEAN, stopReason VARCHAR, "
        "hasOutput BOOLEAN, level VARCHAR)"
    ),
    (
        "CREATE TABLE model_turns (harness VARCHAR, model VARCHAR, stop_reason VARCHAR, "
        "input_tokens BIGINT, output_tokens BIGINT, timestamp VARCHAR, sessionId VARCHAR, cwd VARCHAR)"
    ),
)


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def q(value: str | None) -> str:
    return "NULL" if value is None else "'" + value.replace("'", "''") + "'"


def session_row(
    harness: str, sid: str, first: float, last: float, version: str | None, entries: int
) -> str:
    return (
        f"INSERT INTO sessions VALUES ({q(harness)}, {q(sid)}, {q(iso(first))}, "
        f"{q(iso(last))}, '/p', 'b', {q(version)}, {entries})"
    )


class EnsureFreshDbTests(unittest.TestCase):
    def test_ingest_runs_when_no_sessions_db_override_is_set(self) -> None:
        env = {k: v for k, v in os.environ.items() if k != "SESSIONS_DB"}
        with (
            mock.patch.dict(os.environ, env, clear=True),
            mock.patch.object(hc_db.subprocess, "run") as run,
        ):
            hc_db.ensure_fresh_db()
        ((args, _),) = run.call_args_list
        self.assertEqual(args[0], [sys.executable, str(hc_db.INGEST_PY)])
        self.assertNotIn("--force", args[0])
        self.assertTrue(Path(hc_db.INGEST_PY).is_file())

    def test_sessions_db_override_skips_the_ingest(self) -> None:
        with (
            mock.patch.dict(os.environ, {"SESSIONS_DB": "/tmp/x.duckdb"}),
            mock.patch.object(hc_db.subprocess, "run") as run,
        ):
            hc_db.ensure_fresh_db()
        run.assert_not_called()

    def test_every_database_reader_refreshes_first(self) -> None:
        absent = str(Path(os.environ["SESSIONS_DB"]).with_name("never.duckdb"))
        with (
            mock.patch.dict(os.environ, {"SESSIONS_DB": absent}),
            mock.patch.object(hc_db, "ensure_fresh_db") as fresh,
        ):
            rc, out = call(
                "analyze",
                "--repo",
                "/tmp",
                "--thread",
                "t1",
                "--state-dir",
                "/tmp/hc-none",
            )
            self.assertEqual((rc, out["status"]), (1, "no-db"))
            self.assertEqual(fresh.call_count, 1)
            args = argparse.Namespace(denylist=None)
            self.assertIsNone(hc_denylist.load_denylist(args, Path("/tmp/repo")))
            self.assertEqual(fresh.call_count, 2)


@unittest.skipUnless(HAVE_DUCKDB, "duckdb CLI not installed")
class LoadRowsTests(RepoCase):
    def build(self, *extra: str, sessions_ddl: str = SESSIONS_DDL) -> Path:
        return make_db(self.dir / "s.duckdb", sessions_ddl, *OTHER_DDL, *extra)

    def test_load_rows_computes_per_session_values_from_the_ingest_schema(self) -> None:
        t = AFTER + 100
        db = self.build(
            # s1 spans three (cwd, branch) rows. 10.0 beats 9.0 only as a version by recency.
            session_row("claude", "s1", t, t + 10, "9.0", 3),
            session_row("claude", "s1", t + 5, t + 100, "10.0", 3),
            session_row("claude", "s1", t + 6, t + 200, None, 3),
            session_row("codex", "s2", t + 50, t + 60, None, 1),
            session_row("claude", "old", AFTER - 30 * DAY, AFTER - 29 * DAY, "1", 1),
            session_row("omp", "o1", t, t + 1, "1", 1),
            "INSERT INTO tool_results VALUES "
            + ", ".join(
                f"('claude', 'u{i}', 'c', {q(flag)}, true, 'ts', 's1')"
                for i, flag in enumerate(("true", "false", "false", "false"))
            ),
            "INSERT INTO permission_denials VALUES ('claude', 'x', 's1', 'ts'), ('claude', 'y', 's1', 'ts')",
            "INSERT INTO stop_hooks VALUES "
            + ", ".join(
                f"('claude', 'ts', 's1', 1, '', '', {flag}, '', false, 'x')"
                for flag in ("true", "true", "false")
            ),
            "INSERT INTO model_turns VALUES ('claude', 'm', 'end_turn', 100, 50, 'ts', 's1', '/p'), "
            "('claude', 'm', 'end_turn', 300, NULL, 'ts', 's1', '/p')",
        )
        gate = gate_json(
            targeted_query="SELECT harness, sessionId, entry_count * 2.5 AS value FROM sessions"
        )
        rows = hc_db.load_rows(db, gate, AFTER, AFTER + 7 * DAY)
        by = {r["session"]: r for r in rows}
        self.assertEqual(sorted(by), ["s1", "s2"])
        s1 = by["s1"]
        self.assertEqual(s1["harness"], "claude")
        self.assertEqual(s1["start"], t)
        self.assertEqual(s1["version"], "10.0")
        self.assertEqual(s1["target"], 7.5)
        self.assertEqual(s1["tool_error_rate"], 0.25)
        self.assertEqual(s1["permission_denials"], 2)
        self.assertEqual(s1["stop_hook_blocks"], 2)
        self.assertEqual(s1["tokens_per_turn"], 225.0)
        s2 = by["s2"]
        self.assertEqual((s2["harness"], s2["version"]), ("codex", None))
        self.assertEqual((s2["permission_denials"], s2["stop_hook_blocks"]), (0, 0))
        self.assertIsNone(s2["tool_error_rate"])
        self.assertIsNone(s2["tokens_per_turn"])

    def test_field_gate_reads_the_database_and_keeps_a_real_gain(self) -> None:
        statements = []
        for harness in ("claude", "codex"):
            for side, base, count in (
                ("b", AFTER - 3 * DAY, 9),
                ("a", AFTER + 3600, 5),
            ):
                for i in range(6):
                    start = base + i * 3600
                    sid = f"{harness}-{side}{i}"
                    entries = count + (1 if i % 2 else -1)
                    statements.append(
                        session_row(harness, sid, start, start + 60, "1.0", entries)
                    )
                    err = "true" if i % 2 else "false"
                    statements.append(
                        f"INSERT INTO tool_results VALUES ({q(harness)}, 'u', 'c', {q(err)}, true, 'ts', {q(sid)})"
                    )
                    statements.append(
                        f"INSERT INTO model_turns VALUES ({q(harness)}, 'm', 'end_turn', {1000 + 10 * i}, 0, 'ts', {q(sid)}, '/p')"
                    )
        db = self.build(*statements)
        self.commit({"README.md": "x"}, date=T0 - DAY)
        gate = gate_json(
            min_sessions=4,
            targeted_query="SELECT harness, sessionId, entry_count AS value FROM sessions",
        )
        merge = self.commit(
            {"harness-climb/gates/t1-r1.json": json.dumps(gate)}, date=T0
        )
        got = hc_field_gate.field_gate(
            self.repo, "t1", 1, merge, f"{AFTER} {merge}\n", None, AFTER + 9 * DAY, db
        )
        self.assertEqual(got["status"], "ok", got)
        self.assertEqual(got["candidate"], "keep", got)
        self.assertEqual(
            {h: v["verdict"] for h, v in got["harnesses"].items()},
            {"claude": "keep", "codex": "keep"},
        )

    def test_missing_version_column_is_inconclusive_version_unavailable(self) -> None:
        ddl = (
            "CREATE TABLE sessions (harness VARCHAR, sessionId VARCHAR, first_seen VARCHAR, "
            "last_seen VARCHAR, project VARCHAR, branch VARCHAR, entry_count BIGINT)"
        )
        db = self.build(sessions_ddl=ddl)
        self.commit({"README.md": "x"}, date=T0 - DAY)
        merge = self.commit(
            {"harness-climb/gates/t1-r1.json": json.dumps(gate_json())}, date=T0
        )
        got = hc_field_gate.field_gate(
            self.repo, "t1", 1, merge, f"{AFTER} {merge}\n", None, AFTER + 9 * DAY, db
        )
        self.assertEqual(got["candidate"], "inconclusive")
        self.assertEqual(
            {v["reason"] for v in got["harnesses"].values()}, {"version-unavailable"}
        )
        with self.assertRaises(hc_db.VersionUnavailable):
            hc_db.load_rows(db, gate_json(), AFTER, AFTER + DAY)


if __name__ == "__main__":
    unittest.main()
