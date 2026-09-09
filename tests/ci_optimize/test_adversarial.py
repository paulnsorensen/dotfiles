"""Exercise malformed captures and comparison boundaries through the CLI."""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_cli import SCRIPT, ci_payload, run_cli


def local_payload(values=(10, 12, 14)):
    return {
        "schema_version": 1,
        "source": "local",
        "command": "just check",
        "revision": "abc",
        "environment": "macos-arm64",
        "cache_state": "cold",
        "workload_label": "required checks",
        "benchmark_source": {"tool": "fixture", "evidence_file": "raw.json"},
        "samples": [
            {
                "id": str(index),
                "status": "success",
                "duration_seconds": value,
                "exit_code": 0,
                "warmup": False,
            }
            for index, value in enumerate(values)
        ],
    }


class BoundaryTests(unittest.TestCase):
    def normalize(self, command, payload):
        result = run_cli(command, payload=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def compare(self, before, after=None, ack=None, minimum=1):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("before", "after", "ack")]
            for path, value in zip(paths, (before, after or before, ack), strict=True):
                path.write_text(json.dumps(value), encoding="utf-8")
            args = [
                "compare",
                "--before",
                str(paths[0]),
                "--after",
                str(paths[1]),
                "--minimum-samples",
                str(minimum),
            ]
            if ack is not None:
                args.extend(("--acknowledgements", str(paths[2])))
            return run_cli(*args)

    def test_local_numeric_and_outcome_boundaries(self):
        for value in (True, -1, float("nan"), float("inf"), 10**400):
            with self.subTest(value=repr(value)):
                result = run_cli("local", payload=local_payload((value,)))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
        for status, exit_code, warmup in (
            ("failed", 1, False),
            ("cancelled", None, False),
            ("timed_out", None, False),
            ("success", 0, True),
        ):
            payload = local_payload((10,))
            payload["samples"][0].update(
                status=status, exit_code=exit_code, warmup=warmup
            )
            data = self.normalize("local", payload)
            self.assertFalse(data["observations"][0]["eligibility"])
            self.assertEqual(len(data["exclusions"]), 1)

    def test_cancelled_codes_and_malformed_normalized_source(self):
        for status, code in (("cancelled", 130), ("timed_out", 124)):
            payload = local_payload((5,))
            payload["samples"][0].update(status=status, exit_code=code)
            data = self.normalize("local", payload)
            self.assertEqual(data["observations"][0]["exit_code"], code)
            self.assertFalse(data["observations"][0]["eligibility"])
            self.assertEqual(self.compare(data).returncode, 0)
            payload["samples"][0]["exit_code"] = 0
            self.assertEqual(run_cli("local", payload=payload).returncode, 2)
        data = self.normalize("local", local_payload())
        for source in ([], {}, None, True):
            data["source"] = source
            result = self.compare(data)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_unknown_context_cannot_be_acknowledged(self):
        for field in ("command", "environment", "cache_state", "workload_label"):
            payload = local_payload()
            payload[field] = "unknown"
            with self.subTest(field=field):
                data = self.normalize("local", payload)
                result = self.compare(data)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertFalse(report["comparability"], field)
                self.assertIsNone(report["delta"]["saved_seconds"])

    def test_context_acknowledgement_is_exact(self):
        before = self.normalize("local", local_payload())
        raw = local_payload()
        raw["command"] = "make check"
        after = self.normalize("local", raw)
        difference = {
            "field": "local command",
            "before": "just check",
            "after": "make check",
        }
        report = json.loads(self.compare(before, after).stdout)
        self.assertFalse(report["comparability"])
        ack = {"schema_version": 1, "plan_ref": "plan-1", "differences": [difference]}
        result = self.compare(before, after, ack)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["comparability"])
        self.assertEqual(report["acknowledged_differences"], [difference])
        bad = copy.deepcopy(ack)
        bad["differences"][0]["before"] = "not-the-command"
        self.assertEqual(self.compare(before, after, bad).returncode, 2)

    def test_mixed_sources_and_insufficient_samples_are_limits(self):
        local = self.normalize("local", local_payload())
        ci = self.normalize("ci", ci_payload())
        for result in (self.compare(local, ci), self.compare(local, minimum=4)):
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertFalse(report["comparability"])
            self.assertEqual(report["delta"]["direction"], "unavailable")
        self.assertEqual(self.compare(local, minimum=0).returncode, 2)

    def test_normalized_identity_and_eligibility_cannot_be_forged(self):
        for kind in ("ci", "local"):
            data = self.normalize(
                kind, ci_payload() if kind == "ci" else local_payload()
            )
            duplicate = copy.deepcopy(data["observations"][0])
            duplicate["identity"]["extra"] = "not-another-observation"
            data["observations"].append(duplicate)
            self.assertEqual(self.compare(data).returncode, 2)
        for field, value in (("warmup", True), ("exit_code", 1), ("status", "failed")):
            data = self.normalize("local", local_payload())
            data["observations"][0][field] = value
            with self.subTest(field=field):
                self.assertEqual(self.compare(data).returncode, 2)

    def test_ci_timing_and_population_boundaries(self):
        data = self.normalize("ci", ci_payload())
        data["observations"][0]["duration_seconds"] = 1
        self.assertEqual(self.compare(data).returncode, 2)
        payload = ci_payload()
        payload["captures"][0]["job_pages"][0]["jobs"][1]["name"] = "lint"
        data = self.normalize("ci", payload)
        result = self.compare(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["comparability"])
        for change in ("missing", "reversed", "failed"):
            payload = ci_payload()
            capture = payload["captures"][0]
            if change == "missing":
                capture["job_pages"][0]["jobs"].pop()
            elif change == "reversed":
                capture["job_pages"][0]["jobs"][0]["completed_at"] = (
                    "2025-12-31T23:59:00Z"
                )
            else:
                capture["run"]["conclusion"] = "failure"
            result = run_cli("ci", payload=payload)
            if change == "reversed":
                self.assertEqual(result.returncode, 2, result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(
                    json.loads(result.stdout)["observations"][0]["eligibility"]
                )

    def test_capture_completeness_cannot_be_forged(self):
        payload = ci_payload()
        payload["captures"][0]["job_pages"][0]["total_count"] = 3
        data = self.normalize("ci", payload)
        data["observations"][0].update(
            eligibility=True, reasons=[], duration_seconds=480
        )
        data["exclusions"] = []
        self.assertEqual(self.compare(data).returncode, 2)
        for total in (0, 1):
            payload["captures"][0]["job_pages"][0]["total_count"] = total
            self.assertEqual(run_cli("ci", payload=payload).returncode, 2)
        for captured in ("2025-01-01T00:00:00Z", "2026-01-01T00:07:00Z"):
            payload = ci_payload()
            payload["captures"][0]["collection"]["captured_at"] = captured
            self.assertEqual(run_cli("ci", payload=payload).returncode, 2)

    def test_large_finite_median_and_zero_baseline(self):
        for values in ((1e308, 1e308), (0, 0)):
            data = self.normalize("local", local_payload(values))
            result = self.compare(data)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("Infinity", result.stdout)
            self.assertNotIn("NaN", result.stdout)
            report = json.loads(result.stdout)
            self.assertEqual(report["before"]["median_seconds"], values[0])
            self.assertEqual(report["delta"]["saved_seconds"], 0)
            if values[0] == 0:
                self.assertIsNone(report["delta"]["saved_percent"])

    def test_output_and_encoding_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.json"
            output = Path(directory) / "output.json"
            source.write_text(json.dumps(local_payload()), encoding="utf-8")
            args = ["local", "--input", str(source), "--output", str(output)]
            first = run_cli(*args)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(first.stdout, "")
            original = output.read_bytes()
            self.assertEqual(run_cli(*args).returncode, 1)
            self.assertEqual(output.read_bytes(), original)
            self.assertEqual(run_cli(*args, "--force").returncode, 0)
            source.write_bytes(b"\xff")
            result = run_cli("local", "--input", str(source))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "local",
                    "--input",
                    str(source),
                    "--force",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
