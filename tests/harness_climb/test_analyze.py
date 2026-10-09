"""Analyze: findings validation and database resolution."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest.mock
from pathlib import Path
from typing import Any

from .support import CLI_PATH, HAVE_DUCKDB, call, cli, hc_db

GOOD_QUERY = "SELECT sessionId FROM tool_results WHERE harness IN ('claude','codex') AND is_error = 'true'"


def failure_mode(**over: Any) -> dict[str, Any]:
    mode = {
        "query": GOOD_QUERY,
        "counts": {"claude": 4, "codex": 2},
        "component": "skill",
    }
    mode.update(over)
    return mode


class ValidateFindingsTests(unittest.TestCase):
    def errors(self, **findings: Any) -> list[str]:
        return cli.validate_findings(findings)

    def test_complete_findings_pass(self) -> None:
        self.assertEqual(
            self.errors(
                failure_modes=[failure_mode()], success_habits=[{"sessions": 3}]
            ),
            [],
        )

    def test_failure_mode_without_query_is_rejected(self) -> None:
        for query in (None, "", "   "):
            errors = self.errors(failure_modes=[failure_mode(query=query)])
            self.assertEqual(len(errors), 1, query)
            self.assertIn("lacks query", errors[0])

    def test_failure_mode_query_must_filter_claude_and_codex(self) -> None:
        errors = self.errors(
            failure_modes=[
                failure_mode(query="SELECT 1 FROM sessions WHERE harness = 'pi'")
            ]
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("must filter", errors[0])

    def test_failure_mode_query_accepts_a_reordered_harness_list(self) -> None:
        query = "SELECT 1 FROM sessions WHERE harness  IN ( 'codex', 'claude' )"
        self.assertEqual(self.errors(failure_modes=[failure_mode(query=query)]), [])

    def test_failure_mode_query_rejects_a_partial_harness_list(self) -> None:
        for query in (
            "SELECT 1 WHERE harness IN ('claude')",
            "SELECT 1 WHERE harness IN ('claude','codex','pi')",
        ):
            errors = self.errors(failure_modes=[failure_mode(query=query)])
            self.assertEqual(len(errors), 1, query)

    def test_non_object_findings_return_errors(self) -> None:
        self.assertEqual(len(cli.validate_findings([])), 1)
        for key, bad in (
            ("failure_modes", ["x"]),
            ("failure_modes", "x"),
            ("success_habits", [3]),
            ("success_habits", None),
        ):
            errors = self.errors(**{key: bad})
            self.assertEqual(len(errors), 1, (key, bad))

    def test_boolean_counts_are_rejected(self) -> None:
        errors = self.errors(failure_modes=[failure_mode(counts={"claude": True})])
        self.assertEqual(len(errors), 1)
        self.assertIn("counts", errors[0])

    def test_failure_mode_without_counts_is_rejected(self) -> None:
        for counts in (None, {}, {"claude": "4"}, {"claude": 1.5}):
            errors = self.errors(failure_modes=[failure_mode(counts=counts)])
            self.assertEqual(len(errors), 1, counts)
            self.assertIn("counts", errors[0])

    def test_failure_mode_without_component_is_rejected(self) -> None:
        for component in (None, "", "vibes"):
            errors = self.errors(failure_modes=[failure_mode(component=component)])
            self.assertEqual(len(errors), 1, component)
            self.assertIn("component", errors[0])

    def test_success_habit_without_session_count_is_rejected(self) -> None:
        for habit in ({}, {"sessions": 0}, {"sessions": "3"}, {"sessions": True}):
            errors = self.errors(success_habits=[habit])
            self.assertEqual(len(errors), 1, habit)
            self.assertIn("session count", errors[0])

    def test_every_bad_entry_is_reported_with_its_index(self) -> None:
        errors = self.errors(
            failure_modes=[
                failure_mode(),
                failure_mode(query=""),
                failure_mode(counts={}),
            ]
        )
        self.assertEqual(
            [e.split(" ")[0] for e in errors], ["failure_modes[1]", "failure_modes[2]"]
        )


class AnalyzeCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.db = self.dir / "sessions.duckdb"

    def analyze(
        self, findings: Path | None = None, db: Path | None = None
    ) -> tuple[int, dict[str, Any]]:
        argv = [
            "analyze",
            "--repo",
            str(self.dir),
            "--state-dir",
            str(self.dir / "state"),
            "--thread",
            "t1",
        ]
        if findings:
            argv += ["--findings", str(findings)]
        with unittest.mock.patch.dict(os.environ, {"SESSIONS_DB": str(db or self.db)}):
            return call(*argv)

    def findings(self, data: dict[str, Any]) -> Path:
        import json

        path = self.dir / "findings.json"
        path.write_text(json.dumps(data))
        return path

    def test_db_path_comes_from_db_path_sh(self) -> None:
        rc, out = self.analyze()
        self.assertEqual((rc, out["status"]), (1, "no-db"))
        self.assertEqual(out["db"], str(self.db))
        self.assertEqual(out["harnesses"], ["claude", "codex"])
        other = self.dir / "other.duckdb"
        self.assertEqual(self.analyze(db=other)[1]["db"], str(other))

    def test_db_path_is_never_hardcoded_in_the_cli(self) -> None:
        source = (CLI_PATH.parent / "hc_db.py").read_text()
        self.assertNotIn("sessions.duckdb", source)
        self.assertIn("db-path.sh", source)
        self.assertIn("sessions_db_path", source)

    def test_invalid_findings_exit_2_with_errors_and_no_db_read(self) -> None:
        bad = self.findings({"failure_modes": [{"counts": {}}], "success_habits": [{}]})
        rc, out = self.analyze(bad)
        self.assertEqual((rc, out["status"]), (2, "invalid"))
        self.assertGreaterEqual(len(out["errors"]), 4)
        self.assertFalse(self.db.exists())

    def test_invalid_findings_never_refresh_the_database(self) -> None:
        bad = self.findings({"failure_modes": [{"counts": {}}]})
        with unittest.mock.patch.object(hc_db, "ensure_fresh_db") as fresh:
            self.analyze(bad)
        fresh.assert_not_called()

    def test_a_failed_refresh_is_an_error_not_a_stale_read(self) -> None:
        with unittest.mock.patch.object(hc_db, "ensure_fresh_db", return_value=False):
            rc, out = self.analyze(self.findings({"failure_modes": [failure_mode()]}))
        self.assertEqual((rc, out["status"]), (2, "error"))
        self.assertIn("refresh failed", out["error"])

    def test_valid_findings_with_missing_db_report_no_db(self) -> None:
        rc, out = self.analyze(self.findings({"failure_modes": [failure_mode()]}))
        self.assertEqual((rc, out["status"]), (1, "no-db"))

    @unittest.skipUnless(HAVE_DUCKDB, "duckdb CLI not installed")
    def test_counts_cover_claude_and_codex_only(self) -> None:
        sql = """
        CREATE TABLE sessions(harness VARCHAR, sessionId VARCHAR, first_seen VARCHAR);
        CREATE TABLE tool_results(harness VARCHAR, sessionId VARCHAR, timestamp VARCHAR, is_error VARCHAR);
        INSERT INTO sessions SELECT h, h || i::VARCHAR, CAST(now() AS VARCHAR)
          FROM (VALUES ('claude'), ('codex'), ('pi')) AS v(h), range(2) AS r(i);
        INSERT INTO tool_results SELECT h, h || '0', CAST(now() AS VARCHAR), 'true'
          FROM (VALUES ('claude'), ('codex'), ('pi')) AS v(h);
        """
        subprocess.run(
            ["duckdb", "-init", "/dev/null", str(self.db), "-c", sql],
            check=True,
            capture_output=True,
        )
        rc, out = self.analyze(
            self.findings(
                {"failure_modes": [failure_mode()], "success_habits": [{"sessions": 3}]}
            )
        )
        self.assertEqual((rc, out["status"]), (0, "ok"))
        self.assertEqual(
            {r["harness"]: r["sessions"] for r in out["sessions"]},
            {"claude": 2, "codex": 2},
        )
        self.assertEqual(
            {
                r["harness"]: (int(r["results"]), int(r["errors"]))
                for r in out["tool_results"]
            },
            {"claude": (1, 1), "codex": (1, 1)},
        )
        self.assertEqual(out["failure_modes"], [failure_mode()])


if __name__ == "__main__":
    unittest.main()
