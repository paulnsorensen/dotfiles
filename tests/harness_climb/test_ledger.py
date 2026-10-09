"""Ledger: STOP file, append format, and the keep merge-tree check."""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

from .support import RepoCase, call, gate_json, hc_git, run_cli

FIELDS = ("round", "change", "pr", "lab", "claude", "codex", "candidate", "merge")


class LedgerCase(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.commit({"README.md": "base\n"}, "base")

    def ledger(self, action: str, **fields: Any) -> tuple[int, dict[str, Any]]:
        argv = [
            "ledger",
            action,
            "--repo",
            str(self.repo),
            "--state-dir",
            str(self.state),
            "--thread",
            "t1",
        ]
        for key, value in fields.items():
            argv += [f"--{key}", str(value)]
        return call(*argv)

    def fields(self, **over: Any) -> dict[str, Any]:
        base = {
            "round": 1,
            "change": "tighten the skill",
            "pr": "https://example.com/pr/1",
            "lab": "held",
            "claude": "keep",
            "codex": "keep",
            "candidate": "keep",
            "merge": "HEAD",
        }
        base.update(over)
        return base

    def ledger_file(self) -> Path:
        return self.state / "t1" / "ledger.md"

    def merge_branch(self, files: dict[str, str], rnd: int = 1) -> str:
        self.git("checkout", "-q", "-b", f"harness-climb/t1/r{rnd}")
        self.commit(files, "branch work")
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--no-ff", "-m", "merge", f"harness-climb/t1/r{rnd}")
        return self.git("rev-parse", "HEAD")


class StopTests(LedgerCase):
    def snapshot(self) -> tuple[Any, ...]:
        files = sorted(
            str(p.relative_to(self.dir))
            for p in self.dir.rglob("*")
            if ".git" not in p.parts and p.is_file()
        )
        return (
            files,
            self.git("rev-parse", "HEAD"),
            self.git("branch", "--list"),
            self.git("status", "--porcelain"),
        )

    def test_stop_halts_every_subcommand_without_writes(self) -> None:
        stop = self.state / "t1" / "STOP"
        stop.parent.mkdir(parents=True)
        stop.write_text("hold the climb for the audit\nsecond line stays hidden\n")
        common = [
            "--repo",
            str(self.repo),
            "--state-dir",
            str(self.state),
            "--thread",
            "t1",
        ]
        commands = {
            "analyze": ["analyze", *common],
            "critic": ["critic", *common, "--round", "1"],
            "freeze": [
                "freeze",
                *common,
                "--round",
                "1",
                "--component",
                "skill",
                "--targeted-query",
                "SELECT 1",
            ],
            "field-gate": ["field-gate", *common, "--round", "1", "--merge", "HEAD"],
            "ledger-append": [
                "ledger",
                "append",
                *common,
                *[
                    a
                    for k, v in self.fields(candidate="pending").items()
                    for a in (f"--{k}", str(v))
                ],
            ],
            "ledger-tail": ["ledger", "tail", *common],
        }
        before = self.snapshot()
        for name, argv in commands.items():
            with self.subTest(command=name):
                rc, out = call(*argv)
                self.assertEqual(rc, 0)
                self.assertEqual(
                    out, {"status": "stopped", "reason": "hold the climb for the audit"}
                )
                self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.ledger_file().exists())

    def test_stop_short_circuits_before_ref_resolution(self) -> None:
        stop = self.state / "t1" / "STOP"
        stop.parent.mkdir(parents=True)
        stop.write_text("hold the climb for the audit\n")
        common = ["--repo", str(self.repo), "--state-dir", str(self.state)]
        commands = {
            "critic": ["critic", *common, "--thread", "t1", "--round", "1"],
            "ledger-pending": ["ledger", "pending", *common, "--thread", "t1"],
            "ledger-stop-check": ["ledger", "stop-check", *common, "--thread", "t1"],
        }
        for name, argv in commands.items():
            with self.subTest(command=name):
                with mock.patch.object(
                    hc_git, "resolve_main", side_effect=AssertionError("resolved")
                ) as resolve:
                    rc, out = call(*argv)
                resolve.assert_not_called()
                self.assertEqual(rc, 0)
                self.assertEqual(
                    out, {"status": "stopped", "reason": "hold the climb for the audit"}
                )

    def test_stop_does_not_halt_a_command_without_a_thread(self) -> None:
        stop = self.state / "t1" / "STOP"
        stop.parent.mkdir(parents=True)
        stop.write_text("hold the climb for the audit\n")
        rc, out = call("soak-check", "--repo", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertNotEqual(out.get("status"), "stopped")
        self.assertTrue(out)


class AppendTests(LedgerCase):
    def test_append_writes_one_line_with_every_field(self) -> None:
        rc, out = self.ledger(
            "append",
            **self.fields(
                candidate="pending", claude="pending", codex="pending", merge="none"
            ),
        )
        self.assertEqual((rc, out["status"]), (0, "appended"))
        rc, out = self.ledger(
            "append",
            **self.fields(
                round=2,
                change="a | b\nc",
                candidate="rejected",
                claude="n/a",
                codex="n/a",
                merge="none",
            ),
        )
        self.assertEqual(rc, 0)
        lines = self.ledger_file().read_text().splitlines()
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertEqual(
                [part.split("=", 1)[0] for part in line.split(" | ")], list(FIELDS)
            )
        self.assertIn("change=a / b c", lines[1])

    def test_append_refuses_missing_field_and_bad_verdict(self) -> None:
        fields = self.fields(candidate="pending", claude="pending", codex="pending")
        del fields["pr"]
        rc, out = self.ledger("append", **fields)
        self.assertEqual((rc, out["status"]), (1, "refused"))
        self.assertIn("pr", out["error"])
        rc, out = self.ledger("append", **self.fields(candidate="great"))
        self.assertEqual(rc, 1)
        self.assertFalse(self.ledger_file().exists())

    def test_append_tail_returns_last_lines(self) -> None:
        for rnd in (1, 2, 3):
            self.ledger(
                "append",
                **self.fields(
                    round=rnd,
                    candidate="pending",
                    claude="pending",
                    codex="pending",
                    merge="none",
                ),
            )
        rc, out = self.ledger("tail", last=2)
        self.assertEqual(rc, 0)
        self.assertEqual(
            [line.split(" | ")[0] for line in out["lines"]], ["round=2", "round=3"]
        )


class KeepMergeTreeTests(LedgerCase):
    def gate_file(self, rnd: int = 1) -> dict[str, str]:
        return {
            f"harness-climb/gates/t1-r{rnd}.json": json.dumps(gate_json(rnd=rnd)) + "\n"
        }

    def refused(self, **over: Any) -> dict[str, Any]:
        rc, out = self.ledger("append", **self.fields(**over))
        self.assertEqual((rc, out["status"]), (1, "refused"), out)
        self.assertFalse(self.ledger_file().exists())
        return out

    def test_keep_accepted_when_merge_holds_edit_and_gate_file(self) -> None:
        merge = self.merge_branch({"skills/foo/SKILL.md": "edit\n", **self.gate_file()})
        for verdict in ("keep", "keep-cheaper"):
            rc, out = self.ledger(
                "append",
                **self.fields(
                    candidate=verdict, claude=verdict, codex=verdict, merge=merge
                ),
            )
            self.assertEqual((rc, out["status"]), (0, "appended"), out)
        self.assertEqual(len(self.ledger_file().read_text().splitlines()), 2)

    def test_keep_refused_without_gate_file(self) -> None:
        merge = self.merge_branch({"skills/foo/SKILL.md": "edit\n"})
        self.assertIn(
            "harness-climb/gates/t1-r1.json", self.refused(merge=merge)["error"]
        )

    def test_keep_refused_for_gate_only_merge(self) -> None:
        merge = self.merge_branch(self.gate_file())
        self.assertIn("changes nothing besides", self.refused(merge=merge)["error"])

    def test_keep_refused_for_unknown_merge(self) -> None:
        self.refused(merge="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
        self.refused(merge="none")

    def test_keep_refused_for_wrong_round_gate(self) -> None:
        merge = self.merge_branch(
            {"skills/foo/SKILL.md": "edit\n", **self.gate_file(rnd=2)}
        )
        self.assertIn("t1-r1.json", self.refused(merge=merge)["error"])

    def test_non_keep_verdicts_need_no_merge_tree(self) -> None:
        for verdict in ("revert", "inconclusive"):
            rc, out = self.ledger(
                "append",
                **self.fields(
                    candidate=verdict, claude=verdict, codex=verdict, merge="HEAD"
                ),
            )
            self.assertEqual(rc, 0, out)


class SanitizeTests(LedgerCase):
    def test_pipe_next_to_any_whitespace_never_starts_a_field(self) -> None:
        for rnd, change in enumerate(("x\t|\tround=9", "x |\nround=9"), start=1):
            with self.subTest(change=change):
                rc, out = self.ledger(
                    "append",
                    **self.fields(
                        round=rnd,
                        change=change,
                        candidate="pending",
                        claude="pending",
                        codex="pending",
                        merge="none",
                    ),
                )
                self.assertEqual(rc, 0, out)
                line = self.ledger_file().read_text().splitlines()[-1]
                parts = line.split(" | ")
                self.assertEqual([p.split("=", 1)[0] for p in parts], list(FIELDS))
                self.assertEqual(parts[0], f"round={rnd}")


class CandidateConsistencyTests(LedgerCase):
    def test_candidate_verdict_must_equal_the_combined_harness_verdicts(self) -> None:
        for claude, codex, candidate in (
            ("revert", "keep", "keep"),
            ("keep", "keep", "inconclusive"),
            ("pending", "pending", "keep"),
        ):
            with self.subTest(claude=claude, codex=codex, candidate=candidate):
                rc, out = self.ledger(
                    "append",
                    **self.fields(claude=claude, codex=codex, candidate=candidate),
                )
                self.assertEqual((rc, out["status"]), (1, "refused"), out)
                self.assertIn("combine", out["error"])
        self.assertFalse(self.ledger_file().exists())

    def test_matching_verdicts_are_accepted(self) -> None:
        rc, out = self.ledger(
            "append",
            **self.fields(claude="revert", codex="keep", candidate="revert"),
        )
        self.assertEqual((rc, out["status"]), (0, "appended"), out)


class StopCheckTests(LedgerCase):
    def verdict(self, rnd: int, verdict: str) -> None:
        rc, out = self.ledger(
            "append",
            **self.fields(
                round=rnd,
                claude=verdict,
                codex=verdict,
                candidate=verdict,
                merge="none",
            ),
        )
        self.assertEqual(rc, 0, out)

    def stop_file(self) -> Path:
        return self.state / "t1" / "STOP"

    def test_three_non_keep_verdicts_write_stop(self) -> None:
        for rnd in (1, 2, 3):
            self.verdict(rnd, "inconclusive" if rnd % 2 else "revert")
        rc, out = self.ledger("stop-check")
        self.assertEqual(
            (rc, out["stop"], out["reason"]), (0, True, "diminishing-returns")
        )
        first = self.stop_file().read_text().splitlines()[0]
        self.assertEqual(first, "diminishing-returns")

    def test_two_non_keep_verdicts_do_not_stop(self) -> None:
        self.verdict(1, "revert")
        self.verdict(2, "inconclusive")
        rc, out = self.ledger("stop-check")
        self.assertEqual((rc, out["stop"]), (0, False))
        self.assertFalse(self.stop_file().exists())

    def test_a_keep_inside_the_last_three_does_not_stop(self) -> None:
        merge = self.merge_branch(
            {
                "skills/foo/SKILL.md": "edit\n",
                "harness-climb/gates/t1-r2.json": json.dumps(gate_json(rnd=2)) + "\n",
            },
            rnd=2,
        )
        self.verdict(1, "revert")
        rc, out = self.ledger(
            "append",
            **self.fields(
                round=2, claude="keep", codex="keep", candidate="keep", merge=merge
            ),
        )
        self.assertEqual(rc, 0, out)
        self.verdict(3, "revert")
        self.verdict(4, "revert")
        rc, out = self.ledger("stop-check")
        self.assertFalse(out["stop"], out)

    def test_rejected_rounds_are_not_field_verdicts(self) -> None:
        self.verdict(1, "revert")
        self.verdict(2, "revert")
        rc, _ = self.ledger(
            "append",
            **self.fields(
                round=3, claude="n/a", codex="n/a", candidate="rejected", merge="none"
            ),
        )
        self.assertEqual(rc, 0)
        rc, out = self.ledger("stop-check")
        self.assertFalse(out["stop"], out)


class ThreadNameTests(LedgerCase):
    def tail(self, thread: str) -> Any:
        return run_cli(
            "ledger", "tail", "--repo", str(self.repo),
            "--state-dir", str(self.state), "--thread", thread,
        )  # fmt: skip

    def test_thread_with_path_or_branch_characters_is_refused(self) -> None:
        for thread in ("../x", "A", "-x", "a/b", "a b", "a_b"):
            with self.subTest(thread=thread):
                proc = self.tail(thread)
                self.assertEqual(proc.returncode, 2)
                self.assertIn("thread", proc.stderr)

    def test_lowercase_digit_hyphen_thread_is_accepted(self) -> None:
        proc = self.tail("t1-a2")
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
