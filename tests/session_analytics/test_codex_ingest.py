from __future__ import annotations

import importlib.util
import json
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
        self.assertEqual(turn["type"], "assistant")
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


if __name__ == "__main__":
    unittest.main()
