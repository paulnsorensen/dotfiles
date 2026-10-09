"""Ledger pending: due rounds and the merge commit each one resolves to."""

from __future__ import annotations

import json
import unittest
from typing import Any

from .support import RepoCase, call, gate_json


class PendingCase(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.commit({"README.md": "base\n"}, "base")

    def gate_files(self, rnd: int) -> dict[str, str]:
        return {
            f"harness-climb/gates/t1-r{rnd}.json": json.dumps(gate_json(rnd=rnd)),
            f"skills/foo/r{rnd}.md": "edit\n",
        }

    def branch(self, rnd: int) -> str:
        self.git("checkout", "-q", "-b", f"harness-climb/t1/r{rnd}", "main")
        self.commit({f"skills/foo/r{rnd}.md": "edit\n"}, f"edit r{rnd}")
        head = self.commit(self.gate_files(rnd), f"freeze r{rnd}")
        self.git("checkout", "-q", "main")
        return head

    def merge(self, rnd: int) -> str:
        self.git(
            "merge", "-q", "--no-ff", "-m", f"merge r{rnd}", f"harness-climb/t1/r{rnd}"
        )
        return self.git("rev-parse", "HEAD")

    def append(self, rnd: int, **over: str) -> None:
        fields = {
            "round": str(rnd),
            "change": "c",
            "pr": "none",
            "lab": "held",
            "claude": "pending",
            "codex": "pending",
            "candidate": "pending",
            "merge": "none",
            **over,
        }
        argv = ["ledger", "append", "--repo", str(self.repo)]
        argv += ["--state-dir", str(self.state), "--thread", "t1"]
        for key, value in fields.items():
            argv += [f"--{key}", value]
        rc, out = call(*argv)
        self.assertEqual(rc, 0, out)

    def pending(self) -> list[dict[str, Any]]:
        rc, out = call(
            "ledger", "pending", "--repo", str(self.repo),
            "--state-dir", str(self.state), "--thread", "t1",
        )  # fmt: skip
        self.assertEqual((rc, out["status"]), (0, "ok"), out)
        return out["pending"]

    def ledger_text(self) -> str:
        return (self.state / "t1" / "ledger.md").read_text()


class PendingTests(PendingCase):
    def test_pending_without_a_ledger_is_empty(self) -> None:
        self.assertEqual(self.pending(), [])

    def test_unmerged_branch_commit_is_never_the_merge(self) -> None:
        self.branch(1)
        self.append(1)
        self.git("checkout", "-q", "harness-climb/t1/r1")
        (row,) = self.pending()
        self.assertEqual(row["round"], 1)
        self.assertIsNone(row["merge"])
        self.assertEqual(row["gate"], "harness-climb/gates/t1-r1.json")

    def test_no_ff_merge_resolves_to_the_first_parent_merge_commit(self) -> None:
        branch_head = self.branch(1)
        self.append(1)
        merge = self.merge(1)
        (row,) = self.pending()
        self.assertEqual(row["merge"], merge)
        self.assertNotEqual(row["merge"], branch_head)

    def test_fast_forward_merge_resolves_to_the_gate_commit_on_main(self) -> None:
        head = self.branch(1)
        self.append(1)
        self.git("merge", "-q", "--ff-only", "harness-climb/t1/r1")
        (row,) = self.pending()
        self.assertEqual(row["merge"], head)

    def test_each_round_resolves_to_its_own_merge(self) -> None:
        self.branch(1)
        self.append(1)
        first = self.merge(1)
        self.branch(2)
        self.append(2)
        second = self.merge(2)
        rows = {r["round"]: r["merge"] for r in self.pending()}
        self.assertEqual(rows, {1: first, 2: second})

    def test_latest_line_per_round_wins_and_the_ledger_only_grows(self) -> None:
        self.branch(1)
        self.append(1)
        merge = self.merge(1)
        before = self.ledger_text()
        self.append(
            1,
            claude="inconclusive",
            codex="inconclusive",
            candidate="inconclusive",
            merge=merge,
        )
        self.assertEqual(self.pending(), [])
        self.assertTrue(self.ledger_text().startswith(before))
        self.assertEqual(len(self.ledger_text().splitlines()), 2)

    def test_refused_and_rejected_rounds_are_not_pending(self) -> None:
        self.append(1, claude="n/a", codex="n/a", candidate="n/a")
        self.append(2, claude="n/a", codex="n/a", candidate="rejected")
        self.assertEqual(self.pending(), [])

    def test_not_due_is_not_a_ledger_candidate(self) -> None:
        rc, out = call(
            "ledger", "append", "--repo", str(self.repo), "--state-dir", str(self.state),
            "--thread", "t1", "--round", "1", "--change", "c", "--pr", "none",
            "--lab", "held", "--claude", "pending", "--codex", "pending",
            "--candidate", "not-due", "--merge", "none",
        )  # fmt: skip
        self.assertEqual((rc, out["status"]), (1, "refused"))


if __name__ == "__main__":
    unittest.main()
