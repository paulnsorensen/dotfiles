from __future__ import annotations

import json
import unittest

from .support import DAY, T0, RepoCase, gate_json, hc_git, run_cli, soak_check

PIN = soak_check.PIN_FILE
GATE = "harness-climb/gates/t1-r1.json"


def mise(claude: str = "1.0.0", codex: str = "2.0.0", other: str = "3.0.0") -> str:
    return f'[tools]\n"aqua:anthropics/claude-code" = "{claude}"\n"aqua:openai/codex" = "{codex}"\n"aqua:other/tool" = "{other}"\n'


class SoakCase(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.commit(
            {PIN: mise(), "harness-climb/gates/.gitkeep": ""}, date=T0 - 10 * DAY
        )
        self.main = self.git("rev-parse", "HEAD")

    def merge_gate(self, when: int = T0, **gate: object) -> str:
        return self.commit({GATE: json.dumps(gate_json(**gate))}, "gate", date=when)

    def pr(self, files: dict[str, str]) -> tuple[str, str]:
        """Branch off main's tip, commit `files`, return (base, head)."""
        base = self.git("rev-parse", "main")
        self.git("checkout", "-q", "-b", "pr")
        head = self.commit(files, "pr", date=T0 + 5)
        self.git("checkout", "-q", "main")
        return base, head

    def check(
        self,
        base: str,
        head: str,
        labels: list[str] | None = None,
        now: float = T0 + DAY,
    ) -> dict:
        return soak_check.soak_check(self.repo, base, head, "main", labels or [], now)

    def cli(self, base: str, head: str, labels: str = "", now: float = T0 + DAY):
        return run_cli(
            "soak-check",
            "--repo",
            str(self.repo),
            "--base",
            base,
            "--head",
            head,
            "--main-ref",
            "main",
            "--labels",
            labels,
            "--now",
            str(now),
        )

    def test_open_window_pin_bump_fails_and_names_the_gate_file(self) -> None:
        self.merge_gate()
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        got = self.check(base, head)
        self.assertEqual((got["status"], got["reason"]), ("fail", "open-window"))
        self.assertEqual(got["open_gate_files"], [GATE])
        self.assertEqual(got["pins_changed"], ["aqua:anthropics/claude-code"])
        proc = self.cli(base, head)
        self.assertEqual(proc.returncode, 1)
        self.assertIn(GATE, self.out(proc)["open_gate_files"])

    def test_open_window_codex_pin_bump_fails_too(self) -> None:
        self.merge_gate()
        base, head = self.pr({PIN: mise(codex="2.1.0")})
        self.assertEqual(self.check(base, head)["status"], "fail")

    def test_open_window_lasts_the_grace_plus_the_soak(self) -> None:
        self.merge_gate(soak_days=7, sync_grace_days=2)
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        self.assertEqual(self.check(base, head, now=T0 + 9 * DAY - 1)["status"], "fail")
        self.assertEqual(self.check(base, head, now=T0 + 9 * DAY)["status"], "pass")

    def test_open_window_uses_the_gate_file_settings(self) -> None:
        self.merge_gate(soak_days=14, sync_grace_days=1)
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        self.assertEqual(self.check(base, head, now=T0 + 14 * DAY)["status"], "fail")
        self.assertEqual(self.check(base, head, now=T0 + 15 * DAY)["status"], "pass")

    def test_open_window_opens_at_a_merge_commit_to_main(self) -> None:
        self.git("checkout", "-q", "-b", "feature")
        self.commit({GATE: json.dumps(gate_json())}, "feature gate", date=T0 - 3 * DAY)
        self.git("checkout", "-q", "main")
        self.commit({"other.txt": "x"}, "main moves", date=T0 - 2 * DAY)
        self.git("merge", "--no-ff", "-q", "-m", "merge feature", "feature", date=T0)
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        got = self.check(base, head, now=T0 + DAY)
        self.assertEqual(got["open_gate_files"], [GATE])
        # The window opens at the merge, not at the feature commit three days earlier.
        self.assertEqual(self.check(base, head, now=T0 + 8 * DAY)["status"], "fail")

    def test_override_label_passes_and_reports_the_override(self) -> None:
        self.merge_gate()
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        got = self.check(base, head, ["dependencies", soak_check.OVERRIDE_LABEL])
        self.assertEqual((got["status"], got["reason"]), ("pass", "override"))
        self.assertEqual(got["override"], soak_check.OVERRIDE_LABEL)
        self.assertEqual(got["open_gate_files"], [GATE])
        proc = self.cli(base, head, labels=f"x,{soak_check.OVERRIDE_LABEL}")
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertEqual(self.out(proc)["reason"], "override")

    def test_override_label_must_match_exactly(self) -> None:
        self.merge_gate()
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        self.assertEqual(
            self.check(base, head, ["harness-climb/soak-override-not"])["status"],
            "fail",
        )

    def test_no_window_pin_bump_passes(self) -> None:
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        got = self.check(base, head)
        self.assertEqual((got["status"], got["reason"]), ("pass", "no-open-window"))
        self.assertEqual(self.cli(base, head).returncode, 0)

    def test_no_window_expired_window_passes_the_bump(self) -> None:
        self.merge_gate()
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        self.assertEqual(self.check(base, head, now=T0 + 30 * DAY)["status"], "pass")

    def test_no_window_without_a_pin_change_passes_during_an_open_window(self) -> None:
        self.merge_gate()
        base, head = self.pr({PIN: mise(other="3.1.0")})
        got = self.check(base, head)
        self.assertEqual((got["status"], got["reason"]), ("pass", "no-pin-change"))

    def test_no_window_unrelated_files_pass_during_an_open_window(self) -> None:
        self.merge_gate()
        base, head = self.pr({"README.md": "hi"})
        self.assertEqual(self.check(base, head)["status"], "pass")

    def test_no_window_push_events_pass_without_a_base(self) -> None:
        self.merge_gate()
        got = self.check("", "HEAD")
        self.assertEqual((got["status"], got["reason"]), ("pass", "no-pull-request"))

    def test_no_window_gitkeep_alone_opens_nothing(self) -> None:
        self.assertEqual(soak_check.open_windows(self.repo, "main", T0), [])

    def test_missing_main_ref_is_an_error_not_a_pass(self) -> None:
        base, head = self.pr({PIN: mise(claude="1.1.0")})
        proc = run_cli(
            "soak-check",
            "--repo",
            str(self.repo),
            "--base",
            base,
            "--head",
            head,
            "--main-ref",
            "nope/main",
            "--now",
            str(T0),
        )
        self.assertEqual(proc.returncode, 0)  # falls back to the local main branch
        self.git("branch", "-m", "main", "trunk")
        proc = run_cli(
            "soak-check",
            "--repo",
            str(self.repo),
            "--base",
            base,
            "--head",
            head,
            "--main-ref",
            "nope/main",
            "--now",
            str(T0),
        )
        self.assertEqual(proc.returncode, 2)

    def test_resolve_main_falls_back_to_local_main_without_origin(self) -> None:
        self.assertEqual(hc_git.resolve_main(self.repo, "origin/main"), "main")

    def test_resolve_main_prefers_origin_main_when_present(self) -> None:
        self.git("update-ref", "refs/remotes/origin/main", self.main)
        self.assertEqual(hc_git.resolve_main(self.repo, "origin/main"), "origin/main")


def commented_mise(claude: str = "1.0.0", codex: str = "2.0.0") -> str:
    return (
        "# pins for aqua:openai/codex and aqua:anthropics/claude-code\n"
        "[tools]\n"
        f'"aqua:anthropics/claude-code" = "{claude}"\n'
        f'"aqua:openai/codex" = "{codex}"\n'
        '"aqua:other/tool" = "3.0.0"\n'
    )


class SoakAttack(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.commit(
            {PIN: commented_mise(), "harness-climb/gates/.gitkeep": ""},
            date=T0 - 10 * DAY,
        )

    def gate(
        self, name: str, when: int = T0, raw: str | None = None, **over: object
    ) -> str:
        text = raw if raw is not None else json.dumps(gate_json(**over))
        return self.commit(
            {f"harness-climb/gates/{name}.json": text}, "gate", date=when
        )

    def pr(self, files: dict[str, str]) -> tuple[str, str]:
        base = self.git("rev-parse", "main")
        self.git("checkout", "-q", "-b", "pr")
        head = self.commit(files, "pr", date=T0 + 5)
        self.git("checkout", "-q", "main")
        return base, head

    def check(
        self,
        base: str,
        head: str,
        labels: list[str] | None = None,
        now: float = T0 + DAY,
    ):
        return soak_check.soak_check(self.repo, base, head, "main", labels or [], now)

    # --- what counts as a pin change ---

    def test_pinChange_lineReorderOnly_isNotAPinChange(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr(
            {
                PIN: '# pins for aqua:openai/codex and aqua:anthropics/claude-code\n[tools]\n"aqua:openai/codex" = "2.0.0"\n"aqua:anthropics/claude-code" = "1.0.0"\n"aqua:other/tool" = "3.0.0"\n'
            }
        )
        self.assertEqual(
            self.check(base, head)["status"], "pass", "versions are unchanged"
        )

    def test_pinChange_commentOnlyEdit_isNotAPinChange(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr(
            {PIN: commented_mise().replace("# pins for", "# the pins for")}
        )
        self.assertEqual(self.check(base, head)["status"], "pass")

    def test_pinChange_whitespaceOnlyEdit_isNotAPinChange(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr(
            {
                PIN: commented_mise().replace(
                    '"aqua:openai/codex" = ', '"aqua:openai/codex"   =   '
                )
            }
        )
        self.assertEqual(self.check(base, head)["status"], "pass")

    def test_pinChange_unrelatedToolBump_passesDuringWindow(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise().replace("3.0.0", "3.1.0")})
        self.assertEqual(self.check(base, head)["status"], "pass")

    def test_pinChange_bothPinsInOnePr_nameBothAndFail(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise("1.0.1", "2.0.1")})
        out = self.check(base, head)
        self.assertEqual(out["status"], "fail")
        self.assertEqual(out["pins_changed"], sorted(soak_check.PINNED_TOOLS))
        self.assertEqual(out["open_gate_files"], ["harness-climb/gates/t1-r1.json"])

    def test_pinChange_pinFileDeletedInPr_isStillHeld(self) -> None:
        self.gate("t1-r1")
        base = self.git("rev-parse", "main")
        self.git("checkout", "-q", "-b", "pr")
        self.git("rm", "-q", PIN)
        self.git("commit", "-q", "-m", "rm")
        head = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "main")
        self.assertEqual(self.check(base, head)["status"], "fail")

    def test_pinChange_toolWithSharedPrefixIsNotAPin(self) -> None:
        self.gate("t1-r1")
        text = commented_mise() + '"aqua:openai/codex-extra" = "1.0.0"\n'
        base, head = self.pr({PIN: text})
        self.assertEqual(self.check(base, head)["status"], "pass")

    # --- window edges ---

    def test_window_exactOpenSecond_isOpen(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        self.assertEqual(self.check(base, head, now=T0)["status"], "fail")
        self.assertEqual(self.check(base, head, now=T0 - 1)["status"], "pass")

    def test_window_exactCloseSecond_isClosed(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        close = T0 + 9 * DAY
        self.assertEqual(self.check(base, head, now=close - 1)["status"], "fail")
        self.assertEqual(self.check(base, head, now=close)["status"], "pass")

    def test_window_usesGateFileGraceAndSoakNotDefaults(self) -> None:
        self.gate("t1-r1", soak_days=1, sync_grace_days=0.5)
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        self.assertEqual(
            self.check(base, head, now=T0 + 1.5 * DAY - 1)["status"], "fail"
        )
        self.assertEqual(self.check(base, head, now=T0 + 1.5 * DAY)["status"], "pass")

    def test_window_multipleGateFilesOnlyOpenOnesNamed(self) -> None:
        self.gate("old-r1", when=T0 - 30 * DAY)
        self.gate("new-r1", when=T0)
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        out = self.check(base, head)
        self.assertEqual(out["open_gate_files"], ["harness-climb/gates/new-r1.json"])

    def test_window_allGateFilesClosed_passes(self) -> None:
        self.gate("old-r1", when=T0 - 30 * DAY)
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        out = self.check(base, head)
        self.assertEqual((out["status"], out["reason"]), ("pass", "no-open-window"))

    def test_window_gateAddedViaNoFfMergeCommit_opensWindow(self) -> None:
        self.git("checkout", "-q", "-b", "feature")
        self.commit(
            {"harness-climb/gates/t9-r1.json": json.dumps(gate_json("t9"))},
            "gate",
            date=T0 - 3600,
        )
        self.git("checkout", "-q", "main")
        self.commit({"x.txt": "x\n"}, "main moves", date=T0 - 1800)
        self.git("merge", "-q", "--no-ff", "-m", "merge", "feature", date=T0)
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        out = self.check(base, head)
        self.assertEqual(out["status"], "fail", out)
        self.assertEqual(out["windows"][0]["opened"], T0)

    def test_window_gateReaddedAfterDeletion_newestAddWins(self) -> None:
        self.gate("t1-r1", when=T0 - 30 * DAY)
        self.git("rm", "-q", "harness-climb/gates/t1-r1.json")
        self.git("commit", "-q", "-m", "rm")
        self.gate("t1-r1", when=T0)
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        self.assertEqual(self.check(base, head)["status"], "fail")

    def test_window_malformedGateFile_fallsBackToDefaultsAndStillHolds(self) -> None:
        self.gate("t1-r1", raw="{broken")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        self.assertEqual(self.check(base, head)["status"], "fail")

    def test_window_gateWithStringSoakDays_doesNotCrash(self) -> None:
        self.gate("t1-r1", soak_days="7")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        proc = run_cli(
            "soak-check",
            "--repo",
            str(self.repo),
            "--base",
            base,
            "--head",
            head,
            "--main-ref",
            "main",
            "--now",
            str(T0 + DAY),
        )
        self.assertNotIn("Traceback", proc.stderr)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(json.loads(proc.stdout)["reason"], "open-window")

    def test_window_gateWithInfiniteSoak_doesNotHoldBumpsForever(self) -> None:
        self.gate(
            "t1-r1",
            raw=json.dumps(gate_json()).replace(
                '"soak_days": 7', '"soak_days": Infinity'
            ),
        )
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        out = self.check(base, head, now=T0 + 3650 * DAY)
        self.assertEqual(out["status"], "pass")

    def test_window_nonJsonFileInGateDirIgnored(self) -> None:
        self.commit({"harness-climb/gates/NOTES.md": "x\n"}, "notes", date=T0)
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        self.assertEqual(self.check(base, head)["status"], "pass")

    # --- labels ---

    def test_labels_spacesAndCommasAreTrimmed(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        proc = run_cli(
            "soak-check",
            "--repo",
            str(self.repo),
            "--base",
            base,
            "--head",
            head,
            "--main-ref",
            "main",
            "--now",
            str(T0 + DAY),
            "--labels",
            " bug ,, harness-climb/soak-override , other label ",
        )
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertEqual(json.loads(proc.stdout)["reason"], "override")

    def test_labels_superstringOfOverrideDoesNotOverride(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        out = self.check(
            base,
            head,
            labels=["harness-climb/soak-override-not", "x harness-climb/soak-override"],
        )
        self.assertEqual(out["status"], "fail")

    def test_labels_overrideStillNamesOpenGateFiles(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        out = self.check(base, head, labels=[soak_check.OVERRIDE_LABEL])
        self.assertEqual(out["open_gate_files"], ["harness-climb/gates/t1-r1.json"])

    def test_cli_failExitCodeIsOne_andNoPrIsZero(self) -> None:
        self.gate("t1-r1")
        base, head = self.pr({PIN: commented_mise("1.0.1")})
        args = (
            "soak-check",
            "--repo",
            str(self.repo),
            "--main-ref",
            "main",
            "--now",
            str(T0 + DAY),
        )
        self.assertEqual(run_cli(*args, "--base", base, "--head", head).returncode, 1)
        self.assertEqual(run_cli(*args).returncode, 0)

    def test_cli_unknownBase_exitsCleanlyWithJsonError(self) -> None:
        proc = run_cli(
            "soak-check",
            "--repo",
            str(self.repo),
            "--base",
            "deadbeef",
            "--head",
            "HEAD",
            "--main-ref",
            "main",
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("Traceback", proc.stderr)


if __name__ == "__main__":
    unittest.main()
