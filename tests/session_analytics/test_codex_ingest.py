from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "skills" / "session-analytics" / "scripts" / "ingest.py"

_spec = importlib.util.spec_from_file_location("session_analytics_ingest", SCRIPT)
assert _spec is not None and _spec.loader is not None
ingest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ingest)


def usage(inp: int, out: int, cached: int) -> dict[str, int]:
    return {
        "input_tokens": inp,
        "cached_input_tokens": cached,
        "output_tokens": out,
        "total_tokens": inp + out,
    }


def token_count(ts: str, last: Any, total: Any) -> dict[str, Any]:
    info = None
    if last is not None or total is not None:
        info = {"last_token_usage": last, "total_token_usage": total}
    return {
        "timestamp": ts,
        "type": "event_msg",
        "payload": {"type": "token_count", "info": info},
    }


def meta(version: str | None = "9.9.9") -> dict[str, Any]:
    payload: dict[str, Any] = {"id": "s-1", "cwd": "/work/x"}
    if version is not None:
        payload["cli_version"] = version
    return {"timestamp": "t0", "type": "session_meta", "payload": payload}


def turn_context(model: str) -> dict[str, Any]:
    return {
        "timestamp": "t1",
        "type": "turn_context",
        "payload": {"cwd": "/work/x", "model": model},
    }


def call(call_id: str) -> dict[str, Any]:
    return {
        "timestamp": "t2",
        "type": "response_item",
        "payload": {
            "type": "function_call",
            "name": "shell",
            "arguments": json.dumps({"command": ["ls"]}),
            "call_id": call_id,
        },
    }


def output(call_id: str) -> dict[str, Any]:
    return {
        "timestamp": "t3",
        "type": "response_item",
        "payload": {
            "type": "function_call_output",
            "call_id": call_id,
            "output": "ok",
        },
    }


def normalize(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "rollout.jsonl"
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        return list(ingest.codex_normalize(str(path)))


def token_turns(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [e for e in entries if "usage" in e.get("message", {})]


class CodexIngestCase(unittest.TestCase):
    def test_cli_version_becomes_raw_entries_version(self) -> None:
        entries = normalize(
            [
                meta("0.159.3"),
                turn_context("gpt-x"),
                call("c1"),
                output("c1"),
                token_count("t4", usage(10, 2, 4), usage(10, 2, 4)),
            ]
        )
        self.assertEqual(len(entries), 3)
        self.assertEqual({e["version"] for e in entries}, {"0.159.3"})
        self.assertIn("version", ingest.RAW_COLUMNS)

    def test_missing_cli_version_yields_null_version(self) -> None:
        entries = normalize([meta(None), call("c1")])
        self.assertIsNone(entries[0]["version"])

    def test_token_count_yields_one_model_turn_entry(self) -> None:
        entries = normalize(
            [
                meta(),
                turn_context("gpt-x"),
                token_count("t4", usage(100, 7, 40), usage(100, 7, 40)),
            ]
        )
        (turn,) = token_turns(entries)
        self.assertEqual(turn["type"], "token_usage")
        self.assertEqual(turn["harness"], "codex")
        self.assertEqual(turn["sessionId"], "s-1")
        msg = turn["message"]
        self.assertEqual(msg["model"], "gpt-x")
        self.assertEqual(
            msg["usage"],
            {
                "input_tokens": 100,
                "output_tokens": 7,
                "cache_read_input_tokens": 40,
            },
        )

    def test_token_count_uses_latest_turn_context_model(self) -> None:
        entries = normalize(
            [
                meta(),
                turn_context("gpt-a"),
                token_count("t4", usage(1, 1, 0), usage(1, 1, 0)),
                turn_context("gpt-b"),
                token_count("t5", usage(2, 2, 0), usage(3, 3, 0)),
            ]
        )
        models = [e["message"]["model"] for e in token_turns(entries)]
        self.assertEqual(models, ["gpt-a", "gpt-b"])

    def test_token_count_skips_repeated_total_usage(self) -> None:
        entries = normalize(
            [
                meta(),
                turn_context("gpt-x"),
                token_count("t4", usage(5, 1, 0), usage(5, 1, 0)),
                token_count("t5", usage(5, 1, 0), usage(5, 1, 0)),
                token_count("t6", usage(6, 2, 0), usage(11, 3, 0)),
            ]
        )
        turns = token_turns(entries)
        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[1]["message"]["usage"]["input_tokens"], 6)

    def test_token_count_null_last_usage_yields_nothing(self) -> None:
        entries = normalize(
            [
                meta(),
                turn_context("gpt-x"),
                token_count("t4", None, None),
                token_count("t5", None, usage(5, 1, 0)),
            ]
        )
        self.assertEqual(entries, [])

    def test_token_count_ids_are_unique_and_leave_tool_blocks_alone(self) -> None:
        entries = normalize(
            [
                meta(),
                turn_context("gpt-x"),
                call("c1"),
                token_count("t4", usage(1, 1, 0), usage(1, 1, 0)),
                output("c1"),
                token_count("t5", usage(2, 1, 0), usage(3, 2, 0)),
            ]
        )
        turns = token_turns(entries)
        ids = [e["message"]["id"] for e in turns]
        self.assertEqual(len(set(ids)), 2)
        blocks = [
            b for e in entries for b in e["message"]["content"] if isinstance(b, dict)
        ]
        self.assertEqual(sorted(b["type"] for b in blocks), ["tool_result", "tool_use"])
        for turn in turns:
            self.assertEqual(turn["message"]["content"], [])
            self.assertNotIn("stop_reason", turn["message"])

    def test_forked_rollout_keeps_first_meta_id_and_unique_token_ids(self) -> None:
        def session_meta(sid: str) -> dict[str, Any]:
            return {
                "timestamp": "t0",
                "type": "session_meta",
                "payload": {"id": sid, "cwd": "/work/x"},
            }

        body = [
            turn_context("gpt-x"),
            call("c1"),
            token_count("t4", usage(1, 1, 0), usage(1, 1, 0)),
        ]
        parent = normalize([session_meta("parent-1"), *body])
        fork = normalize([session_meta("child-1"), session_meta("parent-1"), *body])
        self.assertEqual({e["sessionId"] for e in fork}, {"child-1"})
        parent_ids = {e["message"]["id"] for e in token_turns(parent)}
        fork_ids = {e["message"]["id"] for e in token_turns(fork)}
        self.assertEqual(len(fork_ids), 1)
        self.assertFalse(parent_ids & fork_ids)

    def test_sub_agent_rollout_records_its_parent_session(self) -> None:
        def session_meta(sid: str, source: Any) -> dict[str, Any]:
            payload: dict[str, Any] = {"id": sid, "cwd": "/work/x"}
            if source is not None:
                payload["source"] = source
            return {"timestamp": "t0", "type": "session_meta", "payload": payload}

        spawn = {"subagent": {"thread_spawn": {"parent_thread_id": "parent-1"}}}
        body = [call("c1"), token_count("t4", usage(1, 1, 0), usage(1, 1, 0))]
        child = normalize([session_meta("child-1", spawn), *body])
        self.assertEqual({e["sessionId"] for e in child}, {"child-1"})
        self.assertEqual({e["parentSessionId"] for e in child}, {"parent-1"})
        self.assertIn("parentSessionId", ingest.RAW_COLUMNS)
        for source in (None, "cli", {"subagent": "review"}):
            top = normalize([session_meta("top-1", source), *body])
            self.assertEqual({e["parentSessionId"] for e in top}, {None})

    def test_parent_meta_of_a_fork_does_not_set_the_parent_link(self) -> None:
        def session_meta(sid: str, source: Any) -> dict[str, Any]:
            return {
                "timestamp": "t0",
                "type": "session_meta",
                "payload": {"id": sid, "cwd": "/work/x", "source": source},
            }

        spawn = {"subagent": {"thread_spawn": {"parent_thread_id": "gp-1"}}}
        fork = normalize(
            [
                session_meta("child-1", "cli"),
                session_meta("parent-1", spawn),
                call("c1"),
            ]
        )
        self.assertEqual({e["parentSessionId"] for e in fork}, {None})


class CodexNormalizeAttacks(unittest.TestCase):
    def test_tokenCount_beforeAnySessionMeta_doesNotCrashAndLaterEntriesCarryVersion(
        self,
    ) -> None:
        entries = normalize(
            [
                token_count("t0", usage(1, 1, 0), usage(1, 1, 0)),
                meta("1.2.3"),
                turn_context("gpt-x"),
                call("c1"),
            ]
        )
        self.assertEqual(entries[-1]["version"], "1.2.3")
        self.assertIsNone(entries[0]["version"])

    def test_tokenCount_beforeAnySessionMeta_isNotAttributedToASession(self) -> None:
        entries = normalize([token_count("t0", usage(1, 1, 0), usage(1, 1, 0)), meta()])
        for turn in token_turns(entries):
            self.assertIsNone(turn["sessionId"])

    def test_tokenCount_beforeTurnContext_stillCarriesAModelForModelTurns(self) -> None:
        # model_turns keeps only rows whose message.model is not null (ingest.py model_turns SQL).
        entries = normalize([meta(), token_count("t0", usage(5, 1, 0), usage(5, 1, 0))])
        (turn,) = token_turns(entries)
        self.assertIsNotNone(turn["message"]["model"])

    def test_tokenCount_totalEqualsNonAdjacentEarlierEvent_isEmitted(self) -> None:
        a, b = usage(5, 1, 0), usage(9, 2, 0)
        entries = normalize(
            [
                meta(),
                turn_context("m"),
                token_count("t1", a, a),
                token_count("t2", b, b),
                token_count("t3", a, a),
            ]
        )
        self.assertEqual(len(token_turns(entries)), 3)

    def test_tokenCount_threeAdjacentRepeats_emitOnce(self) -> None:
        a = usage(5, 1, 0)
        entries = normalize(
            [meta(), turn_context("m")] + [token_count(f"t{i}", a, a) for i in range(3)]
        )
        self.assertEqual(len(token_turns(entries)), 1)

    def test_tokenCount_lastUsageAllZeros_isStillARow(self) -> None:
        z = usage(0, 0, 0)
        entries = normalize(
            [meta(), turn_context("m"), token_count("t1", z, usage(3, 3, 0))]
        )
        (turn,) = token_turns(entries)
        self.assertEqual(turn["message"]["usage"]["input_tokens"], 0)
        self.assertEqual(turn["message"]["usage"]["output_tokens"], 0)

    def test_tokenCount_totalMissingOnBothEvents_bothEmitted(self) -> None:
        a = usage(5, 1, 0)
        entries = normalize(
            [
                meta(),
                turn_context("m"),
                token_count("t1", a, None),
                token_count("t2", a, None),
            ]
        )
        self.assertEqual(len(token_turns(entries)), 2)

    def test_tokenCount_totalRepeatSeparatedByNullInfoEvent_isStillSkipped(
        self,
    ) -> None:
        a = usage(5, 1, 0)
        entries = normalize(
            [
                meta(),
                turn_context("m"),
                token_count("t1", a, a),
                token_count("t2", None, None),
                token_count("t3", a, a),
            ]
        )
        self.assertEqual(len(token_turns(entries)), 1)

    def test_tokenCount_totalChangedByNullLastEvent_thenOldTotal_isEmitted(
        self,
    ) -> None:
        # t2 moves the total without a last_token_usage; t3 repeats t1's total, not t2's.
        a, b = usage(5, 1, 0), usage(9, 2, 0)
        entries = normalize(
            [
                meta(),
                turn_context("m"),
                token_count("t1", a, a),
                token_count("t2", None, b),
                token_count("t3", a, a),
            ]
        )
        self.assertEqual(
            len(token_turns(entries)), 2, "t3 differs from the previous event (t2)"
        )

    def test_tokenCount_malformedInfoShapes_areIgnored(self) -> None:
        rows = [meta(), turn_context("m")]
        for info in ([], "x", 5, {"last_token_usage": "x"}, {"last_token_usage": []}):
            rows.append(
                {
                    "timestamp": "t",
                    "type": "event_msg",
                    "payload": {"type": "token_count", "info": info},
                }
            )
        rows.append({"timestamp": "t", "type": "event_msg", "payload": None})
        rows.append(
            {"timestamp": "t", "type": "event_msg", "payload": {"type": "token_count"}}
        )
        self.assertEqual(token_turns(normalize(rows)), [])

    def test_cliVersion_appearsAfterEarlierEntries_earlierEntriesStayNull(self) -> None:
        entries = normalize(
            [
                meta(None),
                turn_context("m"),
                call("c1"),
                output("c1"),
                meta("4.5.6"),
                call("c2"),
            ]
        )
        self.assertEqual([e["version"] for e in entries], [None, None, "4.5.6"])

    def test_cliVersion_laterMetaWithoutVersionKeepsEarlierOne(self) -> None:
        entries = normalize([meta("1.0.0"), meta(None), call("c1")])
        self.assertEqual(entries[0]["version"], "1.0.0")

    def test_cliVersion_emptyString_isNull(self) -> None:
        self.assertIsNone(normalize([meta(""), call("c1")])[0]["version"])

    def test_cliVersion_nonStringValue_doesNotCrash(self) -> None:
        normalize(
            [
                meta(),
                {
                    "timestamp": "t",
                    "type": "session_meta",
                    "payload": {"cli_version": 5},
                },
                call("c1"),
            ]
        )

    def test_tokenTurnIds_uniqueAcrossSessionsSharingNoId(self) -> None:
        a = normalize(
            [
                meta(),
                turn_context("m"),
                token_count("t", usage(1, 1, 0), usage(1, 1, 0)),
            ]
        )
        b_meta = meta()
        b_meta["payload"]["id"] = "s-2"
        b = normalize(
            [
                b_meta,
                turn_context("m"),
                token_count("t", usage(1, 1, 0), usage(1, 1, 0)),
            ]
        )
        self.assertNotEqual(a[0]["message"]["id"], b[0]["message"]["id"])

    def test_malformedJsonlLineInMiddle_doesNotDropLaterTokenRows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.jsonl"
            good = [
                meta(),
                turn_context("m"),
                token_count("t1", usage(1, 1, 0), usage(1, 1, 0)),
            ]
            path.write_text(
                json.dumps(good[0])
                + "\n{not json\n"
                + "".join(json.dumps(r) + "\n" for r in good[1:])
            )
            entries = list(ingest.codex_normalize(str(path)))
        self.assertEqual(len(token_turns(entries)), 1)

    def test_tokenTurnIds_filesWithoutSessionMeta_stayDistinctPerFile(self) -> None:
        rows = [token_count("t", usage(1, 1, 0), usage(1, 1, 0))]
        ids = []
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("a.jsonl", "b.jsonl"):
                path = Path(tmp) / name
                path.write_text("".join(json.dumps(r) + "\n" for r in rows))
                ids.extend(
                    t["message"]["id"]
                    for t in token_turns(list(ingest.codex_normalize(str(path))))
                )
        self.assertEqual(len(ids), 2)
        self.assertEqual(len(set(ids)), 2)

    def test_forkedRollout_keepsFirstSessionMetaVersionAndCwd(self) -> None:
        child, parent = meta("1.0.0"), meta("2.0.0")
        child["payload"].update(id="child", cwd="/child")
        parent["payload"].update(id="parent", cwd="/parent")
        entries = normalize([child, parent, call("c1")])
        self.assertEqual(entries[-1]["version"], "1.0.0")
        self.assertEqual(entries[-1]["cwd"], "/child")


class IngestEndToEndAttacks(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        (self.home / ".claude/projects/p").mkdir(parents=True)
        (self.home / ".codex/sessions/2026/05/30").mkdir(parents=True)

    def write(self, rel: str, rows: list[dict]) -> None:
        (self.home / rel).write_text("".join(json.dumps(r) + "\n" for r in rows))

    def ingest(self) -> Path:
        env = {
            # tests/harness_climb sets SESSIONS_DB at import; this ingest must use XDG_CACHE_HOME.
            **{k: v for k, v in os.environ.items() if k != "SESSIONS_DB"},
            "HOME": str(self.home),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
        }
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--force"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return self.home / ".cache/dotfiles/session-analytics/sessions.duckdb"

    def q(self, db: Path, sql: str) -> list[dict]:
        out = subprocess.run(
            ["duckdb", str(db), "-json", "-c", sql],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout) if out.stdout.strip() else []

    def claude(self, ts: str, version: str) -> dict:
        return {
            "type": "assistant",
            "timestamp": ts,
            "sessionId": "c-1",
            "cwd": "/w",
            "version": version,
            "message": {"content": [{"type": "text", "text": "x"}]},
        }

    def test_sessionsVersion_sessionSpanningNumericVersions_reportsTheLatest(
        self,
    ) -> None:
        self.write(
            ".claude/projects/p/s.jsonl",
            [
                self.claude("2026-05-30T10:00:00Z", "2.1.9"),
                self.claude("2026-05-30T10:05:00Z", "2.1.10"),
            ],
        )
        db = self.ingest()
        (row,) = self.q(db, "SELECT version FROM sessions WHERE harness='claude'")
        self.assertEqual(row["version"], "2.1.10")

    def test_sessionsVersion_codexSessionWithoutCliVersion_isNull(self) -> None:
        self.write(
            ".codex/sessions/2026/05/30/r.jsonl",
            [
                {
                    "timestamp": "2026-05-30T11:00:00Z",
                    "type": "session_meta",
                    "payload": {"id": "x-1", "cwd": "/w"},
                },
                {
                    "timestamp": "2026-05-30T11:00:02Z",
                    "type": "response_item",
                    "payload": {
                        "type": "function_call",
                        "name": "shell",
                        "arguments": '{"command":["ls"]}',
                        "call_id": "c",
                    },
                },
            ],
        )
        db = self.ingest()
        (row,) = self.q(db, "SELECT version FROM sessions WHERE harness='codex'")
        self.assertIsNone(row["version"])

    def test_modelTurns_codexTokenCountBeforeTurnContext_stillBecomesARow(self) -> None:
        self.write(
            ".codex/sessions/2026/05/30/r.jsonl",
            [
                {
                    "timestamp": "2026-05-30T11:00:00Z",
                    "type": "session_meta",
                    "payload": {"id": "x-1", "cwd": "/w", "cli_version": "0.1.0"},
                },
                token_count("2026-05-30T11:00:01Z", usage(10, 2, 0), usage(10, 2, 0)),
            ],
        )
        db = self.ingest()
        (row,) = self.q(
            db, "SELECT count(*) AS n FROM model_turns WHERE harness='codex'"
        )
        self.assertEqual(row["n"], 1)

    def test_modelTurns_twoCodexSessionsKeepSeparateTokenRows(self) -> None:
        for i in (1, 2):
            self.write(
                f".codex/sessions/2026/05/30/r{i}.jsonl",
                [
                    {
                        "timestamp": "2026-05-30T11:00:00Z",
                        "type": "session_meta",
                        "payload": {
                            "id": f"x-{i}",
                            "cwd": "/w",
                            "cli_version": "0.1.0",
                        },
                    },
                    {
                        "timestamp": "2026-05-30T11:00:01Z",
                        "type": "turn_context",
                        "payload": {"cwd": "/w", "model": "m"},
                    },
                    token_count(
                        "2026-05-30T11:00:02Z", usage(10, 2, 0), usage(10, 2, 0)
                    ),
                ],
            )
        db = self.ingest()
        (row,) = self.q(
            db,
            "SELECT count(*) AS n, count(DISTINCT sessionId) AS s FROM model_turns WHERE harness='codex'",
        )
        self.assertEqual((row["n"], row["s"]), (2, 2))


if __name__ == "__main__":
    unittest.main()
