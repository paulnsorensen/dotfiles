from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "skills" / "hill-climb" / "scripts" / "ratchet.py"


def run_cli(*argv: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *argv],
        capture_output=True,
        text=True,
        check=False,
    )


class RatchetCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.file = self.dir / "ratchet.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def add(
        self, metric: str, value: str, direction: str = "lower", *extra: str
    ) -> None:
        result = run_cli(
            "add",
            "--file",
            str(self.file),
            "--metric",
            metric,
            "--direction",
            direction,
            "--value",
            value,
            *extra,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def data(self) -> dict[str, Any]:
        return json.loads(self.file.read_text(encoding="utf-8"))


class AddTests(RatchetCase):
    def test_add_creates_file_with_metric(self) -> None:
        self.add(
            "tree.instructions",
            "1000",
            "lower",
            "--unit",
            "instructions",
            "--command",
            "node bench.js",
        )
        entry = self.data()["metrics"]["tree.instructions"]
        self.assertEqual(self.data()["version"], 1)
        self.assertEqual(entry["threshold"], 1000)
        self.assertIsInstance(entry["threshold"], int)
        self.assertEqual(entry["direction"], "lower")
        self.assertEqual(entry["unit"], "instructions")
        self.assertEqual(entry["command"], "node bench.js")

    def test_add_refuses_existing_metric(self) -> None:
        self.add("a", "10")
        result = run_cli(
            "add",
            "--file",
            str(self.file),
            "--metric",
            "a",
            "--direction",
            "lower",
            "--value",
            "5",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(self.data()["metrics"]["a"]["threshold"], 10)

    def test_add_rejects_bad_name_and_value(self) -> None:
        bad_name = run_cli(
            "add",
            "--file",
            str(self.file),
            "--metric",
            "a b",
            "--direction",
            "lower",
            "--value",
            "1",
        )
        self.assertEqual(bad_name.returncode, 2)
        nan = run_cli(
            "add",
            "--file",
            str(self.file),
            "--metric",
            "a",
            "--direction",
            "lower",
            "--value",
            "nan",
        )
        self.assertEqual(nan.returncode, 2)
        self.assertFalse(self.file.exists())

    def test_add_creates_nested_parent_directories(self) -> None:
        self.file = self.dir / "perf" / "ratchet" / "thread.json"
        self.add("a", "10")
        self.assertEqual(self.data()["metrics"]["a"]["threshold"], 10)

    def test_new_file_mode_follows_umask(self) -> None:
        for umask in (0o022, 0o077):
            with self.subTest(umask=oct(umask)):
                self.file = self.dir / f"umask-{umask:o}.json"
                previous = os.umask(umask)
                try:
                    self.add("a", "10")
                finally:
                    os.umask(previous)
                self.assertEqual(self.file.stat().st_mode & 0o777, 0o666 & ~umask)

    def test_directory_path_is_input_error(self) -> None:
        result = run_cli(
            "add",
            "--file",
            str(self.dir),
            "--metric",
            "a",
            "--direction",
            "lower",
            "--value",
            "1",
        )
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)

    def test_undecodable_file_is_input_error(self) -> None:
        self.file.write_bytes(b"\xff\xfe\x00bad")
        result = run_cli("check", "--file", str(self.file), "--value", "a=1")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root ignores file permissions")
    def test_unreadable_file_is_input_error(self) -> None:
        self.add("a", "10")
        self.file.chmod(0o000)
        result = run_cli("check", "--file", str(self.file), "--value", "a=1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot read", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


class CheckTests(RatchetCase):
    def check(self, *values: str, partial: bool = False) -> tuple[int, dict[str, Any]]:
        argv = ["check", "--file", str(self.file)]
        for value in values:
            argv += ["--value", value]
        if partial:
            argv.append("--partial")
        result = run_cli(*argv)
        return result.returncode, json.loads(result.stdout) if result.stdout else {}

    def test_lower_metric_regression_fails_gate(self) -> None:
        self.add("a", "100")
        code, report = self.check("a=101")
        self.assertEqual(code, 1)
        self.assertEqual(report["results"][0]["status"], "regressed")

    def test_equal_passes_and_better_reports_improved(self) -> None:
        self.add("a", "100")
        self.assertEqual(self.check("a=100")[1]["results"][0]["status"], "pass")
        code, report = self.check("a=90")
        self.assertEqual(code, 0)
        self.assertEqual(report["results"][0]["status"], "improved")

    def test_higher_metric_direction(self) -> None:
        self.add("fps", "120", "higher")
        self.assertEqual(self.check("fps=119")[0], 1)
        self.assertEqual(self.check("fps=121")[1]["results"][0]["status"], "improved")

    def test_tolerance_absorbs_noise_inside_limit_only(self) -> None:
        self.add("ms", "100", "lower", "--tolerance", "0.05")
        self.assertEqual(self.check("ms=105")[0], 0)
        self.assertEqual(self.check("ms=105.1")[0], 1)

    def test_higher_tolerance_boundary(self) -> None:
        self.add("fps", "100", "higher", "--tolerance", "0.05")
        self.assertEqual(self.check("fps=95")[0], 0)
        self.assertEqual(self.check("fps=94.9")[0], 1)

    def test_missing_metric_fails_unless_partial(self) -> None:
        self.add("a", "10")
        self.add("b", "10")
        code, report = self.check("a=10")
        self.assertEqual(code, 1)
        self.assertIn({"metric": "b", "status": "missing"}, report["results"])
        self.assertEqual(self.check("a=10", partial=True)[0], 0)

    def test_unknown_metric_is_input_error(self) -> None:
        self.add("a", "10")
        result = run_cli("check", "--file", str(self.file), "--value", "zzz=1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown metric", result.stderr)

    def test_malformed_file_is_input_error(self) -> None:
        self.file.write_text(
            '{"version": 1, "metrics": {"a": {"direction": "down", "threshold": 1}}}'
        )
        result = run_cli("check", "--file", str(self.file), "--value", "a=1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("direction", result.stderr)


class TightenTests(RatchetCase):
    def tighten(self, *values: str) -> tuple[int, dict[str, Any]]:
        argv = ["tighten", "--file", str(self.file), "--revision", "abc123"]
        for value in values:
            argv += ["--value", value]
        result = run_cli(*argv)
        return result.returncode, json.loads(result.stdout)

    def test_tighten_moves_threshold_toward_better(self) -> None:
        self.add("a", "100")
        code, report = self.tighten("a=80")
        self.assertEqual(code, 0)
        self.assertEqual(report["results"][0]["status"], "tightened")
        self.assertEqual(self.data()["metrics"]["a"]["threshold"], 80)
        self.assertEqual(self.data()["metrics"]["a"]["revision"], "abc123")

    def test_tighten_refuses_loosening_and_writes_nothing(self) -> None:
        self.add("a", "100")
        self.add("b", "100")
        before = self.file.read_text(encoding="utf-8")
        code, report = self.tighten("a=80", "b=120")
        self.assertEqual(code, 1)
        self.assertFalse(report["written"])
        self.assertEqual(self.file.read_text(encoding="utf-8"), before)

    def test_tighten_higher_direction(self) -> None:
        self.add("fps", "60", "higher")
        self.assertEqual(self.tighten("fps=120")[0], 0)
        self.assertEqual(self.data()["metrics"]["fps"]["threshold"], 120)
        self.assertEqual(self.tighten("fps=90")[0], 1)

    def test_tighten_is_idempotent_and_skips_write_when_unchanged(self) -> None:
        self.add("a", "100")
        self.assertEqual(self.tighten("a=80")[0], 0)
        self.file.chmod(0o640)
        before = self.file.stat().st_mtime_ns
        code, report = self.tighten("a=80")
        self.assertEqual(code, 0)
        self.assertEqual(report["results"][0]["status"], "unchanged")
        self.assertFalse(report["written"])
        self.assertEqual(self.file.stat().st_mtime_ns, before)
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.data()["metrics"]["a"]["threshold"], 80)

    def test_tighten_preserves_file_mode(self) -> None:
        self.add("a", "100")
        self.file.chmod(0o664)
        self.assertEqual(self.tighten("a=80")[0], 0)
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o664)


class MeasureTests(RatchetCase):
    def measure(
        self, script: str, runs: str = "4", *extra: str
    ) -> tuple[int, dict[str, Any]]:
        result = run_cli(
            "measure", "--runs", runs, *extra, "--", sys.executable, "-c", script
        )
        return result.returncode, json.loads(result.stdout)

    def test_stable_output_is_deterministic(self) -> None:
        code, report = self.measure("print('log line'); print(4242)")
        self.assertEqual(code, 0)
        self.assertTrue(report["deterministic"])
        self.assertEqual(report["values"], [4242] * 4)

    def test_varying_output_fails_without_tolerance(self) -> None:
        counter = self.dir / "n"
        script = (
            f"import pathlib; p = pathlib.Path({str(counter)!r}); n = int(p.read_text()) if p.exists() else 0; "
            "p.write_text(str(n + 1)); print(100 + n)"
        )
        code, report = self.measure(script)
        self.assertEqual(code, 1)
        self.assertFalse(report["deterministic"])
        counter.unlink()
        code, report = self.measure(script, "4", "--tolerance", "0.05")
        self.assertEqual(code, 0, report)

    def test_failing_command_fails_gate(self) -> None:
        code, report = self.measure("import sys; sys.exit(3)")
        self.assertEqual(code, 1)
        self.assertEqual(report["exit"], 3)
        self.assertEqual(report["error"], "command-failed")

    def test_timeout_is_a_failed_run(self) -> None:
        code, report = self.measure(
            "import time; time.sleep(30)", "1", "--timeout", "0.5"
        )
        self.assertEqual(code, 1)
        self.assertEqual(report["error"], "timeout")
        self.assertEqual(report["failed_run"], 1)

    def test_non_positive_timeout_is_input_error(self) -> None:
        result = run_cli(
            "measure", "--timeout", "0", "--", sys.executable, "-c", "print(1)"
        )
        self.assertEqual(result.returncode, 2)

    def test_non_numeric_output_is_input_error(self) -> None:
        result = run_cli(
            "measure", "--runs", "1", "--", sys.executable, "-c", "print('fast')"
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a number", result.stderr)


if __name__ == "__main__":
    unittest.main()
