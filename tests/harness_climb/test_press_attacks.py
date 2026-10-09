"""Press-phase adversarial tests for harness-climb. Each class maps to an attack group."""

from __future__ import annotations

import json
import os
import unittest

from .support import (
    DAY,
    T0,
    RepoCase,
    call,
    gate_json,
    hc_field_gate,
    hc_gate,
    hc_git,
    hc_policy,
    hc_stats,
    make_rows,
    run_cli,
)


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


# --- 1. field gate statistics (AC-13/14/23/24) -----------------------------


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

    def test_selectWindows_versionChangeAtBeforeStart_keepsFullSoak(self) -> None:
        w = hc_stats.select_windows(self.AFTER, 7, self.AFTER - 7 * DAY)
        self.assertEqual(w["before"], (self.AFTER - 7 * DAY, self.AFTER))

    def test_selectWindows_versionChangeBeforeSoakStart_isIgnored(self) -> None:
        w = hc_stats.select_windows(self.AFTER, 7, self.AFTER - 30 * DAY)
        self.assertEqual(w["before"][0], self.AFTER - 7 * DAY)

    def test_selectWindows_versionChangeInsideSoak_clipsBefore(self) -> None:
        w = hc_stats.select_windows(self.AFTER, 7, self.AFTER - 3 * DAY)
        self.assertEqual(w["before"], (self.AFTER - 3 * DAY, self.AFTER))

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

    def test_evaluateHarness_changeInsideAfterWindow_versionChanged(self) -> None:
        a = self.AFTER
        spec = [(a - DAY + i * 600, "1.0") for i in range(3)]
        spec += [(a + DAY + i * 600, "1.0") for i in range(2)]
        spec += [(a + 6 * DAY, "1.1")]
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


# --- 2/3. sync history window and gate file read (AC-22, AC-11) ------------


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


# --- 4. critic -------------------------------------------------------------

REGISTRY = """sources:
  paulnsorensen/easy-cheese:
    description: toolkit
"""


class PolicyEdges(unittest.TestCase):
    VENDORED = frozenset({"easy-cheese"})

    def cats(self, *paths: str) -> list[str]:
        return [v["category"] for v in hc_policy.check_scope(paths, self.VENDORED)]

    def test_scope_dotDotTraversalIntoVendored_rejected(self) -> None:
        self.assertEqual(self.cats("skills/../skills/easy-cheese/x.md"), ["vendored"])

    def test_scope_dotSegmentIntoVendored_rejected(self) -> None:
        self.assertEqual(self.cats("skills/./easy-cheese/x.md"), ["vendored"])

    def test_scope_doubleSlashIntoVendored_rejected(self) -> None:
        self.assertEqual(self.cats("skills//easy-cheese/x.md"), ["vendored"])

    def test_scope_traversalOutOfRepo_rejected(self) -> None:
        self.assertEqual(
            self.cats("../outside.md", "skills/../../x"), ["runtime-output"] * 2
        )

    def test_scope_tildeAndAbsoluteRuntimePaths_rejected(self) -> None:
        got = self.cats("~/.claude/settings.json", "/Users/x/.codex/config.toml", "~")
        self.assertEqual(got, ["runtime-output"] * 3)

    def test_scope_dotSlashRuntimePrefix_rejected(self) -> None:
        self.assertEqual(self.cats("./.claude/settings.json"), ["runtime-output"])

    def test_scope_backslashPath_rejected(self) -> None:
        self.assertEqual(self.cats("skills\\easy-cheese\\x.md"), ["runtime-output"])

    def test_scope_traversalThatLandsOnBudgetConfig_flaggedAsBudget(self) -> None:
        self.assertEqual(
            self.cats("skills/../agents/instruction-budgets.toml"), ["budget-config"]
        )

    def test_scope_emptyPath_notAllowed(self) -> None:
        self.assertEqual(self.cats(""), ["outside-allowlist"])

    def test_scope_vendoredNameCaseVariant_rejected(self) -> None:
        # macOS and default git checkouts fold case; Easy-Cheese resolves to easy-cheese.
        self.assertEqual(self.cats("skills/Easy-Cheese/x.md"), ["vendored"])

    def test_scope_underscorePrefixedSkillDir_notOwned(self) -> None:
        self.assertEqual(self.cats("skills/_registry.yaml"), ["outside-allowlist"])

    def test_tags_listOfTwoTags_multiple(self) -> None:
        got = hc_policy.check_tags(
            ["AGENTS.md"], {"AGENTS.md": ["global-doc", "skill"]}
        )
        self.assertEqual(got[0]["category"], "tag-multiple")

    def test_tags_nonStringTag_isUnknownNotCrash(self) -> None:
        got = hc_policy.check_tags(["AGENTS.md"], {"AGENTS.md": {"a": 1}})
        self.assertEqual(got[0]["category"], "tag-unknown")

    def test_tags_emptyList_isMissing(self) -> None:
        got = hc_policy.check_tags(["AGENTS.md"], {"AGENTS.md": []})
        self.assertEqual(got[0]["category"], "tag-missing")


class LeakageEdges(unittest.TestCase):
    PROMPT = (
        "please rotate the quarterly credentials for the acme billing cluster tonight"
    )

    def deny(self, **kw: list[str]) -> dict:
        return hc_policy.build_denylist(
            kw.get("prompts", []), kw.get("projects", []), kw.get("own", [])
        )

    def test_leakage_spanSplitAcrossTwoAddedLines_flagged(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        added = {
            "skills/m/SKILL.md": [
                (1, "rotate the quarterly credentials"),
                (2, "for the acme billing cluster"),
            ]
        }
        v = hc_policy.check_leakage(added, deny)
        self.assertEqual([x["category"] for x in v], ["prompt"])

    def test_leakage_spanSplitAcrossNonAdjacentHunks_isFalsePositive(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        added = {
            "f": [
                (3, "rotate the quarterly credentials"),
                (90, "for the acme billing cluster"),
            ]
        }
        self.assertEqual(hc_policy.check_leakage(added, deny), [])

    def test_leakage_caseAndPunctuationVariantsOfPrompt_flagged(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        text = "ROTATE, the Quarterly-Credentials; for the ACME billing (cluster)!"
        v = hc_policy.check_leakage({"f": [(1, text)]}, deny)
        self.assertTrue(v)

    def test_leakage_projectCaseVariant_flagged(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/ZebraCorp"])
        for text in ("ZEBRACORP", "zebracorp", "ZebraCorp"):
            v = hc_policy.check_leakage({"f": [(1, f"see {text} docs")]}, deny)
            self.assertEqual([x["category"] for x in v], ["project"], text)

    def test_leakage_repoPathCaseVariant_flagged(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/ZebraCorp"])
        v = hc_policy.check_leakage({"f": [(1, "cd /USERS/P/DEV/ZEBRACORP/src")]}, deny)
        self.assertIn("path", [x["category"] for x in v])

    def test_leakage_ownRepoNameIsNotADenylistTerm(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/dotfiles"], own=["dotfiles"])
        self.assertEqual(
            hc_policy.check_leakage({"f": [(1, "dotfiles repo")]}, deny), []
        )

    def test_leakage_shortProjectNameBelowMinimumIgnored(self) -> None:
        deny = self.deny(projects=["/a/b/abc"])
        self.assertEqual(deny["project"], set())

    def test_leakage_homeTildeFormOfRepoPath_flagged(self) -> None:
        deny = self.deny(projects=["/Users/p/Dev/zebra-app"])
        v = hc_policy.check_leakage({"f": [(1, "~/Dev/zebra-app/src")]}, deny)
        self.assertTrue(v)  # caught by the project basename

    def test_leakage_nonAsciiPromptSpan_flagged(self) -> None:
        prompt = "пожалуйста перезапусти боевой кластер клиента акме сегодня ночью пожалуйста"
        deny = self.deny(prompts=[prompt])
        v = hc_policy.check_leakage({"f": [(1, prompt)]}, deny)
        self.assertTrue(v, "a verbatim non-ASCII prompt must be flagged")

    def test_leakage_accentedWordsDoNotCreateFalseSpans(self) -> None:
        prompt = "café au lait for the quarterly acme billing cluster tonight please"
        deny = self.deny(prompts=[prompt])
        v = hc_policy.check_leakage(
            {"f": [(1, "café au lait for the quarterly acme billing cluster")]}, deny
        )
        self.assertTrue(v)

    def test_leakage_sevenWordSpanBelowNgramIsAllowed(self) -> None:
        deny = self.deny(prompts=[self.PROMPT])
        v = hc_policy.check_leakage(
            {"f": [(1, "rotate the quarterly credentials for the acme")]}, deny
        )
        self.assertEqual(v, [])

    def test_leakage_emptyAndNoneInputs_noCrash(self) -> None:
        deny = self.deny(prompts=["", None], projects=["", None])  # type: ignore[list-item]
        self.assertEqual(hc_policy.check_leakage({"f": [(1, "")]}, deny), [])
        self.assertEqual(hc_policy.check_leakage({}, deny), [])

    def test_parseAddedLines_noNewlineMarkerAndBinaryDoNotCrash(self) -> None:
        diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1,2 @@\n+a\n+b\n\\ No newline at end of file\n"
        self.assertEqual(hc_policy.parse_added_lines(diff), {"x": [(1, "a"), (2, "b")]})

    def test_leakage_addedLineWhoseTextStartsWithPlusPlus_stillScanned(self) -> None:
        deny = hc_policy.build_denylist([LeakageEdges.PROMPT], [], [])
        diff = "--- a/x\n+++ b/x\n@@ -0,0 +1,1 @@\n+++ " + LeakageEdges.PROMPT + "\n"
        added = hc_policy.parse_added_lines(diff)
        self.assertTrue(hc_policy.check_leakage(added, deny))

    def test_parseAddedLines_addedLineStartingWithPlusPlusPlus_isKept(self) -> None:
        diff = "--- a/x\n+++ b/x\n@@ -0,0 +1,1 @@\n++++ secret text\n"
        self.assertEqual(
            hc_policy.parse_added_lines(diff), {"x": [(1, "+++ secret text")]}
        )


class CriticGit(RepoCase):
    PROMPT = (
        "please rotate the quarterly credentials for the acme billing cluster tonight"
    )

    def setUp(self) -> None:
        super().setUp()
        self.commit(
            {
                "AGENTS.md": "base\n",
                "skills/_registry.yaml": REGISTRY,
                "skills/mine/SKILL.md": "keep\n",
                "skills/easy-cheese/SKILL.md": "vendored\n",
                "agents/instruction-budgets.toml": "version = 1\n",
            }
        )
        self.git("checkout", "-q", "-b", "harness-climb/t1/r1")

    def critic(self, tags: dict, deny: dict | None = None, budget: str = "true"):
        return call(
            "critic",
            "--repo",
            str(self.repo),
            "--state-dir",
            str(self.state),
            "--thread",
            "t1",
            "--round",
            "1",
            "--tags",
            str(self.write_json("tags.json", tags)),
            "--denylist",
            str(self.write_json("deny.json", deny or {})),
            "--budget-cmd",
            budget,
        )

    def cats(self, out: dict) -> set[str]:
        return {v["category"] for v in out["violations"]}

    def test_critic_renameOfBudgetConfig_rejected(self) -> None:
        self.git("mv", "agents/instruction-budgets.toml", "skills/mine/budgets.toml")
        self.git("commit", "-q", "-m", "rename")
        rc, out = self.critic({"skills/mine/budgets.toml": "skill"})
        self.assertEqual(rc, 1)
        self.assertIn("budget-config", self.cats(out))

    def test_critic_renameOutOfVendoredSkill_rejected(self) -> None:
        self.git("mv", "skills/easy-cheese/SKILL.md", "skills/mine/stolen.md")
        self.git("commit", "-q", "-m", "rename")
        rc, out = self.critic({"skills/mine/stolen.md": "skill"})
        self.assertEqual(rc, 1)
        self.assertIn("vendored", self.cats(out))

    def test_critic_renameIntoVendoredSkill_rejected(self) -> None:
        self.git("mv", "skills/mine/SKILL.md", "skills/easy-cheese/in.md")
        self.git("commit", "-q", "-m", "rename")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill", "skills/easy-cheese/in.md": "skill"}
        )
        self.assertEqual(rc, 1)
        self.assertIn("vendored", self.cats(out))

    def test_critic_tagOnDeletedFile_passes(self) -> None:
        self.git("rm", "-q", "skills/mine/SKILL.md")
        self.git("commit", "-q", "-m", "delete")
        rc, out = self.critic({"skills/mine/SKILL.md": "skill"})
        self.assertEqual((rc, out["status"]), (0, "pass"))

    def test_critic_deletedFileWithoutTag_tagMissing(self) -> None:
        self.git("rm", "-q", "skills/mine/SKILL.md")
        self.git("commit", "-q", "-m", "delete")
        _rc, out = self.critic({})
        self.assertIn("tag-missing", self.cats(out))

    def test_critic_deleteVendoredFile_rejected(self) -> None:
        self.git("rm", "-q", "skills/easy-cheese/SKILL.md")
        self.git("commit", "-q", "-m", "delete")
        _rc, out = self.critic({"skills/easy-cheese/SKILL.md": "skill"})
        self.assertIn("vendored", self.cats(out))

    def test_critic_rejectionOutputHoldsNoPromptText(self) -> None:
        self.commit({"skills/mine/SKILL.md": self.PROMPT + "\n"}, "leak")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, {"prompts": [self.PROMPT]}
        )
        self.assertEqual(rc, 1)
        self.assertIn("prompt", self.cats(out))
        blob = (
            json.dumps(out).lower()
            + (self.state / "t1/rounds/r1/critic.json").read_text().lower()
        )
        for word in ("rotate", "quarterly", "credentials", "acme", "billing"):
            self.assertNotIn(word, blob)

    def test_critic_projectLeakReasonHoldsNoProjectName(self) -> None:
        self.commit({"skills/mine/SKILL.md": "deploy to zebracorp\n"}, "leak")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, {"projects": ["/Users/p/Dev/zebracorp"]}
        )
        self.assertNotIn("zebracorp", json.dumps(out).lower())
        self.assertEqual(rc, 1)

    def test_critic_missingBudgetExecutable_doesNotPass(self) -> None:
        self.commit({"skills/mine/SKILL.md": "better\n"}, "edit")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, budget="/nonexistent/budget-cmd"
        )
        self.assertNotEqual(rc, 0)
        self.assertNotEqual(out.get("status"), "pass")

    def test_critic_symlinkInOwnedDirPointingAtRuntimeOutput_rejected(self) -> None:
        os.symlink(
            "/Users/someone/.claude/settings.json", self.repo / "skills/mine/link.md"
        )
        self.git("add", "skills/mine/link.md")
        self.git("commit", "-q", "-m", "symlink")
        rc, _out = self.critic({"skills/mine/link.md": "skill"})
        self.assertEqual(rc, 1, "a symlink to runtime output escapes the scope check")

    def test_critic_symlinkInOwnedDirPointingAtVendoredSkill_rejected(self) -> None:
        os.symlink("../easy-cheese", self.repo / "skills/mine/vend")
        self.git("add", "skills/mine/vend")
        self.git("commit", "-q", "-m", "symlink")
        rc, _out = self.critic({"skills/mine/vend": "skill"})
        self.assertEqual(
            rc, 1, "a symlink into a vendored skill escapes the scope check"
        )

    def test_critic_nonAsciiFilenameInOwnedSkill_passes(self) -> None:
        self.commit({"skills/mine/café.md": "ok\n"}, "unicode name")
        rc, out = self.critic({"skills/mine/café.md": "skill"})
        self.assertEqual((rc, out["status"]), (0, "pass"), out)

    def test_critic_filenameWithSpace_passes(self) -> None:
        self.commit({"skills/mine/a b.md": "ok\n"}, "space name")
        rc, out = self.critic({"skills/mine/a b.md": "skill"})
        self.assertEqual((rc, out["status"]), (0, "pass"), out)

    def test_critic_leakInFileWithSpaceInName_stillFlagged(self) -> None:
        self.commit({"skills/mine/a b.md": self.PROMPT + "\n"}, "leak")
        _rc, out = self.critic(
            {"skills/mine/a b.md": "skill"}, {"prompts": [self.PROMPT]}
        )
        self.assertIn("prompt", self.cats(out))

    def test_critic_leakPrefixedWithPlusPlus_stillRejected(self) -> None:
        self.commit({"skills/mine/SKILL.md": "++ " + self.PROMPT + "\n"}, "leak")
        rc, out = self.critic(
            {"skills/mine/SKILL.md": "skill"}, {"prompts": [self.PROMPT]}
        )
        self.assertEqual(rc, 1)
        self.assertIn("prompt", self.cats(out))

    def test_critic_removedLeakingLineIsNotFlagged(self) -> None:
        deny = {"prompts": [LeakageEdges.PROMPT]}
        self.commit({"skills/mine/SKILL.md": LeakageEdges.PROMPT + "\n"}, "pre")
        self.git("checkout", "-q", "-B", "harness-climb/t1/r1")
        self.git("update-ref", "refs/heads/main", "HEAD")
        self.commit({"skills/mine/SKILL.md": "clean text now\n"}, "clean")
        rc, out = self.critic({"skills/mine/SKILL.md": "skill"}, deny)
        self.assertEqual((rc, out["status"]), (0, "pass"))


if __name__ == "__main__":
    unittest.main()
