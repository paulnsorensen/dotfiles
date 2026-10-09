"""Press-phase adversarial tests for the Codex ingest additions (AC-20)."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from .test_codex_ingest import (
    SCRIPT,
    call,
    ingest,
    meta,
    normalize,
    output,
    token_count,
    token_turns,
    turn_context,
    usage,
)


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


@unittest.skipUnless(shutil.which("duckdb"), "duckdb not installed")
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
            **os.environ,
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
