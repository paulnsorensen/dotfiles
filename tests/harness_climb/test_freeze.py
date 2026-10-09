"""Freeze: lab rule, gate file, and the one-in-flight rule."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any
from unittest import TestCase, main, mock, skipUnless

from .support import (
    HAVE_DUCKDB,
    RepoCase,
    call,
    cli,
    gate_json,
    hc_db,
    hc_gate,
    hc_ledger,
    make_db,
)

hc_freeze = cli.hc_freeze

QUERY = "SELECT harness, sessionId, 1.0 AS value FROM sessions"
needs_duckdb = skipUnless(HAVE_DUCKDB, "duckdb CLI not installed")


class FreezeCase(RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.commit({"README.md": "base\n"}, "base")
        self.git("checkout", "-q", "-b", "harness-climb/t1/r1")
        self.commit({"skills/foo/SKILL.md": "edit\n"}, "edit")
        if HAVE_DUCKDB:
            db = make_db(
                self.dir / "sessions.duckdb",
                "CREATE TABLE sessions (harness VARCHAR, sessionId VARCHAR, project VARCHAR)",
            )
            patch = mock.patch.dict(os.environ, {"SESSIONS_DB": str(db)})
            patch.start()
            self.addCleanup(patch.stop)
        clean = ({"prompt": set(), "path": set(), "project": set()}, [])
        denylist = mock.patch("hc_freeze.load_denylist", return_value=clean)
        denylist.start()
        self.addCleanup(denylist.stop)

    def contract(self, skill: str = "foo") -> None:
        """Put the skill's contract on `main`, the freeze base, and rebase the branch."""
        self.git("checkout", "-q", "main")
        self.commit({f"skills/{skill}/evals/autoimprove.json": "{}\n"}, "contract")
        self.git("checkout", "-q", "harness-climb/t1/r1")
        self.git("rebase", "-q", "main")

    def ledger_lines(self) -> list[dict[str, str]]:
        path = self.state / "t1" / "ledger.md"
        lines = path.read_text().splitlines() if path.is_file() else []
        return [hc_ledger.parse_ledger_line(line) for line in lines]

    def critic(self, **over: Any) -> None:
        state = {
            "failures": 0,
            "passed": True,
            "head": self.git("rev-parse", "HEAD"),
            "components": ["skill"],
        }
        state.update(over)
        path = self.state / "t1" / "rounds" / "r1" / "critic.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(state))

    def freeze(
        self,
        *extra: str,
        component: str = "skill",
        rnd: str = "1",
        query: str = QUERY,
    ) -> tuple[int, dict[str, Any]]:
        return call(
            "freeze", "--repo", str(self.repo), "--state-dir", str(self.state), "--thread", "t1",
            "--round", rnd, "--component", component, "--base", "main",
            "--targeted-query", query, *extra,
        )  # fmt: skip


class LabTests(FreezeCase):
    @needs_duckdb
    def test_lab_promote_accepted_for_contracted_skill(self) -> None:
        self.contract()
        self.critic()
        rc, out = self.freeze("--autoimprove-verdict", "promote")
        self.assertEqual((rc, out["status"]), (0, "frozen"))
        self.assertEqual(out["lab"], {"verdict": "promote"})

    def test_lab_other_verdicts_refused_for_contracted_skill(self) -> None:
        self.contract()
        self.critic()
        for verdict in ("hold", "reject", None):
            extra = ["--autoimprove-verdict", verdict] if verdict else []
            rc, out = self.freeze(*extra)
            self.assertEqual((rc, out["status"]), (1, "refused"), verdict)
            self.assertIn("autoimprove verdict", out["reason"], verdict)
        self.assertFalse((self.repo / "harness-climb").exists())

    @needs_duckdb
    def test_lab_held_no_contract_for_skill(self) -> None:
        self.critic()
        rc, out = self.freeze()
        self.assertEqual(rc, 0)
        self.assertEqual(out["lab"], {"verdict": "held", "reason": "no-contract"})

    @needs_duckdb
    def test_lab_held_isolation_preflight_for_other_components(self) -> None:
        for component in ("hook", "agent-def", "preamble", "global-doc"):
            with self.subTest(component=component):
                self.critic(components=[component])
                rc, out = self.freeze(
                    "--autoimprove-verdict", "promote", component=component
                )
                self.assertEqual(rc, 0, out)
                self.assertEqual(
                    out["lab"], {"verdict": "held", "reason": "isolation-preflight"}
                )
                self.git("reset", "-q", "--hard", "HEAD~1")

    def test_lab_freeze_refused_without_passing_critic(self) -> None:
        rc, out = self.freeze()
        self.assertEqual((rc, out["status"]), (1, "refused"))
        self.assertIn("no passing critic verdict", out["reason"])
        self.critic(passed=False)
        rc, out = self.freeze()
        self.assertEqual(rc, 1)
        self.assertIn("no passing critic verdict", out["reason"])
        self.critic(head="0" * 40)
        rc, out = self.freeze()
        self.assertEqual(rc, 1)
        self.assertIn("no passing critic verdict", out["reason"])

    def test_lab_freeze_refused_when_critic_component_differs(self) -> None:
        self.critic(components=["hook"])
        rc, out = self.freeze()
        self.assertEqual(rc, 1)
        self.assertIn("do not match", out["reason"])


class GateFileTests(FreezeCase):
    @needs_duckdb
    def test_gate_file_written_and_committed_with_frozen_settings(self) -> None:
        self.critic()
        before = self.git("rev-parse", "HEAD")
        rc, out = self.freeze(
            "--direction",
            "higher",
            "--min-sessions",
            "6",
            "--soak-days",
            "5",
            "--token-per-gain",
            "2",
        )
        self.assertEqual(rc, 0, out)
        rel = "harness-climb/gates/t1-r1.json"
        self.assertEqual(out["gate_file"], rel)
        gate = json.loads((self.repo / rel).read_text())
        self.assertEqual(gate, out["gate"])
        expected = {
            "thread": "t1",
            "round": 1,
            "component": "skill",
            "targeted_query": QUERY,
            "direction": "higher",
        }
        for key, value in expected.items():
            self.assertEqual(gate[key], value)
        self.assertEqual(
            (gate["min_sessions"], gate["soak_days"], gate["token_per_gain"]), (6, 5, 2)
        )
        self.assertEqual(self.git("rev-parse", "HEAD~1"), before)
        self.assertEqual(self.git("show", "--name-only", "--format=", "HEAD"), rel)
        self.assertEqual(self.git("status", "--porcelain", "--", rel), "")
        self.assertEqual(
            hc_gate.read_gate_at(self.repo, "HEAD", rel)["direction"], "higher"
        )

    def test_gate_file_needs_a_query(self) -> None:
        self.critic()
        rc, out = self.freeze(query="  ")
        self.assertEqual(rc, 2)
        self.assertEqual(out["status"], "error")
        self.assertFalse((self.repo / "harness-climb").exists())


class InFlightTests(FreezeCase):
    def merged_gate(self, name: str, component: str = "skill") -> None:
        self.git("checkout", "-q", "main")
        self.commit(
            {
                f"harness-climb/gates/{name}.json": json.dumps(
                    gate_json(component=component)
                )
                + "\n"
            },
            f"gate {name}",
        )
        self.git("checkout", "-q", "harness-climb/t1/r1")
        self.git("rebase", "-q", "main")
        self.critic()

    def test_in_flight_refuses_same_component_without_verdict(self) -> None:
        self.merged_gate("old-r1")
        rc, out = self.freeze()
        self.assertEqual((rc, out["status"]), (1, "refused"))
        self.assertIn("harness-climb/gates/old-r1.json", out["reason"])
        self.assertFalse((self.repo / "harness-climb/gates/t1-r1.json").exists())

    @needs_duckdb
    def test_in_flight_allows_other_component(self) -> None:
        self.merged_gate("old-r1", component="hook")
        self.assertEqual(self.freeze()[0], 0)

    @needs_duckdb
    def test_in_flight_skips_measured_gate(self) -> None:
        self.merged_gate("old-r1")
        ledger = self.state / "old" / "ledger.md"
        ledger.parent.mkdir(parents=True)
        ledger.write_text(
            "round=1 | change=x | pr=1 | lab=held | claude=keep | codex=keep | candidate=keep | merge=abc\n"
        )
        self.assertEqual(self.freeze()[0], 0)

    def test_in_flight_pending_verdict_still_blocks(self) -> None:
        self.merged_gate("old-r1")
        ledger = self.state / "old" / "ledger.md"
        ledger.parent.mkdir(parents=True)
        ledger.write_text(
            "round=1 | change=x | pr=1 | lab=held | claude=pending | codex=pending | candidate=pending | merge=abc\n"
        )
        rc, out = self.freeze()
        self.assertEqual(rc, 1)
        self.assertIn("merged unmeasured candidate", out["reason"])
        self.assertIn("harness-climb/gates/old-r1.json", out["reason"])

    def test_in_flight_ignores_files_that_are_not_gate_paths(self) -> None:
        self.git("checkout", "-q", "main")
        self.commit({"harness-climb/gates/README.md": "notes\n"}, "notes")
        self.git("checkout", "-q", "harness-climb/t1/r1")
        self.git("rebase", "-q", "main")
        self.critic()
        self.assertEqual(
            hc_freeze.in_flight(self.repo, self.state, "main", "skill", "t1", 1), []
        )


class GatePathTests(TestCase):
    def test_parse_gate_path_inverts_gate_path(self) -> None:
        path = hc_gate.gate_path("my-thread", 12)
        self.assertEqual(hc_gate.parse_gate_path(path), ("my-thread", 12))

    def test_parse_gate_path_rejects_other_paths(self) -> None:
        for path in ("harness-climb/gates/README.md", "other/t1-r1.json", "t1-r1.json"):
            self.assertIsNone(hc_gate.parse_gate_path(path), path)


class LeakageTests(FreezeCase):
    LEAK = "acmesecretproject"

    def test_leaking_query_is_refused_without_echoing_the_text(self) -> None:
        self.critic()
        deny = {"prompt": set(), "path": set(), "project": {self.LEAK}}
        query = f"SELECT harness, sessionId, 1.0 AS value FROM sessions WHERE project = '{self.LEAK}'"
        with mock.patch("hc_freeze.load_denylist", return_value=(deny, [])):
            rc, out = self.freeze(query=query)
        self.assertEqual((rc, out["status"]), (1, "refused"))
        self.assertIn("leaks denylisted text: project", out["reason"])
        self.assertNotIn(self.LEAK, out["reason"])
        self.assertFalse((self.repo / "harness-climb").exists())
        (line,) = self.ledger_lines()
        self.assertNotIn(self.LEAK, line["change"])

    def test_freeze_is_refused_when_the_denylist_is_unavailable(self) -> None:
        self.critic()
        with mock.patch("hc_freeze.load_denylist", return_value=(None, [])):
            rc, out = self.freeze()
        self.assertEqual(rc, 1)
        self.assertIn("denylist unavailable", out["reason"])
        self.assertFalse((self.repo / "harness-climb").exists())


class DbFailureTests(FreezeCase):
    def test_a_failed_refresh_is_not_reported_as_a_bad_query(self) -> None:
        self.critic()
        failure = hc_db.RefreshFailed("session database refresh failed")
        with mock.patch("hc_freeze.resolve_db", side_effect=failure):
            rc, out = self.freeze()
        self.assertEqual((rc, out["status"]), (1, "refused"))
        self.assertIn("session database unavailable", out["reason"])
        self.assertNotIn("dry run", out["reason"])

    def test_a_failed_refresh_in_the_denylist_load_is_not_a_bad_query(self) -> None:
        self.critic()
        failure = hc_db.RefreshFailed("session database refresh failed")
        with mock.patch("hc_freeze.load_denylist", side_effect=failure):
            rc, out = self.freeze()
        self.assertEqual(rc, 1)
        self.assertIn("session database unavailable", out["reason"])

    def test_a_missing_duckdb_is_not_reported_as_a_bad_query(self) -> None:
        db = Path("/x/s.duckdb")
        with (
            mock.patch("hc_freeze.resolve_db", return_value=db),
            mock.patch("hc_db._shell_settings", return_value=(db, "1GB")),
            mock.patch("hc_db.subprocess.run", side_effect=FileNotFoundError),
        ):
            reason = hc_freeze.query_problem(QUERY)
        self.assertIn("session database unavailable", reason)
        self.assertNotIn("dry run", reason)

    @needs_duckdb
    def test_a_bad_query_still_reports_the_dry_run(self) -> None:
        self.critic()
        rc, out = self.freeze(query="SELECT nope FROM sessions")
        self.assertEqual(rc, 1)
        self.assertIn("failed the dry run", out["reason"])


class RefusalLedgerTests(FreezeCase):
    def test_refused_freeze_appends_a_na_ledger_line_with_the_reason(self) -> None:
        rc, out = self.freeze()
        self.assertEqual(rc, 1)
        (line,) = self.ledger_lines()
        self.assertEqual(line["round"], "1")
        self.assertEqual(line["candidate"], "n/a")
        self.assertEqual((line["lab"], line["claude"], line["codex"]), ("n/a",) * 3)
        self.assertEqual((line["pr"], line["merge"]), ("none", "none"))
        self.assertIn(out["reason"], line["change"])

    def test_refusals_never_count_as_a_field_verdict(self) -> None:
        self.freeze()
        self.assertNotIn("1", hc_ledger.measured_rounds(self.state, "t1"))


if __name__ == "__main__":
    main()
