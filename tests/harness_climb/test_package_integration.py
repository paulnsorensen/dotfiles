"""Package-built harness-climb integration fixtures from native session logs."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from unittest import mock

from .support import (
    DAY,
    T0,
    RepoCase,
    gate_json,
    hc_db,
    hc_denylist,
    hc_field_gate,
    hc_policy,
    make_db,
)

AFTER = T0 + DAY
PROMPT = "please rotate the quarterly credentials for the acme billing cluster tonight"


def stamp(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, UTC).isoformat().replace("+00:00", "Z")


def write_log(path: Path, entries: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in entries))


class PackageBuiltConsumerTests(RepoCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._fixture = tempfile.TemporaryDirectory(prefix="hc-package-")
        cls.home = Path(cls._fixture.name)
        cls.env = {
            **{k: v for k, v in os.environ.items() if k != "SESSIONS_DB"},
            "HOME": str(cls.home),
            "XDG_CACHE_HOME": str(cls.home / "cache"),
            "CLAUDE_CONFIG_DIR": str(cls.home / "claude"),
            "CODEX_HOME": str(cls.home / "codex"),
            "CURSOR_HOME": str(cls.home / "cursor"),
        }
        for harness in ("claude", "codex"):
            for side, base, count in (
                ("b", AFTER - 3 * DAY, 9),
                ("a", AFTER + 3600, 5),
            ):
                for i in range(6):
                    sid = f"{harness}-{side}{i}"
                    start = base + i * 3600
                    if harness == "claude":
                        cls.claude_log(sid, start, count + (i % 2), "1.0")
                    else:
                        cls.codex_log(sid, start, count + (i % 2), "1.0")
        cls.claude_log("old-version", AFTER - 2 * DAY, 3, "2.0")
        cls.claude_log(
            "version-shift", AFTER - 2 * DAY + 300, 3, "9.0", last_version="10.0"
        )
        cls.codex_log("child", AFTER + 7200, 5, "1.0", parent="codex-a0")
        cls.claude_log("prompt-source", AFTER - 30 * DAY, 1, "1.0", prompt=True)
        cls.codex_log("rollout-prompt", AFTER - 30 * DAY, 1, "1.0", prompt=True)
        proc = subprocess.run(
            [*hc_db.PACKAGE, "ingest", "--force"],
            env=cls.env,
            capture_output=True,
            text=True,
            check=False,
            timeout=90,
        )
        if proc.returncode:
            raise AssertionError(f"package ingest failed: exit {proc.returncode}")
        cls.db = cls.home / "cache/agent-session-analytics/sessions.duckdb"
        if not cls.db.is_file():
            raise AssertionError("package ingest did not build a database")

    @classmethod
    def tearDownClass(cls) -> None:
        cls._fixture.cleanup()

    @classmethod
    def claude_log(
        cls,
        sid: str,
        start: float,
        count: int,
        version: str,
        *,
        last_version: str | None = None,
        prompt: bool = False,
    ) -> None:
        entries = []
        for n in range(count):
            message = {
                "model": "claude-test",
                "content": [{"type": "text", "text": "ordinary reply"}],
                "usage": {
                    "input_tokens": 10,
                    "cache_read_input_tokens": 1000,
                    "cache_creation_input_tokens": 100,
                    "output_tokens": 20,
                },
            }
            entries.append(
                {
                    "type": "assistant",
                    "timestamp": stamp(start + n),
                    "sessionId": sid,
                    "cwd": "/work/zebracorp",
                    "version": last_version
                    if last_version and n == count - 1
                    else version,
                    "message": message,
                }
            )
        entries.extend(
            [
                {
                    "type": "assistant",
                    "timestamp": stamp(start + count),
                    "sessionId": sid,
                    "cwd": "/work/zebracorp",
                    "version": last_version or version,
                    "message": {
                        "model": "claude-test",
                        "usage": {
                            "input_tokens": 10,
                            "cache_read_input_tokens": 1000,
                            "cache_creation_input_tokens": 100,
                            "output_tokens": 20,
                        },
                        "content": [
                            {
                                "type": "tool_use",
                                "id": "tool-1",
                                "name": "Read",
                                "input": {},
                            }
                        ],
                    },
                },
                {
                    "type": "user",
                    "timestamp": stamp(start + count + 1),
                    "sessionId": sid,
                    "cwd": "/work/zebracorp",
                    "message": {
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "tool-1",
                                "content": "ok",
                                "is_error": "false",
                            }
                        ]
                    },
                },
            ]
        )
        if prompt:
            entries.append(
                {
                    "type": "user",
                    "timestamp": stamp(start + count),
                    "sessionId": sid,
                    "cwd": "/work/zebracorp",
                    "message": {
                        "content": [
                            {
                                "type": "text",
                                "text": "<system-reminder>injected secret text",
                            },
                            {"type": "tool_result", "content": "tool-only secret text"},
                            {"type": "text", "text": PROMPT},
                        ]
                    },
                }
            )
        write_log(cls.home / "claude/projects/fixture" / f"{sid}.jsonl", entries)

    @classmethod
    def codex_log(
        cls,
        sid: str,
        start: float,
        count: int,
        version: str,
        *,
        parent: str | None = None,
        prompt: bool = False,
    ) -> None:
        payload = {"id": sid, "cwd": "/work/zebracorp", "cli_version": version}
        if parent:
            payload["source"] = {
                "subagent": {"thread_spawn": {"parent_thread_id": parent}}
            }
        entries = [
            {"type": "session_meta", "timestamp": stamp(start), "payload": payload}
        ]
        entries.append(
            {
                "type": "turn_context",
                "timestamp": stamp(start + 1),
                "payload": {"cwd": "/work/zebracorp", "model": "gpt-test"},
            }
        )
        for n in range(count):
            entries.append(
                {
                    "type": "response_item",
                    "timestamp": stamp(start + 2 + n),
                    "payload": {
                        "type": "function_call",
                        "name": "shell",
                        "arguments": '{"command":["true"]}',
                        "call_id": f"c{n}",
                    },
                }
            )
            entries.append(
                {
                    "type": "response_item",
                    "timestamp": stamp(start + 2 + n),
                    "payload": {
                        "type": "function_call_output",
                        "call_id": f"c{n}",
                        "output": "ok",
                    },
                }
            )
        usage = {
            "input_tokens": 200,
            "cached_input_tokens": 50,
            "output_tokens": 30,
            "total_tokens": 230,
        }
        entries.append(
            {
                "type": "event_msg",
                "timestamp": stamp(start + count + 3),
                "payload": {
                    "type": "token_count",
                    "info": {"last_token_usage": usage, "total_token_usage": usage},
                },
            }
        )
        if prompt:
            entries.append(
                {
                    "type": "response_item",
                    "timestamp": stamp(start + count + 4),
                    "payload": {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": PROMPT}],
                    },
                }
            )
        write_log(cls.home / "codex/sessions/2026/05/30" / f"{sid}.jsonl", entries)

    def setUp(self) -> None:
        super().setUp()
        patch = mock.patch.dict(os.environ, self.env, clear=True)
        patch.start()
        self.addCleanup(patch.stop)

    def test_load_rows_from_package_schema_preserves_version_parent_and_cost(
        self,
    ) -> None:
        rows = hc_db.load_rows(
            self.db,
            gate_json(
                targeted_query="SELECT harness, sessionId, entry_count AS value FROM sessions"
            ),
            AFTER - 7 * DAY,
            AFTER + 7 * DAY,
        )
        by = {row["session"]: row for row in rows}
        self.assertNotIn("child", by)
        self.assertEqual(by["version-shift"]["version"], "10.0")
        self.assertEqual(by["claude-b0"]["tokens_per_turn"], 1130.0)
        self.assertEqual(by["codex-b0"]["tokens_per_turn"], 230.0)
        self.assertEqual(by["claude-b0"]["harness"], "claude")

    def test_freeze_and_denylist_use_package_database(self) -> None:
        from .support import cli

        self.assertIsNone(
            cli.hc_freeze.query_problem(
                "SELECT harness, sessionId, entry_count AS value FROM sessions"
            )
        )
        self.assertIn(
            "dry run",
            cli.hc_freeze.query_problem(
                "SELECT harness, sessionId, missing AS value FROM sessions"
            ),
        )
        prompts = hc_denylist._db_prompts(self.db)
        self.assertIn(PROMPT, prompts["claude"])
        self.assertNotIn("<system-reminder>injected secret text", prompts["claude"])
        self.assertNotIn("tool-only secret text", prompts["claude"])
        self.assertIn(PROMPT, prompts["codex"])
        deny, notes = hc_denylist.load_denylist(None, Path("/tmp/example-repo"))
        self.assertEqual(notes, [])
        self.assertEqual(
            [
                v["category"]
                for v in hc_policy.check_leakage({"f": [(1, "Zebracorp")]}, deny)
            ],
            ["project"],
        )

    def test_override_rejects_unstamped_database_without_rebuild(self) -> None:
        db = make_db(
            self.dir / "unstamped.duckdb", "CREATE TABLE sessions (sessionId VARCHAR)"
        )
        before = db.stat().st_mtime_ns
        with self.assertRaises(hc_db.DbError):
            hc_db.duck(db, "SELECT 1")
        self.assertEqual(db.stat().st_mtime_ns, before)
        self.assertFalse((self.dir / "unstamped.duckdb.stage").exists())

    def test_field_gate_verdict_uses_package_built_rows(self) -> None:
        self.commit({"README.md": "x"}, date=T0 - DAY)
        gate = gate_json(
            min_sessions=4,
            targeted_query="SELECT harness, sessionId, entry_count AS value FROM sessions",
        )
        merge = self.commit(
            {"harness-climb/gates/t1-r1.json": json.dumps(gate)}, date=T0
        )
        got = hc_field_gate.field_gate(
            self.repo,
            "t1",
            1,
            merge,
            f"{AFTER} {merge}\n",
            None,
            AFTER + 9 * DAY,
            lambda: self.db,
        )
        self.assertEqual(got["status"], "ok", got)
        self.assertEqual(got["candidate"], "keep", got)
        self.assertEqual(
            {h: v["verdict"] for h, v in got["harnesses"].items()},
            {"claude": "keep", "codex": "keep"},
            got,
        )
        self.assertEqual(got["harnesses"]["claude"]["version"], "1.0")
        self.assertEqual(got["harnesses"]["claude"]["excluded"], 2)
