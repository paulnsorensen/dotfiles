"""Behavior tests for skills/review-leverage/scripts/review_leverage.py.

Each test builds a real git repository with a bare origin and runs the CLI as
a subprocess. Nothing in the script is mocked.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

# REVIEW_LEVERAGE_SCRIPT points the suite at a seeded mutant copy.
SCRIPT = Path(
    os.environ.get("REVIEW_LEVERAGE_SCRIPT")
    or Path(__file__).resolve().parents[2]
    / "skills/review-leverage/scripts/review_leverage.py"
)

BATS_BASE = """@test "greets" {
  run greet
  [ "$status" -eq 0 ]
  [[ "$output" == *hello* ]]
}
"""


class Repo:
    def __init__(self, root: Path) -> None:
        self.origin = root / "origin.git"
        self.path = root / "work"
        self.home = root / "home"
        self.env = {
            **os.environ,
            "REVIEW_LEVERAGE_HOME": str(self.home),
            "REVIEW_LEVERAGE_RISK": "off",
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.invalid",
        }
        self.git("init", "-q", "--bare", "-b", "main", str(self.origin), cwd=root)
        self.git("init", "-q", "-b", "main", str(self.path), cwd=root)
        self.git("remote", "add", "origin", str(self.origin))

    def git(self, *args: str, cwd: Path | None = None, env: dict | None = None) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.path,
            env=env or self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def write(self, files: dict[str, str | None]) -> None:
        for rel, text in files.items():
            target = self.path / rel
            if text is None:
                target.unlink()
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)

    def commit(
        self, files: dict[str, str | None], msg: str, env: dict | None = None
    ) -> None:
        self.write(files)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg, env=env)

    def publish_main(self) -> None:
        self.git("push", "-q", "origin", "main")
        self.git("remote", "set-head", "origin", "main")

    def cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.path,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def rank(self) -> dict:
        proc = self.cli("rank", "--json")
        if proc.returncode != 0:
            raise AssertionError(proc.stderr)
        return json.loads(proc.stdout)

    def ledger(self) -> list[dict]:
        path = self.home / "ledger.jsonl"
        return [json.loads(x) for x in path.read_text().splitlines()]


def area_for(run: dict, path: str) -> dict:
    for area in run["areas"]:
        if path in area["files"]:
            return area
    raise AssertionError(f"no area holds {path}: {run['areas']}")


class ReviewLeverageTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def base(self, files: dict[str, str]) -> None:
        self.repo.commit({"README.md": "x\n", **files}, "base")
        self.repo.publish_main()
        self.repo.git("checkout", "-q", "-b", "agent/change")

    def test_weakened_assertion_is_must_even_when_policy_skips_tests(self) -> None:
        self.base(
            {
                "tests/greet.bats": BATS_BASE,
                ".review-leverage.toml": 'skip_paths = ["tests/**"]\n',
            }
        )
        weakened = BATS_BASE.replace(
            '  [[ "$output" == *hello* ]]\n', '  skip "flaky on CI"\n'
        )
        self.repo.commit({"tests/greet.bats": weakened}, "make test pass")
        run = self.repo.rank()
        area = area_for(run, "tests/greet.bats")
        self.assertEqual((area["category"], area["tier"]), ("test-oracle", "must"))
        self.assertIn(area["id"], run["walk"])
        text = " ".join(area["reasons"])
        self.assertIn("removes or rewrites assertion", text)
        self.assertIn("adds skip marker", text)

    def test_gate_config_edit_is_must(self) -> None:
        self.base({".markdownlint-cli2.yaml": "config:\n  MD013: true\n"})
        self.repo.commit(
            {".markdownlint-cli2.yaml": "config:\n  MD013: false\n"}, "relax lint"
        )
        area = area_for(self.repo.rank(), ".markdownlint-cli2.yaml")
        self.assertEqual((area["category"], area["tier"]), ("gate-mute", "must"))

    def test_added_suppression_comment_is_must(self) -> None:
        self.base({"src/app.py": "x = 1\n"})
        self.repo.commit({"src/app.py": "x = 1\ny = eval_it()  # noqa: E501\n"}, "x")
        area = area_for(self.repo.rank(), "src/app.py")
        self.assertEqual(area["category"], "gate-mute")
        self.assertIn("adds suppression", area["reasons"][0])

    def test_policy_comes_from_default_branch_not_head(self) -> None:
        self.base({".review-leverage.toml": "should_budget = 0\n"})
        self.repo.commit(
            {
                ".review-leverage.toml": 'should_budget = 20\nskip_paths = ["**"]\n',
                "src/new_api.py": "def public(a):\n    return a\n",
            },
            "widen policy",
        )
        run = self.repo.rank()
        self.assertEqual(run["should_budget"], 0)
        self.assertTrue(run["policy"].startswith("builtin+origin/main:"))
        policy_area = area_for(run, ".review-leverage.toml")
        self.assertEqual(
            (policy_area["category"], policy_area["tier"]), ("gate-mute", "must")
        )
        api_area = area_for(run, "src/new_api.py")
        self.assertEqual(api_area["category"], "api-change")
        skipped = {s["id"]: s["reason"] for s in run["skipped"]}
        self.assertIn("beyond budget 0", skipped[api_area["id"]])

    def test_destructive_migration_is_must(self) -> None:
        self.base({"migrations/001.sql": "CREATE TABLE t (c int);\n"})
        self.repo.commit(
            {"migrations/002.sql": "ALTER TABLE t DROP COLUMN c;\n"}, "drop column"
        )
        area = area_for(self.repo.rank(), "migrations/002.sql")
        self.assertEqual((area["category"], area["tier"]), ("schema-breaking", "must"))

    def test_changed_public_signature_is_must(self) -> None:
        self.base({"src/core.py": "def handle(a):\n    return a\n"})
        self.repo.commit(
            {"src/core.py": "def handle(a, b):\n    return a + b\n"}, "change api"
        )
        area = area_for(self.repo.rank(), "src/core.py")
        self.assertEqual((area["category"], area["tier"]), ("api-breaking", "must"))

    def test_plain_script_function_is_not_api(self) -> None:
        self.base({"scripts/run.sh": "run() { echo a; }\nrun\n"})
        self.repo.commit({"scripts/run.sh": "echo a\n"}, "inline")
        area = area_for(self.repo.rank(), "scripts/run.sh")
        self.assertNotEqual(area["category"], "api-breaking")

    def test_lockfile_is_skipped_with_reason(self) -> None:
        self.base({"uv.lock": "a\n", "src/core.py": "def handle(a):\n    return a\n"})
        self.repo.commit(
            {"uv.lock": "b\n", "src/core.py": "def handle(b):\n    return b\n"}, "x"
        )
        run = self.repo.rank()
        lock = area_for(run, "uv.lock")
        skipped = {s["id"]: s["reason"] for s in run["skipped"]}
        self.assertIn("skip_paths", skipped[lock["id"]])

    def test_record_close_and_outcomes_join_on_head_commit(self) -> None:
        self.base({"tests/greet.bats": BATS_BASE, "uv.lock": "a\n"})
        self.repo.commit(
            {"tests/greet.bats": BATS_BASE.replace("-eq 0", "-eq 1"), "uv.lock": "b\n"},
            "agent change",
        )
        run = self.repo.rank()
        run_file = run["run_file"]
        self.assertEqual(self.repo.cli("close", "--run", run_file).returncode, 3)
        bad = self.repo.cli(
            "record", "--run", run_file, "--area", run["walk"][0], "--decision", "lgtm"
        )
        self.assertEqual(bad.returncode, 2)
        for aid in run["walk"]:
            rec = self.repo.cli(
                "record", "--run", run_file, "--area", aid, "--decision", "ok"
            )
            self.assertEqual(rec.returncode, 0, rec.stderr)
        closed = self.repo.cli("close", "--run", run_file)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        ledger = self.repo.ledger()
        self.assertEqual(len(ledger), len(run["walk"]) + len(run["skipped"]))
        self.assertEqual({e["head_sha"] for e in ledger}, {run["head_sha"]})
        self.assertEqual(
            sum(e["decision"] == "skipped" for e in ledger), len(run["skipped"])
        )

        self.repo.git("checkout", "-q", "main")
        later = {
            **self.repo.env,
            "GIT_COMMITTER_DATE": f"{int(time.time()) + 120} +0000",
        }
        fixed = (
            BATS_BASE + '@test "exit code" {\n  run greet\n  [ "$status" -eq 0 ]\n}\n'
        )
        self.repo.commit(
            {"tests/greet.bats": fixed}, "fix: restore greet assertion", env=later
        )
        self.repo.commit({"README.md": "y\n"}, "fix: typo", env=later)
        self.repo.publish_main()
        out = self.repo.cli("outcomes", "--json")
        self.assertEqual(out.returncode, 0, out.stderr)
        matches = json.loads(out.stdout)
        self.assertEqual(
            [m["later_subject"] for m in matches], ["fix: restore greet assertion"]
        )
        self.assertEqual(matches[0]["head_sha"], run["head_sha"])
        self.assertEqual(matches[0]["decision"], "ok")


if __name__ == "__main__":
    unittest.main()
