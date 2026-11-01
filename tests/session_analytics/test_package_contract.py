"""Runtime contract for the published agent-session-analytics CLI."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast, final, override

# -q keeps uv install progress out of stderr; the sandbox starts with a cold uv cache.
CLI = ["uvx", "-q", "agent-session-analytics==0.2.1"]


@final
class PackageContract(unittest.TestCase):
    @classmethod
    @override
    def setUpClass(cls) -> None:
        cls.sandbox = tempfile.TemporaryDirectory(prefix="session-package-")
        cls.root = Path(cls.sandbox.name)
        cls.env = os.environ.copy()
        cls.env.update(
            HOME=str(cls.root),
            XDG_CACHE_HOME=str(cls.root / "cache"),
            CLAUDE_CONFIG_DIR=str(cls.root / "claude"),
            CODEX_HOME=str(cls.root / "codex"),
            CURSOR_HOME=str(cls.root / "cursor"),
        )
        _ = cls.env.pop("SESSIONS_DB", None)
        _ = cls.env.pop("SESSIONS_DUCKDB_MEMORY_LIMIT", None)
        log = cls.root / "claude" / "projects" / "fixture" / "session.jsonl"
        _ = log.parent.mkdir(parents=True)
        _ = log.write_text(
            '{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"c-1","cwd":"/work/fixture","message":{"content":[{"type":"tool_use","id":"tu-1","name":"Read","input":{"file_path":"README.md"}}]}}\n'
            + '{"type":"user","timestamp":"2026-05-30T10:00:01Z","sessionId":"c-1","message":{"content":[{"type":"tool_result","tool_use_id":"tu-1","content":"ok","is_error":"false"}]}}\n',
            encoding="utf-8",
        )
        result = cls.call("ingest", "--force")
        if result.returncode != 0:
            raise AssertionError(result.stderr)

    @classmethod
    @override
    def tearDownClass(cls) -> None:
        cls.sandbox.cleanup()

    @classmethod
    def call(
        cls, *args: str, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [*CLI, *args],
            env=env or cls.env,
            capture_output=True,
            text=True,
            check=False,
            timeout=90,
        )

    def test_path_and_schema_json(self) -> None:
        path = cast(dict[str, str], json.loads(self.call("db-path").stdout))["path"]
        self.assertEqual(
            path, str(self.root / "cache/agent-session-analytics/sessions.duckdb")
        )
        schema = cast(dict[str, str], json.loads(self.call("schema").stdout))
        self.assertEqual(schema["reference"], "canonical-schema.md")
        self.assertIn("tool_uses", schema["content"])

    def test_ingest_stamps_schema_and_returns_row_dicts(self) -> None:
        rows = cast(
            list[dict[str, object]],
            json.loads(self.call("sql", "SELECT version FROM schema_info").stdout),
        )
        self.assertEqual(rows, [{"version": 3}])
        rows = cast(
            list[dict[str, object]],
            json.loads(
                self.call(
                    "sql", "SELECT harness, sessionId, tool_name FROM tool_uses"
                ).stdout
            ),
        )
        self.assertEqual(
            rows, [{"harness": "claude", "sessionId": "c-1", "tool_name": "Read"}]
        )

    def test_existing_consumer_sql_shapes(self) -> None:
        queries = [
            "SELECT tool_name, count(*) AS uses FROM tool_uses WHERE harness = 'claude' GROUP BY tool_name",
            "SELECT count(*) AS n FROM information_schema.columns WHERE table_name = 'sessions' AND column_name = 'version'",
            "SELECT harness, sessionId, value FROM (SELECT harness, sessionId, count(*) AS value FROM tool_uses GROUP BY harness, sessionId) AS q LIMIT 0",
            "SELECT s.sessionId, count(tu.tool_name) AS calls FROM sessions s LEFT JOIN tool_uses tu USING (sessionId) GROUP BY s.sessionId",
        ]
        for query in queries:
            with self.subTest(query=query):
                result = self.call("sql", query)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = cast(object, json.loads(result.stdout))
                self.assertIsInstance(data, list)

    def test_missing_and_incompatible_override_exit_four(self) -> None:
        missing = dict(self.env, SESSIONS_DB=str(self.root / "missing.duckdb"))
        result = self.call("sql", "SELECT 1", env=missing)
        self.assertEqual(result.returncode, 4)
        self.assertEqual(json.loads(result.stderr)["exit_code"], 4)
        self.assertFalse(Path(missing["SESSIONS_DB"]).exists())

        source = Path(
            cast(dict[str, str], json.loads(self.call("db-path").stdout))["path"]
        )
        other = self.root / "wrong-version.duckdb"
        _ = shutil.copy2(source, other)
        _ = subprocess.run(
            ["duckdb", str(other), "-c", "UPDATE schema_info SET version=2"],
            check=True,
            capture_output=True,
        )
        result = self.call(
            "sql", "SELECT 1", env=dict(self.env, SESSIONS_DB=str(other))
        )
        self.assertEqual(result.returncode, 4)
        self.assertEqual(json.loads(result.stderr)["exit_code"], 4)

    def test_rejected_sql_exits_five(self) -> None:
        for query in (
            "SELECT * FROM missing_table",
            "CREATE TABLE forbidden (x INTEGER)",
            "SELECT * FROM read_csv('/etc/passwd')",
        ):
            with self.subTest(query=query):
                result = self.call("sql", query)
                self.assertEqual(result.returncode, 5)
                self.assertEqual(json.loads(result.stderr)["exit_code"], 5)
                self.assertFalse(result.stdout)

    def test_missing_duckdb_exits_three(self) -> None:
        uvx = shutil.which("uvx")
        assert uvx is not None
        if Path(uvx).parent.name == "shims":
            uvx = subprocess.run(
                ["mise", "which", "uvx"], check=True, capture_output=True, text=True
            ).stdout.strip()
        bin_dir = self.root / "no-duckdb-bin"
        bin_dir.mkdir()
        for name in ("uvx", "realpath", "dirname"):
            target = uvx if name == "uvx" else shutil.which(name)
            assert target is not None
            (bin_dir / name).symlink_to(target)
        result = self.call(
            "sql",
            "SELECT 1",
            env=dict(self.env, PATH=str(bin_dir), UV_PYTHON=sys.executable),
        )
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(json.loads(result.stderr)["exit_code"], 3)


if __name__ == "__main__":
    _ = unittest.main()
