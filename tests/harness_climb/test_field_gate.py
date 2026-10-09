from __future__ import annotations

import itertools
import json
import unittest
from typing import Any

from .support import (
    DAY,
    T0,
    RepoCase,
    cli,
    gate_json,
    hc_git,
    hc_stats,
    make_rows,
    run_cli,
    spread,
)

AFTER = T0 + DAY
N = 6


def window_rows(
    harness: str,
    before: dict[str, Any],
    after: dict[str, Any],
    version: str | None = "1.0",
    after_version: str | None = None,
) -> list[dict[str, Any]]:
    """Six sessions in each window; keyword values are lists or constants."""
    rows = make_rows(harness, AFTER - 3 * DAY, N, version, **before)
    rows += make_rows(harness, AFTER + 3600, N, after_version or version, **after)
    return rows


QUIET = {
    "tool_error_rate": spread(0.1, 0.01, N),
    "permission_denials": 0.0,
    "stop_hook_blocks": 0.0,
}


def side(target: float, tokens: float | None = 1000.0, **guards: Any) -> dict[str, Any]:
    return {
        "target": spread(target, 1, N),
        "tokens_per_turn": None if tokens is None else spread(tokens, 10, N),
        **QUIET,
        **guards,
    }


class VerdictCase(unittest.TestCase):
    gate = hc_stats.normalize_gate(gate_json(min_sessions=4))

    def verdict(
        self,
        before: dict,
        after: dict,
        harness: str = "claude",
        gate: dict | None = None,
    ) -> dict:
        return hc_stats.evaluate_harness(
            harness, gate or self.gate, window_rows(harness, before, after), AFTER
        )

    def test_verdict_keep(self) -> None:
        got = self.verdict(side(10), side(5))
        self.assertEqual((got["verdict"], got["reason"]), ("keep", "target"))
        self.assertAlmostEqual(got["target"]["gain"], 0.5)

    def test_verdict_revert_token_cost(self) -> None:
        got = self.verdict(side(10), side(5, tokens=1600))
        self.assertEqual((got["verdict"], got["reason"]), ("revert", "token-cost"))

    def test_verdict_token_per_gain_scales_the_cost_rule(self) -> None:
        gate = hc_stats.normalize_gate(gate_json(min_sessions=4, token_per_gain=2.0))
        self.assertEqual(
            self.verdict(side(10), side(5, tokens=1600), gate=gate)["verdict"], "keep"
        )

    def test_verdict_keep_cheaper(self) -> None:
        got = self.verdict(side(10), side(10, tokens=800))
        self.assertEqual((got["verdict"], got["reason"]), ("keep-cheaper", "tokens"))

    def test_verdict_noise_band_is_inconclusive(self) -> None:
        got = self.verdict(side(10), side(10))
        self.assertEqual((got["verdict"], got["reason"]), ("inconclusive", "no-effect"))

    def test_verdict_target_regression_reverts(self) -> None:
        self.assertEqual(self.verdict(side(10), side(15))["verdict"], "revert")

    def test_verdict_higher_direction_flips_the_sign(self) -> None:
        gate = hc_stats.normalize_gate(gate_json(min_sessions=4, direction="higher"))
        self.assertEqual(self.verdict(side(5), side(10), gate=gate)["verdict"], "keep")
        self.assertEqual(
            self.verdict(side(10), side(5), gate=gate)["verdict"], "revert"
        )

    def test_guard_regression_reverts_and_names_the_guard(self) -> None:
        after = side(5, tool_error_rate=spread(0.3, 0.01, N))
        got = self.verdict(side(10), after)
        self.assertEqual((got["verdict"], got["reason"]), ("revert", "tool_error_rate"))

    def test_guard_claude_permission_denials_and_stop_hooks_count(self) -> None:
        for name in ("permission_denials", "stop_hook_blocks"):
            after = side(5, **{name: spread(3.0, 0.5, N)})
            got = self.verdict(side(10), after)
            self.assertEqual((got["verdict"], got["reason"]), ("revert", name), name)

    def test_guard_tokens_are_not_a_guard(self) -> None:
        got = self.verdict(side(10), side(10, tokens=5000))
        self.assertEqual(got["verdict"], "inconclusive")
        self.assertNotIn("tokens_per_turn", got["guards"])

    def test_guard_codex_records_only_tool_error_rate(self) -> None:
        after = side(
            5,
            permission_denials=spread(9.0, 0.5, N),
            stop_hook_blocks=spread(9.0, 0.5, N),
        )
        got = self.verdict(side(10), after, harness="codex")
        self.assertEqual(got["verdict"], "keep")
        self.assertEqual(got["guards"]["permission_denials"], {"status": "n/a"})
        self.assertEqual(got["guards"]["stop_hook_blocks"], {"status": "n/a"})
        self.assertEqual(got["guards"]["tool_error_rate"]["status"], "pass")

    def test_guard_codex_tool_error_regression_still_reverts(self) -> None:
        got = self.verdict(
            side(10), side(5, tool_error_rate=spread(0.4, 0.01, N)), harness="codex"
        )
        self.assertEqual((got["verdict"], got["reason"]), ("revert", "tool_error_rate"))

    def test_guard_too_few_sessions_is_inconclusive_with_counts(self) -> None:
        rows = make_rows(
            "claude", AFTER - 3 * DAY, 3, target=spread(10, 1, 3)
        ) + make_rows("claude", AFTER + 3600, 5, target=spread(5, 1, 5))
        got = hc_stats.evaluate_harness("claude", self.gate, rows, AFTER)
        self.assertEqual(
            (got["verdict"], got["reason"]), ("inconclusive", "min-sessions")
        )
        self.assertEqual(got["sessions"], {"before": 3, "after": 5})

    def test_guard_without_data_is_not_a_pass(self) -> None:
        before = {**side(10), "tool_error_rate": None}
        got = self.verdict(before, side(5))
        self.assertEqual(
            (got["verdict"], got["reason"]),
            ("inconclusive", "guard-no-data:tool_error_rate"),
        )

    def test_verdict_improvement_without_token_data_is_inconclusive(self) -> None:
        got = self.verdict(side(10, tokens=None), side(5, tokens=None))
        self.assertEqual(
            (got["verdict"], got["reason"]), ("inconclusive", "tokens-unavailable")
        )


class CombineCase(unittest.TestCase):
    def test_combine_table_covers_every_pair(self) -> None:
        def expected(a: str, b: str) -> str:
            pair = {a, b}
            for winner in ("revert", "keep", "keep-cheaper"):
                if winner in pair:
                    return winner
            return "inconclusive"

        table = {
            ("keep", "keep"): "keep",
            ("keep", "keep-cheaper"): "keep",
            ("keep", "revert"): "revert",
            ("keep", "inconclusive"): "keep",
            ("keep-cheaper", "keep-cheaper"): "keep-cheaper",
            ("keep-cheaper", "revert"): "revert",
            ("keep-cheaper", "inconclusive"): "keep-cheaper",
            ("revert", "revert"): "revert",
            ("revert", "inconclusive"): "revert",
            ("inconclusive", "inconclusive"): "inconclusive",
        }
        for a, b in itertools.product(hc_stats.VERDICTS, repeat=2):
            want = table.get((a, b)) or table[(b, a)]
            self.assertEqual(hc_stats.combine([a, b]), want, (a, b))
            self.assertEqual(want, expected(a, b))


class WindowCase(unittest.TestCase):
    def test_window_before_ends_where_after_starts(self) -> None:
        w = hc_stats.select_windows(100 * DAY, 7, None)
        self.assertEqual(w["before"], (93 * DAY, 100 * DAY))
        self.assertEqual(w["after"], (100 * DAY, 107 * DAY))

    def test_window_starts_at_a_recent_version_change(self) -> None:
        self.assertEqual(
            hc_stats.select_windows(100 * DAY, 7, 98 * DAY)["before"],
            (98 * DAY, 100 * DAY),
        )

    def test_window_ignores_a_version_change_older_than_the_soak(self) -> None:
        self.assertEqual(
            hc_stats.select_windows(100 * DAY, 7, 80 * DAY)["before"],
            (93 * DAY, 100 * DAY),
        )

    def test_window_last_version_change_comes_from_session_versions(self) -> None:
        rows = (
            make_rows("claude", 0, 2, "1")
            + make_rows("claude", 10 * DAY, 2, "2")
            + make_rows("claude", 20 * DAY, 2, "3")
        )
        self.assertEqual(hc_stats.last_version_change(rows, 15 * DAY), 10 * DAY)
        self.assertEqual(hc_stats.last_version_change(rows, 30 * DAY), 20 * DAY)
        self.assertIsNone(hc_stats.last_version_change(rows, 5 * DAY))

    def test_window_unversioned_sessions_never_mark_a_change(self) -> None:
        rows = make_rows("codex", 0, 3, None) + make_rows("codex", DAY, 3, "1")
        self.assertIsNone(hc_stats.last_version_change(rows, 5 * DAY))

    def test_window_evaluate_drops_sessions_before_the_version_change(self) -> None:
        # Old-version sessions sit before the change; the before window starts at the change.
        old = make_rows("claude", AFTER - 6 * DAY, 6, "0.9", **side(10))
        new_before = make_rows("claude", AFTER - 2 * DAY, 6, "1.0", **side(10))
        after = make_rows("claude", AFTER + 3600, 6, "1.0", **side(5))
        gate = hc_stats.normalize_gate(gate_json(min_sessions=4))
        got = hc_stats.evaluate_harness("claude", gate, old + new_before + after, AFTER)
        self.assertEqual(got["verdict"], "keep")
        self.assertEqual(got["sessions"]["before"], 6)
        self.assertEqual(got["windows"]["before"][0], AFTER - 2 * DAY)


class VersionChangedCase(unittest.TestCase):
    gate = hc_stats.normalize_gate(gate_json(min_sessions=4))

    def test_version_changed_inside_the_after_window(self) -> None:
        rows = window_rows("claude", side(10), side(5), "1.0")
        for row in rows[-3:]:
            row["version"] = "2.0"
        got = hc_stats.evaluate_harness("claude", self.gate, rows, AFTER)
        self.assertEqual(
            (got["verdict"], got["reason"]), ("inconclusive", "version-changed")
        )
        self.assertEqual(got["versions"], ["1.0", "2.0"])

    def test_version_changed_between_the_windows(self) -> None:
        rows = window_rows("claude", side(10), side(5), "1.0", after_version="2.0")
        got = hc_stats.evaluate_harness("claude", self.gate, rows, AFTER)
        self.assertEqual(got["reason"], "version-changed")

    def test_version_changed_only_marks_the_affected_harness(self) -> None:
        rows = window_rows(
            "claude", side(10), side(5), "1.0", after_version="2.0"
        ) + window_rows("codex", side(10), side(5))
        verdicts = {
            h: hc_stats.evaluate_harness(h, self.gate, rows, AFTER)["verdict"]
            for h in ("claude", "codex")
        }
        self.assertEqual(verdicts, {"claude": "inconclusive", "codex": "keep"})
        self.assertEqual(hc_stats.combine(verdicts.values()), "keep")


class GateCase(RepoCase):
    """Field gate against a temp repo with a real merge commit and sync history."""

    def setUp(self) -> None:
        super().setUp()
        self.base = self.commit({"README.md": "x"}, date=T0 - DAY)
        self.merge = self.commit(
            {
                "skills/s/SKILL.md": "edit",
                "harness-climb/gates/t1-r1.json": json.dumps(gate_json(min_sessions=4)),
            },
            date=T0,
        )
        self.after = self.commit({"later.txt": "y"}, date=T0 + 3600)
        self.history = f"{AFTER} {self.merge}\n"
        self.rows = window_rows("claude", side(10), side(5)) + window_rows(
            "codex", side(10), side(5)
        )

    def run_gate(
        self, history: str | None = None, rows: Any = None, now: float | None = None
    ) -> dict[str, Any]:
        return cli.field_gate(
            self.repo,
            "t1",
            1,
            self.merge,
            self.history if history is None else history,
            self.rows if rows is None else rows,
            AFTER + 9 * DAY if now is None else now,
        )

    def test_merge_commit_gate_file_wins_over_working_tree_edits(self) -> None:
        before = self.run_gate()
        (self.repo / "harness-climb/gates/t1-r1.json").write_text(
            json.dumps(gate_json(min_sessions=1000, direction="higher"))
        )
        self.assertEqual(self.run_gate(), before)
        self.assertEqual(before["candidate"], "keep")
        self.assertEqual(before["gate"]["min_sessions"], 4)

    def test_merge_commit_gate_file_is_required(self) -> None:
        with self.assertRaises(hc_git.GitError):
            cli.field_gate(
                self.repo, "t1", 2, self.merge, self.history, self.rows, AFTER + 9 * DAY
            )

    def test_merge_commit_cli_reads_gate_from_the_commit(self) -> None:
        hist = self.dir / "hist.log"
        hist.write_text(self.history)
        rows = self.write_json("rows.json", self.rows)
        proc = run_cli(
            "field-gate",
            "--repo",
            str(self.repo),
            "--state-dir",
            str(self.state),
            "--thread",
            "t1",
            "--round",
            "1",
            "--merge",
            self.merge,
            "--history",
            str(hist),
            "--rows",
            str(rows),
            "--now",
            str(AFTER + 9 * DAY),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.out(proc)["candidate"], "keep")

    def test_held_lab_candidate_gets_the_same_verdict_as_a_promote_candidate(
        self,
    ) -> None:
        verdicts = []
        for lab in ("held", "promote"):
            gate = gate_json(min_sessions=4, lab=lab)
            merge = self.commit(
                {"harness-climb/gates/t1-r1.json": json.dumps(gate)}, date=T0
            )
            history = f"{AFTER} {merge}\n"
            got = cli.field_gate(
                self.repo, "t1", 1, merge, history, self.rows, AFTER + 9 * DAY
            )
            verdicts.append(
                (
                    got["candidate"],
                    {h: v["verdict"] for h, v in got["harnesses"].items()},
                )
            )
        self.assertEqual(verdicts[0], verdicts[1])
        self.assertEqual(verdicts[0][0], "keep")

    def test_sync_history_after_window_starts_at_the_first_line_containing_the_merge(
        self,
    ) -> None:
        history = (
            f"{T0 - 5} {self.base}\n{AFTER} {self.after}\n{AFTER + DAY} {self.merge}\n"
        )
        got = self.run_gate(history)
        self.assertEqual(got["sync"], {"epoch": AFTER, "sha": self.after})
        self.assertEqual(got["candidate"], "keep")

    def test_sync_history_skips_unknown_shas_and_garbage_lines(self) -> None:
        history = f"garbage\n{T0} {'0' * 40}\n{AFTER} {self.merge}\n"
        self.assertEqual(self.run_gate(history)["sync"]["epoch"], AFTER)

    def test_sync_history_without_a_containing_sync_is_inconclusive(self) -> None:
        got = self.run_gate(f"{T0} {self.base}\n")
        self.assertEqual(got["candidate"], "inconclusive")
        self.assertEqual({v["reason"] for v in got["harnesses"].values()}, {"no-sync"})

    def test_sync_history_late_sync_is_inconclusive_sync_late(self) -> None:
        late = T0 + 3 * DAY
        got = self.run_gate(f"{late} {self.merge}\n", now=late + 9 * DAY)
        self.assertEqual(got["candidate"], "inconclusive")
        self.assertEqual(
            {v["reason"] for v in got["harnesses"].values()}, {"sync-late"}
        )

    def test_sync_history_exactly_at_the_grace_is_not_late(self) -> None:
        edge = T0 + 2 * DAY
        rows = window_rows("claude", side(10), side(5))
        rows = [{**r, "start": r["start"] + DAY} for r in rows]
        got = cli.field_gate(
            self.repo,
            "t1",
            1,
            self.merge,
            f"{edge} {self.merge}\n",
            rows,
            edge + 9 * DAY,
        )
        self.assertNotEqual(got["harnesses"]["claude"]["reason"], "sync-late")

    def test_field_gate_before_the_soak_ends_is_not_due(self) -> None:
        got = self.run_gate(now=AFTER + DAY)
        self.assertEqual(got["status"], "not-due")

    def test_field_gate_ignores_other_harnesses(self) -> None:
        rows = self.rows + window_rows("omp", side(1), side(99), "9.9")
        self.assertEqual(self.run_gate(rows=rows)["candidate"], "keep")
        self.assertEqual(
            sorted(self.run_gate(rows=rows)["harnesses"]), ["claude", "codex"]
        )

    def test_version_changed_surfaces_through_the_field_gate(self) -> None:
        rows = window_rows(
            "claude", side(10), side(5), "1.0", after_version="2.0"
        ) + window_rows("codex", side(10), side(5), "1.0", after_version="2.0")
        got = self.run_gate(rows=rows)
        self.assertEqual(got["candidate"], "inconclusive")
        self.assertEqual(
            {v["reason"] for v in got["harnesses"].values()}, {"version-changed"}
        )

    def test_revert_pr_action_leaves_head_branches_and_tree_unchanged(self) -> None:
        rows = window_rows("claude", side(10), side(15)) + window_rows(
            "codex", side(10), side(5)
        )
        snapshot = lambda: (
            self.git("rev-parse", "HEAD"),
            self.git("branch", "--list"),
            self.git("status", "--porcelain"),
            self.git("stash", "list"),
        )
        before = snapshot()
        got = self.run_gate(rows=rows)
        self.assertEqual(
            (got["candidate"], got["action"]), ("revert", "open-revert-pr")
        )
        self.assertEqual(snapshot(), before)

    def test_revert_pr_action_is_absent_for_other_verdicts(self) -> None:
        self.assertEqual(self.run_gate()["action"], "none")


if __name__ == "__main__":
    unittest.main()
