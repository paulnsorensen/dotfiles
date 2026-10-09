"""Freeze: lab rule, gate file, and the one-in-flight rule."""

from __future__ import annotations

import contextlib
import io
import json
import os
import unittest
from typing import Any
from unittest import mock

from .support import HAVE_DUCKDB, RepoCase, call, gate_json, hc_gate, hc_ledger, make_db

QUERY = "SELECT harness, sessionId, 1.0 AS value FROM sessions"
needs_duckdb = unittest.skipUnless(HAVE_DUCKDB, "duckdb CLI not installed")


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

    def contract(self) -> None:
        self.commit({"skills/foo/evals/autoimprove.json": "{}\n"}, "contract")

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
        self, *extra: str, component: str = "skill", rnd: str = "1"
    ) -> tuple[int, dict[str, Any]]:
        return call(
            "freeze", "--repo", str(self.repo), "--state-dir", str(self.state), "--thread", "t1",
            "--round", rnd, "--component", component, "--targeted-query", QUERY, *extra,
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
        self.assertFalse((self.repo / "harness-climb").exists())

    @needs_duckdb
    def test_lab_contract_comes_from_the_evals_file_not_a_flag(self) -> None:
        self.critic()
        rc, out = self.freeze("--autoimprove-verdict", "promote")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["lab"], {"verdict": "held", "reason": "no-contract"})

    def test_lab_contract_flag_is_gone(self) -> None:
        self.critic()
        with (
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            self.freeze("--contract", "--autoimprove-verdict", "promote")

    @needs_duckdb
    def test_lab_contract_needs_every_touched_skill_contracted(self) -> None:
        self.contract()
        self.commit({"skills/bar/SKILL.md": "edit\n"}, "second skill")
        self.critic()
        rc, out = self.freeze("--autoimprove-verdict", "promote")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["lab"], {"verdict": "held", "reason": "no-contract"})

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
        self.critic(passed=False)
        self.assertEqual(self.freeze()[0], 1)
        self.critic(head="0" * 40)
        self.assertEqual(self.freeze()[0], 1)

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
        rc, out = call(
            "freeze", "--repo", str(self.repo), "--state-dir", str(self.state), "--thread", "t1",
            "--round", "1", "--component", "skill", "--targeted-query", "  ",
        )  # fmt: skip
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
        self.assertEqual(self.freeze()[0], 1)


class QueryDryRunTests(FreezeCase):
    def query_freeze(self, query: str) -> tuple[int, dict[str, Any]]:
        self.critic()
        return self.freeze_query(query)

    def freeze_query(self, query: str) -> tuple[int, dict[str, Any]]:
        return call(
            "freeze", "--repo", str(self.repo), "--state-dir", str(self.state), "--thread", "t1",
            "--round", "1", "--component", "skill", "--targeted-query", query,
        )  # fmt: skip

    def assertRefusedWithoutGate(self, rc: int, out: dict[str, Any], text: str) -> None:
        self.assertEqual((rc, out["status"]), (1, "refused"), out)
        self.assertIn(text, out["reason"])
        self.assertFalse((self.repo / "harness-climb").exists())

    def test_query_with_a_semicolon_is_refused_without_duckdb(self) -> None:
        rc, out = self.query_freeze(f"{QUERY}; DROP TABLE sessions")
        self.assertRefusedWithoutGate(rc, out, "';'")

    def test_query_with_a_trailing_semicolon_is_refused(self) -> None:
        rc, out = self.query_freeze(f"{QUERY};")
        self.assertRefusedWithoutGate(rc, out, "';'")

    @needs_duckdb
    def test_query_missing_the_value_column_is_refused(self) -> None:
        rc, out = self.query_freeze("SELECT harness, sessionId FROM sessions")
        self.assertRefusedWithoutGate(rc, out, "dry run")

    @needs_duckdb
    def test_query_with_a_sql_error_is_refused(self) -> None:
        rc, out = self.query_freeze("SELECT harness, sessionId, 1 AS value FROM nope")
        self.assertRefusedWithoutGate(rc, out, "dry run")

    def test_query_dry_run_is_refused_when_the_database_is_missing(self) -> None:
        with mock.patch.dict(os.environ, {"SESSIONS_DB": str(self.dir / "absent.db")}):
            rc, out = self.query_freeze(QUERY)
        self.assertRefusedWithoutGate(rc, out, "dry run")

    @needs_duckdb
    def test_query_with_the_three_columns_freezes(self) -> None:
        rc, out = self.query_freeze(
            "SELECT harness, sessionId, 2 AS value, 'x' AS extra FROM sessions"
        )
        self.assertEqual((rc, out["status"]), (0, "frozen"), out)


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
    unittest.main()
