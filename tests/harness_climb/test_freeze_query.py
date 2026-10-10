"""Freeze: the targeted-query dry run, the lab contract, and the refusal defaults."""

from __future__ import annotations

import contextlib
import io
import os
import subprocess
from typing import Any
from unittest import mock

import hc_freeze

from .support import call, cli, hc_db
from .test_freeze import QUERY, FreezeCase, needs_duckdb


class ContractTests(FreezeCase):
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
    def test_lab_contract_added_only_on_the_branch_is_no_contract(self) -> None:
        self.commit({"skills/foo/evals/autoimprove.json": "{}\n"}, "contract")
        self.critic()
        rc, out = self.freeze("--autoimprove-verdict", "promote")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["lab"], {"verdict": "held", "reason": "no-contract"})

    def test_lab_contract_holds_when_any_touched_skill_is_contracted_at_base(
        self,
    ) -> None:
        self.contract("foo")
        self.commit({"skills/bar/SKILL.md": "edit\n"}, "second skill")
        names = hc_freeze.touched_skills(self.repo, "main")
        self.assertEqual(names, {"foo", "bar"})
        self.assertTrue(hc_freeze.has_contract(self.repo, "main", names))
        self.assertFalse(hc_freeze.has_contract(self.repo, "main", {"bar"}))

    def test_skill_round_spanning_two_skills_is_refused(self) -> None:
        self.contract("foo")
        self.commit({"skills/bar/SKILL.md": "edit\n"}, "second skill")
        self.critic()
        rc, out = self.freeze("--autoimprove-verdict", "promote")
        self.assertEqual((rc, out["status"]), (1, "refused"), out)
        self.assertIn("one skill", out["reason"])
        self.assertFalse((self.repo / "harness-climb").exists())


class QueryDryRunTests(FreezeCase):
    def query_freeze(self, query: str) -> tuple[int, dict[str, Any]]:
        self.critic()
        return self.freeze(query=query)

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


class DuckdbMissingTests(FreezeCase):
    """The CI runner has no duckdb on PATH: the freeze must refuse, not crash."""

    def hide_duckdb(self) -> mock._patch[Any]:
        real = subprocess.run

        def run(args: Any, *a: Any, **kw: Any) -> Any:
            if args[0] == "duckdb":
                raise FileNotFoundError(2, "No such file", "duckdb")
            return real(args, *a, **kw)

        return mock.patch.object(hc_db.subprocess, "run", run)

    def test_duck_turns_a_missing_binary_into_a_db_error(self) -> None:
        with self.hide_duckdb(), self.assertRaises(hc_db.DbError) as ctx:
            hc_db.duck(self.dir / "x.duckdb", "SELECT 1")
        self.assertIn("duckdb not installed", str(ctx.exception))

    def test_freeze_refuses_and_records_the_reason_without_duckdb(self) -> None:
        self.critic()
        with self.hide_duckdb():
            rc, out = self.freeze()
        self.assertEqual((rc, out["status"]), (1, "refused"), out)
        self.assertIn("session database unavailable", out["reason"])
        self.assertIn("duckdb not installed", out["reason"])
        (line,) = self.ledger_lines()
        self.assertEqual(line["candidate"], "n/a")
        self.assertIn("duckdb not installed", line["change"])
        self.assertFalse((self.repo / "harness-climb").exists())


class RefreshFailureTests(FreezeCase):
    def test_freeze_refuses_when_the_database_refresh_fails(self) -> None:
        self.critic()
        with mock.patch.object(hc_db, "ensure_fresh_db", return_value=False):
            rc, out = self.freeze()
        self.assertEqual((rc, out["status"]), (1, "refused"), out)
        self.assertIn("session database refresh failed", out["reason"])
        self.assertFalse((self.repo / "harness-climb").exists())

    def test_a_refused_freeze_never_reads_the_query_file(self) -> None:
        missing = self.dir / "absent-query.sql"
        rc, out = call(
            "freeze", "--repo", str(self.repo), "--state-dir", str(self.state),
            "--thread", "t1", "--round", "1", "--component", "skill",
            "--base", "main", "--targeted-query-file", str(missing),
        )  # fmt: skip
        self.assertEqual((rc, out["status"]), (1, "refused"), out)
        self.assertIn("critic", out["reason"])


class BaseDefaultTests(FreezeCase):
    def test_critic_freeze_and_ledger_default_to_origin_main(self) -> None:
        parser = cli.build_parser()
        common = ["--thread", "t1"]
        critic = parser.parse_args(["critic", *common, "--round", "1"])
        freeze = parser.parse_args(
            ["freeze", *common, "--round", "1", "--component", "skill"]
            + ["--targeted-query", QUERY]
        )
        pending = parser.parse_args(["ledger", "pending", *common])
        self.assertEqual(
            (critic.base, freeze.base, pending.main_ref), ("origin/main",) * 3
        )
