from __future__ import annotations

import itertools
import json
import unittest
import unittest.mock
from pathlib import Path
from typing import Any

from .support import (
    DAY,
    T0,
    RepoCase,
    call,
    gate_json,
    hc_db,
    hc_field_gate,
    hc_gate,
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
    gate = hc_gate.normalize_gate(gate_json(min_sessions=4))

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
        gate = hc_gate.normalize_gate(gate_json(min_sessions=4, token_per_gain=2.0))
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
        gate = hc_gate.normalize_gate(gate_json(min_sessions=4, direction="higher"))
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
        w = hc_stats.select_windows(100 * DAY, 7)
        self.assertEqual(w["before"], (93 * DAY, 100 * DAY))
        self.assertEqual(w["after"], (100 * DAY, 107 * DAY))

    def test_dominant_version_needs_min_sessions_in_both_windows(self) -> None:
        before = make_rows("claude", 0, 3, "1") + make_rows("claude", 0, 5, "2")
        after = make_rows("claude", 0, 4, "1") + make_rows("claude", 0, 1, "2")
        self.assertEqual(hc_stats.dominant_version(before, after, 3), "1")
        self.assertIsNone(hc_stats.dominant_version(before, after, 5))

    def test_window_interleaved_versions_are_filtered_not_inconclusive(self) -> None:
        # Claude interleaves versions. Each window holds both; the busiest shared version wins.
        rows = make_rows("claude", AFTER - 3 * DAY, 6, "1.0", **side(10))
        rows += make_rows("claude", AFTER - 2 * DAY, 2, "2.0", **side(10))
        rows += make_rows("claude", AFTER - DAY, 2, "1.0", **side(10))
        rows += make_rows("claude", AFTER + 3600, 6, "1.0", **side(5))
        rows += make_rows("claude", AFTER + 7200, 2, "2.0", **side(5))
        gate = hc_gate.normalize_gate(gate_json(min_sessions=4))
        got = hc_stats.evaluate_harness("claude", gate, rows, AFTER)
        self.assertEqual(got["verdict"], "keep")
        self.assertEqual(got["version"], "1.0")
        self.assertEqual(got["sessions"], {"before": 8, "after": 6})
        self.assertEqual(got["excluded"], 4)

    def test_window_evaluate_drops_sessions_of_other_versions(self) -> None:
        old = make_rows("claude", AFTER - 6 * DAY, 6, "0.9", **side(10))
        new_before = make_rows("claude", AFTER - 2 * DAY, 6, "1.0", **side(10))
        after = make_rows("claude", AFTER + 3600, 6, "1.0", **side(5))
        gate = hc_gate.normalize_gate(gate_json(min_sessions=4))
        got = hc_stats.evaluate_harness("claude", gate, old + new_before + after, AFTER)
        self.assertEqual(got["verdict"], "keep")
        self.assertEqual(got["sessions"]["before"], 6)
        self.assertEqual(got["excluded"], 6)


class VersionChangedCase(unittest.TestCase):
    gate = hc_gate.normalize_gate(gate_json(min_sessions=4))

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
        return hc_field_gate.field_gate(
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
            hc_field_gate.field_gate(
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
            got = hc_field_gate.field_gate(
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

    def test_no_containing_sync_within_the_grace_is_not_due_not_inconclusive(
        self,
    ) -> None:
        history = f"{T0} {self.base}\n"
        for now in (T0 + DAY, T0 + 2 * DAY):
            got = self.run_gate(history, now=now)
            self.assertEqual(got["status"], "not-due", now)
            self.assertEqual(got["due"], T0 + 2 * DAY)
            self.assertNotIn("candidate", got)
            self.assertNotIn("harnesses", got)

    def test_no_containing_sync_past_the_grace_is_inconclusive_sync_late(self) -> None:
        got = self.run_gate(f"{T0} {self.base}\n", now=T0 + 2 * DAY + 1)
        self.assertEqual(got["status"], "ok")
        self.assertEqual(got["candidate"], "inconclusive")
        self.assertEqual(
            {v["reason"] for v in got["harnesses"].values()}, {"sync-late"}
        )

    def test_db_refresh_failure_is_inconclusive_db_stale(self) -> None:
        def stale() -> Path:
            raise hc_db.RefreshFailed("session database refresh failed")

        got = hc_field_gate.field_gate(
            self.repo, "t1", 1, self.merge, self.history, None, AFTER + 9 * DAY, stale
        )
        self.assertEqual(got["candidate"], "inconclusive")
        self.assertEqual({v["reason"] for v in got["harnesses"].values()}, {"db-stale"})

    def test_early_verdicts_never_refresh_the_database(self) -> None:
        resolver = unittest.mock.Mock(side_effect=AssertionError("refreshed"))
        for history, now in (
            (f"{T0} {self.base}\n", T0 + DAY),
            (f"{T0} {self.base}\n", T0 + 3 * DAY),
            (self.history, AFTER + DAY),
        ):
            got = hc_field_gate.field_gate(
                self.repo, "t1", 1, self.merge, history, None, now, resolver
            )
            self.assertNotEqual(got.get("status"), "no-db")
        resolver.assert_not_called()

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
        got = hc_field_gate.field_gate(
            self.repo,
            "t1",
            1,
            self.merge,
            f"{edge} {self.merge}\n",
            rows,
            edge + 9 * DAY,
        )
        self.assertEqual(got["sync"]["epoch"], edge)
        self.assertEqual(got["harnesses"]["claude"]["verdict"], "keep")
        self.assertEqual(got["candidate"], "keep")

    def test_sync_inside_the_window_without_the_merge_is_sync_regressed(self) -> None:
        history = f"{self.history}{AFTER + DAY} {self.base}\n"
        got = self.run_gate(history)
        self.assertEqual(got["candidate"], "inconclusive")
        self.assertEqual(
            {v["reason"] for v in got["harnesses"].values()}, {"sync-regressed"}
        )

    def test_sync_after_the_window_without_the_merge_is_ignored(self) -> None:
        history = f"{self.history}{AFTER + 8 * DAY} {self.base}\n"
        self.assertEqual(
            self.run_gate(history, now=AFTER + 20 * DAY)["candidate"], "keep"
        )

    def test_first_sync_allows_clock_skew_of_60_seconds(self) -> None:
        got = hc_git.first_sync_containing(
            self.repo, self.merge, [(T0 - 60, self.merge)]
        )
        self.assertEqual(got, (T0 - 60, self.merge))

    def test_first_sync_skips_a_sync_600_seconds_before_the_merge(self) -> None:
        got = hc_git.first_sync_containing(
            self.repo, self.merge, [(T0 - 600, self.merge)]
        )
        self.assertIsNone(got)

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


def gate(**over: object) -> dict:
    return hc_gate.normalize_gate(gate_json(min_sessions=2, **over))


def rows(harness: str, n: int, **metrics: object) -> list[dict]:
    return make_rows(harness, T0, n, **metrics)


def judge(
    before: dict, after: dict, harness: str = "claude", **gate_over: object
) -> dict:
    """before/after: metric -> list. Missing guards default to a constant 0.1."""

    def build(spec: dict) -> list[dict]:
        n = len(next(iter(spec.values())))
        base = {
            "tool_error_rate": [0.1] * n,
            "permission_denials": [0.0] * n,
            "stop_hook_blocks": [0.0] * n,
            "tokens_per_turn": [100.0] * n,
        }
        return rows(harness, n, **{**base, **spec})

    return hc_stats.judge(harness, gate(**gate_over), build(before), build(after))


class WelchEdges(unittest.TestCase):
    def test_welch_zeroVarianceBothWindows_nonzeroDiffIsBeyond(self) -> None:
        v = judge({"target": [10.0] * 3}, {"target": [5.0] * 3})
        self.assertEqual(v["verdict"], "keep")

    def test_welch_zeroVarianceBothWindows_zeroDiffIsNoEffect(self) -> None:
        v = judge({"target": [10.0] * 3}, {"target": [10.0] * 3})
        self.assertEqual((v["verdict"], v["reason"]), ("inconclusive", "no-effect"))

    def test_welch_zeroVarianceOneWindow_stillUsesOtherVariance(self) -> None:
        before = [10.0, 12.0, 10.0, 12.0]
        v = judge({"target": before}, {"target": [11.0] * 4})
        self.assertEqual(v["verdict"], "inconclusive")
        self.assertGreater(v["target"]["se"], 0)

    def test_welch_singleSessionWindow_seUndefinedNeverBeyond(self) -> None:
        cmp = hc_stats.welch([1.0], [100.0])
        self.assertFalse(hc_stats.beyond(cmp))
        self.assertEqual(
            hc_stats.judge(
                "claude",
                {**gate(), "min_sessions": 1},
                rows(
                    "claude",
                    1,
                    target=10.0,
                    tool_error_rate=0.1,
                    permission_denials=0,
                    stop_hook_blocks=0,
                    tokens_per_turn=1.0,
                ),
                rows(
                    "claude",
                    1,
                    target=1.0,
                    tool_error_rate=0.1,
                    permission_denials=0,
                    stop_hook_blocks=0,
                    tokens_per_turn=1.0,
                ),
            )["verdict"],
            "inconclusive",
        )

    def test_judge_singleValueGuardWindow_isGuardNoData(self) -> None:
        v = judge(
            {"target": [10.0] * 3, "permission_denials": [0.0, None, None]},
            {"target": [5.0] * 3, "permission_denials": [50.0, None, None]},
        )
        self.assertEqual(
            (v["verdict"], v["reason"]),
            ("inconclusive", "guard-no-data:permission_denials"),
        )

    def test_normalizeGate_minSessionsOne_rejected(self) -> None:
        with self.assertRaises(ValueError):
            hc_gate.normalize_gate(gate_json(min_sessions=1))

    def test_beyond_exactlyTwoSE_isNotBeyond(self) -> None:
        # before [10,12]: var 2 -> SE 1 with a zero-variance after window
        v = judge({"target": [10.0, 12.0]}, {"target": [9.0, 9.0]})
        self.assertEqual(v["target"]["se"], 1.0)
        self.assertEqual(v["target"]["diff"], -2.0)
        self.assertEqual((v["verdict"], v["reason"]), ("inconclusive", "no-effect"))

    def test_beyond_justPastTwoSE_isBeyond(self) -> None:
        v = judge({"target": [10.0, 12.0]}, {"target": [8.99, 8.99]})
        self.assertEqual(v["verdict"], "keep")


class VerdictRules(unittest.TestCase):
    def test_judge_gainZeroTokensUp_isInconclusiveNotKeep(self) -> None:
        v = judge(
            {"target": [5.0] * 3, "tokens_per_turn": [100.0, 101.0, 102.0]},
            {"target": [5.0] * 3, "tokens_per_turn": [200.0, 201.0, 202.0]},
        )
        self.assertEqual(v["verdict"], "inconclusive")

    def test_judge_gainZeroTokensDropBeyond_keepCheaper(self) -> None:
        v = judge(
            {"target": [5.0] * 3, "tokens_per_turn": [100.0, 101.0, 102.0]},
            {"target": [5.0] * 3, "tokens_per_turn": [50.0, 51.0, 52.0]},
        )
        self.assertEqual(v["verdict"], "keep-cheaper")

    def test_judge_keepCheaperWithGuardRegression_reverts(self) -> None:
        v = judge(
            {
                "target": [5.0] * 3,
                "tokens_per_turn": [100.0, 101.0, 102.0],
                "permission_denials": [0.0] * 3,
            },
            {
                "target": [5.0] * 3,
                "tokens_per_turn": [50.0, 51.0, 52.0],
                "permission_denials": [9.0, 10.0, 11.0],
            },
        )
        self.assertEqual((v["verdict"], v["reason"]), ("revert", "permission_denials"))

    def test_judge_lowerDirectionTargetRises_reverts(self) -> None:
        v = judge({"target": [5.0] * 3}, {"target": [9.0] * 3})
        self.assertEqual((v["verdict"], v["reason"]), ("revert", "target"))

    def test_judge_higherDirectionTargetDrops_reverts(self) -> None:
        v = judge({"target": [9.0] * 3}, {"target": [5.0] * 3}, direction="higher")
        self.assertEqual((v["verdict"], v["reason"]), ("revert", "target"))

    def test_judge_higherDirectionTargetRises_keeps(self) -> None:
        v = judge({"target": [5.0] * 3}, {"target": [9.0] * 3}, direction="higher")
        self.assertEqual(v["verdict"], "keep")
        self.assertGreater(v["target"]["gain"], 0)

    def test_judge_guardImproves_isNotARegression(self) -> None:
        v = judge(
            {"target": [9.0] * 3, "tool_error_rate": [0.5] * 3},
            {"target": [5.0] * 3, "tool_error_rate": [0.1] * 3},
        )
        self.assertEqual(v["guards"]["tool_error_rate"]["status"], "pass")
        self.assertEqual(v["verdict"], "keep")

    def test_judge_guardRegressionNamesTheGuard(self) -> None:
        v = judge(
            {"target": [9.0] * 3, "stop_hook_blocks": [0.0] * 3},
            {"target": [5.0] * 3, "stop_hook_blocks": [4.0] * 3},
        )
        self.assertEqual((v["verdict"], v["reason"]), ("revert", "stop_hook_blocks"))

    def test_judge_tokenPerGainZero_anyCostIncreaseReverts(self) -> None:
        v = judge(
            {"target": [9.0] * 3, "tokens_per_turn": [100.0, 100.0, 100.0]},
            {"target": [5.0] * 3, "tokens_per_turn": [101.0, 101.0, 101.0]},
            token_per_gain=0,
        )
        self.assertEqual((v["verdict"], v["reason"]), ("revert", "token-cost"))

    def test_judge_tokenPerGainZero_zeroCostKeeps(self) -> None:
        v = judge({"target": [9.0] * 3}, {"target": [5.0] * 3}, token_per_gain=0)
        self.assertEqual(v["verdict"], "keep")

    def test_judge_tokenPerGainZero_infiniteGainStillRevertsOnCost(self) -> None:
        # direction=higher with a zero baseline makes gain infinite; 0 * inf is nan.
        v = judge(
            {"target": [0.0] * 3, "tokens_per_turn": [100.0] * 3},
            {"target": [5.0] * 3, "tokens_per_turn": [150.0] * 3},
            direction="higher",
            token_per_gain=0,
        )
        self.assertEqual((v["verdict"], v["reason"]), ("revert", "token-cost"))

    def test_judge_costExactlyAtBudget_keeps(self) -> None:
        # gain 0.5, cost 0.5, token_per_gain 1.0 -> cost <= budget
        v = judge(
            {"target": [10.0] * 3, "tokens_per_turn": [100.0] * 3},
            {"target": [5.0] * 3, "tokens_per_turn": [150.0] * 3},
        )
        self.assertEqual(v["verdict"], "keep")

    def test_judge_tokensAreNeverAGuard(self) -> None:
        v = judge(
            {"target": [10.0] * 3, "tokens_per_turn": [100.0] * 3},
            {"target": [2.0] * 3, "tokens_per_turn": [120.0] * 3},
        )
        self.assertNotIn("tokens_per_turn", v["guards"])
        self.assertEqual(v["verdict"], "keep")

    def test_judge_codexGuardMembersAreNaAndNeverPass(self) -> None:
        v = judge({"target": [5.0] * 3}, {"target": [5.0] * 3}, harness="codex")
        self.assertEqual(v["guards"]["permission_denials"], {"status": "n/a"})
        self.assertEqual(v["guards"]["stop_hook_blocks"], {"status": "n/a"})
        self.assertEqual(v["guards"]["tool_error_rate"]["status"], "pass")
        self.assertNotEqual(v["verdict"], "keep")

    def test_judge_codexIgnoresRegressedClaudeOnlyGuards(self) -> None:
        v = judge(
            {"target": [9.0] * 3, "permission_denials": [0.0] * 3},
            {"target": [5.0] * 3, "permission_denials": [50.0] * 3},
            harness="codex",
        )
        self.assertEqual(v["verdict"], "keep")

    def test_judge_codexToolErrorRegression_reverts(self) -> None:
        v = judge(
            {"target": [9.0] * 3, "tool_error_rate": [0.1] * 3},
            {"target": [5.0] * 3, "tool_error_rate": [0.9] * 3},
            harness="codex",
        )
        self.assertEqual((v["verdict"], v["reason"]), ("revert", "tool_error_rate"))


class CombineEdges(unittest.TestCase):
    def test_combine_oneInconclusiveOneRevert_reverts(self) -> None:
        self.assertEqual(hc_stats.combine(["inconclusive", "revert"]), "revert")

    def test_combine_keepAndRevert_reverts(self) -> None:
        self.assertEqual(hc_stats.combine(["keep", "revert"]), "revert")

    def test_combine_keepCheaperAndKeep_keepWins(self) -> None:
        self.assertEqual(hc_stats.combine(["keep-cheaper", "keep"]), "keep")

    def test_combine_keepCheaperAndInconclusive_keepCheaper(self) -> None:
        self.assertEqual(
            hc_stats.combine(["inconclusive", "keep-cheaper"]), "keep-cheaper"
        )

    def test_combine_empty_isInconclusive(self) -> None:
        self.assertEqual(hc_stats.combine([]), "inconclusive")

    def test_combine_unknownVerdictNeverWins(self) -> None:
        self.assertEqual(hc_stats.combine(["bogus", "inconclusive"]), "inconclusive")


class WindowEdges(unittest.TestCase):
    AFTER = T0 + 20 * DAY

    def sessions(self, harness: str, spec: list[tuple[float, str]]) -> list[dict]:
        out = []
        for i, (start, version) in enumerate(spec):
            out.append(
                {
                    "harness": harness,
                    "session": f"s{i}",
                    "start": start,
                    "version": version,
                    "target": 5.0 + (i % 2),
                    "tool_error_rate": 0.1,
                    "permission_denials": 0,
                    "stop_hook_blocks": 0,
                    "tokens_per_turn": 100.0,
                }
            )
        return out

    def test_evaluateHarness_changeInsideBeforeWindowIsClippedNotInconclusive(
        self,
    ) -> None:
        a = self.AFTER
        spec = [(a - 6 * DAY + i * 600, "1.0") for i in range(3)]
        spec += [(a - 3 * DAY + i * 600, "2.0") for i in range(3)]
        spec += [(a + i * 600, "2.0") for i in range(3)]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertEqual(out["sessions"], {"before": 3, "after": 3})
        self.assertNotEqual(out["reason"], "version-changed")

    def test_evaluateHarness_firstNewVersionSessionExactlyAtAfterStart_versionChanged(
        self,
    ) -> None:
        a = self.AFTER
        spec = [(a - DAY + i * 600, "1.0") for i in range(3)]
        spec += [(a + i * 600, "2.0") for i in range(3)]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertEqual(out["reason"], "version-changed")

    def test_evaluateHarness_changeInsideAfterWindow_isFilteredNotMixed(self) -> None:
        a = self.AFTER
        spec = [(a - DAY + i * 600, "1.0") for i in range(3)]
        spec += [(a + DAY + i * 600, "1.0") for i in range(2)]
        spec += [(a + 6 * DAY, "1.1")]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertNotEqual(out["reason"], "version-changed")
        self.assertEqual(out["sessions"], {"before": 3, "after": 2})
        self.assertEqual((out["version"], out["excluded"]), ("1.0", 1))

    def test_evaluateHarness_noVersionInBothWindows_versionChanged(self) -> None:
        a = self.AFTER
        spec = [(a - DAY + i * 600, "1.0") for i in range(3)]
        spec += [(a + DAY, "1.0")]
        spec += [(a + 2 * DAY + i * 600, "1.1") for i in range(2)]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertEqual(out["reason"], "version-changed")

    def test_evaluateHarness_sessionExactlyAtAfterEnd_isOutsideAfterWindow(
        self,
    ) -> None:
        a = self.AFTER
        spec = [(a - DAY + i * 600, "1.0") for i in range(3)]
        spec += [(a + i * 600, "1.0") for i in range(3)]
        spec += [(a + 7 * DAY, "9.9")]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertNotEqual(out["reason"], "version-changed")
        self.assertEqual(out["sessions"]["after"], 3)

    def test_evaluateHarness_otherHarnessVersionChangeDoesNotLeak(self) -> None:
        a = self.AFTER
        rows_ = self.sessions(
            "claude",
            [(a - DAY + i * 600, "1.0") for i in range(3)]
            + [(a + i * 600, "1.0") for i in range(3)],
        ) + self.sessions("codex", [(a - 100, "1"), (a + 100, "2")])
        out = hc_stats.evaluate_harness("claude", gate(), rows_, a)
        self.assertNotEqual(out["reason"], "version-changed")

    def test_evaluateHarness_exactlyMinSessions_isJudged(self) -> None:
        a = self.AFTER
        spec = [(a - DAY + i * 600, "1.0") for i in range(2)]
        spec += [(a + i * 600, "1.0") for i in range(2)]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertNotEqual(out["reason"], "min-sessions")

    def test_evaluateHarness_oneBelowMinSessions_reportsCounts(self) -> None:
        a = self.AFTER
        spec = [(a - DAY + i * 600, "1.0") for i in range(2)]
        spec += [(a, "1.0")]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertEqual(out["reason"], "min-sessions")
        self.assertEqual(out["sessions"], {"before": 2, "after": 1})

    def test_evaluateHarness_nullVersionRowsDoNotTriggerVersionChange(self) -> None:
        a = self.AFTER
        spec = [(a - DAY, "1.0"), (a - DAY + 600, None), (a, None), (a + 600, "1.0")]
        spec += [(a + 1200, "1.0"), (a - DAY + 1200, "1.0")]
        out = hc_stats.evaluate_harness(
            "claude", gate(), self.sessions("claude", spec), a
        )
        self.assertNotEqual(out["reason"], "version-changed")


class GateSettingsEdges(unittest.TestCase):
    def test_normalizeGate_nanSoakDays_rejected(self) -> None:
        with self.assertRaises(ValueError):
            hc_gate.normalize_gate(gate_json(soak_days=float("nan")))

    def test_normalizeGate_infiniteSoakDays_rejected(self) -> None:
        with self.assertRaises(ValueError):
            hc_gate.normalize_gate(gate_json(soak_days=float("inf")))

    def test_normalizeGate_nanTokenPerGain_rejected(self) -> None:
        with self.assertRaises(ValueError):
            hc_gate.normalize_gate(gate_json(token_per_gain=float("nan")))

    def test_normalizeGate_boolSoakDays_rejected(self) -> None:
        with self.assertRaises(ValueError):
            hc_gate.normalize_gate(gate_json(soak_days=True))


class FieldGateCase(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.base = self.commit({"README.md": "x\n"}, date=T0 - 30 * DAY)
        self.merge = self.commit(
            {"harness-climb/gates/t1-r1.json": json.dumps(gate_json()), "a.txt": "1\n"},
            "merge",
            date=T0,
        )
        self.later = self.commit({"b.txt": "2\n"}, "later", date=T0 + DAY)

    def fg(self, history: str, now: float = T0 + 30 * DAY, merge: str | None = None):
        return hc_field_gate.field_gate(
            self.repo, "t1", 1, merge or self.merge, history, [], now
        )

    def reasons(self, out: dict) -> set[str]:
        return {h["reason"] for h in out["harnesses"].values()}

    def test_syncHistory_earlierSyncWithoutMergeIsSkipped(self) -> None:
        hist = f"{T0 - 5 * DAY} {self.base}\n{T0 + 3600} {self.later}\n"
        out = self.fg(hist)
        self.assertEqual(out["sync"]["epoch"], T0 + 3600)
        self.assertEqual(self.reasons(out), {"min-sessions"})

    def test_syncHistory_firstContainingLineWinsOverLaterOnes(self) -> None:
        hist = f"{T0 + 100} {self.merge}\n{T0 + 200} {self.later}\n"
        self.assertEqual(self.fg(hist)["sync"]["epoch"], T0 + 100)

    def test_syncHistory_malformedLinesAreIgnored(self) -> None:
        junk = [
            "garbage",
            "",
            "   ",
            "12 abc",
            f"x {self.later}",
            f"-5 {self.later}",
            f"{T0} {self.later[:39]}",
            f"{T0} {self.later} extra",
            f"{T0}{self.later}",
            f"{T0} {self.later.upper()}",
            f"{T0 + 1.5} {self.later}",
        ]
        hist = "\n".join(junk) + f"\n{T0 + 7} {self.later}\n"
        self.assertEqual(self.fg(hist)["sync"]["epoch"], T0 + 7)

    def test_syncHistory_crlfAndPaddedLinesParse(self) -> None:
        hist = f"  {T0 + 9} {self.later}  \r\n"
        self.assertEqual(self.fg(hist)["sync"]["epoch"], T0 + 9)

    def test_syncHistory_onlyMalformed_isNoSync(self) -> None:
        out = self.fg("nonsense\n")
        self.assertEqual(self.reasons(out), {"sync-late"})
        self.assertEqual(out["candidate"], "inconclusive")

    def test_syncHistory_unknownShaIsSkippedNotFatal(self) -> None:
        hist = f"{T0 + 1} {'a' * 40}\n{T0 + 2} {self.later}\n"
        self.assertEqual(self.fg(hist)["sync"]["epoch"], T0 + 2)

    def test_syncGrace_exactlyAtBoundary_isNotLate(self) -> None:
        out = self.fg(f"{T0 + 2 * DAY} {self.later}\n")
        self.assertEqual(self.reasons(out), {"min-sessions"})

    def test_syncGrace_oneSecondPastBoundary_isSyncLate(self) -> None:
        out = self.fg(f"{T0 + 2 * DAY + 1} {self.later}\n")
        self.assertEqual(self.reasons(out), {"sync-late"})
        self.assertEqual(out["candidate"], "inconclusive")

    def test_syncGrace_syncOnlyAtLaterCommitStillLateAgainstMergeTime(self) -> None:
        out = self.fg(f"{T0 + 5 * DAY} {self.later}\n")
        self.assertEqual(self.reasons(out), {"sync-late"})

    def test_soakWindow_nowBeforeSoakEnd_isNotDue(self) -> None:
        hist = f"{T0 + 100} {self.later}\n"
        out = self.fg(hist, now=T0 + 100 + 7 * DAY - 1)
        self.assertEqual(out["status"], "not-due")
        self.assertEqual(self.fg(hist, now=T0 + 100 + 7 * DAY)["status"], "ok")

    def test_cliFieldGate_missingHistoryFile_isNoSyncNotCrash(self) -> None:
        rows_file = self.write_json("rows.json", [])
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
            str(self.dir / "absent.log"),
            "--rows",
            str(rows_file),
            "--now",
            str(T0 + 30 * DAY),
        )
        out = self.out(proc)
        self.assertEqual(out["candidate"], "inconclusive")
        self.assertEqual(out["harnesses"]["claude"]["reason"], "sync-late")

    def test_cliFieldGate_historyPathIsDirectory_failsCleanly(self) -> None:
        rows_file = self.write_json("rows.json", [])
        proc = run_cli(
            "field-gate",
            "--repo",
            str(self.repo),
            "--thread",
            "t1",
            "--round",
            "1",
            "--merge",
            self.merge,
            "--history",
            str(self.dir),
            "--rows",
            str(rows_file),
            "--now",
            str(T0 + 30 * DAY),
        )
        self.assertNotIn("Traceback", proc.stderr)

    def test_defaultHistoryPath_stateDirWithSpaces(self) -> None:
        p = hc_git.default_history_path({"DOTFILES_STATE_DIR": "/tmp/a b/c"})
        self.assertEqual(str(p), "/tmp/a b/c/sync-history.log")

    # --- AC-11 gate file read ---

    def test_gateRead_workingTreeEditIsIgnored(self) -> None:
        path = self.repo / "harness-climb/gates/t1-r1.json"
        path.write_text(json.dumps(gate_json(min_sessions=999)))
        out = self.fg(f"{T0 + 100} {self.later}\n")
        self.assertEqual(out["gate"]["min_sessions"], 4)

    def test_gateRead_laterCommitEditIsIgnored(self) -> None:
        self.commit(
            {"harness-climb/gates/t1-r1.json": json.dumps(gate_json(min_sessions=999))},
            "tamper",
            date=T0 + 2 * DAY,
        )
        out = self.fg(f"{T0 + 100} {self.later}\n")
        self.assertEqual(out["gate"]["min_sessions"], 4)

    def test_gateRead_absentFromMerge_errorsEvenIfLaterCommitHasIt(self) -> None:
        early = self.base
        self.commit({"harness-climb/gates/t2-r1.json": json.dumps(gate_json("t2"))})
        rc, out = call(
            "field-gate",
            "--repo",
            str(self.repo),
            "--state-dir",
            str(self.state),
            "--thread",
            "t2",
            "--round",
            "1",
            "--merge",
            self.merge,
            "--history",
            str(self.dir / "h.log"),
            "--rows",
            str(self.write_json("r.json", [])),
        )
        self.assertEqual(rc, 2)
        self.assertEqual(out["status"], "error")
        self.assertTrue(early)

    def test_gateRead_malformedJsonAtMerge_errorsCleanly(self) -> None:
        bad = self.commit({"harness-climb/gates/t3-r1.json": "{not json"}, "bad")
        rc, out = call(
            "field-gate",
            "--repo",
            str(self.repo),
            "--thread",
            "t3",
            "--round",
            "1",
            "--merge",
            bad,
            "--history",
            str(self.dir / "h.log"),
            "--rows",
            str(self.write_json("r.json", [])),
        )
        self.assertEqual((rc, out["status"]), (2, "error"))

    def test_gateRead_nonObjectJson_errorsCleanly(self) -> None:
        bad = self.commit({"harness-climb/gates/t3-r1.json": "[1,2]"}, "bad")
        rc, out = call(
            "field-gate",
            "--repo",
            str(self.repo),
            "--thread",
            "t3",
            "--round",
            "1",
            "--merge",
            bad,
            "--history",
            str(self.dir / "h.log"),
            "--rows",
            str(self.write_json("r.json", [])),
        )
        self.assertEqual((rc, out["status"]), (2, "error"))

    def test_gateRead_missingRequiredKeys_errorsCleanly(self) -> None:
        bad = self.commit({"harness-climb/gates/t3-r1.json": "{}"}, "bad")
        rc, out = call(
            "field-gate",
            "--repo",
            str(self.repo),
            "--thread",
            "t3",
            "--round",
            "1",
            "--merge",
            bad,
            "--history",
            str(self.dir / "h.log"),
            "--rows",
            str(self.write_json("r.json", [])),
        )
        self.assertEqual((rc, out["status"]), (2, "error"))

    def test_gateRead_unknownGuardVersion_isInconclusiveForBoth(self) -> None:
        c = self.commit(
            {
                "harness-climb/gates/t4-r1.json": json.dumps(
                    gate_json("t4", guard_composite_version=99)
                )
            },
            "gv",
            date=T0,
        )
        out = hc_field_gate.field_gate(
            self.repo, "t4", 1, c, f"{T0} {c}\n", [], T0 + 30 * DAY
        )
        self.assertEqual(self.reasons(out), {"guard-version-unknown"})

    def test_gateRead_mergeRefThatIsNotACommit_errorsCleanly(self) -> None:
        rc, out = call(
            "field-gate",
            "--repo",
            str(self.repo),
            "--thread",
            "t1",
            "--round",
            "1",
            "--merge",
            "no-such-rev",
            "--history",
            str(self.dir / "h.log"),
            "--rows",
            str(self.write_json("r.json", [])),
        )
        self.assertEqual((rc, out["status"]), (2, "error"))

    def test_endToEnd_revertCandidateRequestsRevertPrWithoutActing(self) -> None:
        hist = f"{T0 + 100} {self.later}\n"
        sync = T0 + 100
        bad = make_rows(
            "claude",
            sync,
            5,
            target=[9.0, 9.1, 9.2, 9.3, 9.4],
            tool_error_rate=0.1,
            permission_denials=0,
            stop_hook_blocks=0,
            tokens_per_turn=100.0,
        )
        good = make_rows(
            "claude",
            sync - 3 * DAY,
            5,
            target=[5.0, 5.1, 5.2, 5.3, 5.4],
            tool_error_rate=0.1,
            permission_denials=0,
            stop_hook_blocks=0,
            tokens_per_turn=100.0,
        )
        out = hc_field_gate.field_gate(
            self.repo, "t1", 1, self.merge, hist, bad + good, T0 + 30 * DAY
        )
        self.assertEqual(out["harnesses"]["claude"]["verdict"], "revert")
        self.assertEqual(out["candidate"], "revert")
        self.assertEqual(out["action"], "open-revert-pr")


if __name__ == "__main__":
    unittest.main()
