from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "skills" / "ci-optimize" / "scripts" / "ci_optimize.py"


def run_cli(
    *args: str, payload: dict[str, Any] | None = None
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        input_path = Path(directory) / "input.json"
        if payload is not None:
            input_path.write_text(json.dumps(payload), encoding="utf-8")
            args = (*args, "--input", str(input_path))
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            text=True,
            capture_output=True,
            check=False,
        )


def ci_payload(*, attempt: int = 1, completed: bool = True) -> dict[str, Any]:
    jobs = [
        {
            "id": 101,
            "run_id": 99,
            "run_attempt": attempt,
            "name": "lint",
            "status": "completed" if completed else "in_progress",
            "conclusion": "success" if completed else None,
            "started_at": "2026-01-01T00:00:10Z",
            "completed_at": "2026-01-01T00:05:00Z" if completed else None,
        },
        {
            "id": 102,
            "run_id": 99,
            "run_attempt": attempt,
            "name": "test",
            "status": "completed" if completed else "in_progress",
            "conclusion": "success" if completed else None,
            "started_at": "2026-01-01T00:00:20Z",
            "completed_at": "2026-01-01T00:08:00Z" if completed else None,
        },
    ]
    return {
        "schema_version": 1,
        "source": "github-actions",
        "captures": [
            {
                "context": {
                    "repository": "owner/repo",
                    "workflow": "verify",
                    "workflow_id": "7",
                    "event_class": "pull_request",
                    "workload_label": "default",
                    "validation_contract": "required-checks-v1",
                    "runner_toolchain": "ubuntu-python-3.12",
                    "cache_state": "warm",
                },
                "run": {
                    "id": 99,
                    "workflow_id": 7,
                    "event": "pull_request",
                    "head_sha": "a" * 40,
                    "run_attempt": attempt,
                    "status": "completed",
                    "conclusion": "success",
                    "created_at": "2026-01-01T00:00:00Z",
                },
                "job_pages": [{"total_count": 2, "jobs": jobs}],
                "collection": {
                    "run_id": 99,
                    "attempt": attempt,
                    "selected_job_ids": [101, 102],
                    "expected_job_ids": [101, 102],
                    "captured_at": "2026-01-01T00:10:00Z",
                },
            }
        ],
    }


class CliTests(unittest.TestCase):
    def test_ci_uses_latest_selected_completion_not_sum(self) -> None:
        result = run_cli("ci", payload=ci_payload())
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        observation = output["observations"][0]
        self.assertEqual(observation["duration_seconds"], 480.0)
        self.assertEqual(observation["pre_start_seconds"], 10.0)
        self.assertEqual(
            [job["duration_seconds"] for job in observation["jobs"]],
            [290.0, 460.0],
        )
        self.assertEqual(
            observation["provenance"]["captured_at"], "2026-01-01T00:10:00Z"
        )
        self.assertTrue(observation["eligibility"])

    def test_ci_keeps_incomplete_observation_as_diagnostic(self) -> None:
        payload = ci_payload(completed=False)
        payload["captures"][0]["job_pages"][0]["total_count"] = 3
        result = run_cli("ci", payload=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        observation = json.loads(result.stdout)["observations"][0]
        self.assertFalse(observation["eligibility"])
        self.assertIn("incomplete_job_pages", observation["reasons"])

    def test_ci_rejects_duplicate_job_ids(self) -> None:
        payload = ci_payload()
        payload["captures"][0]["job_pages"][0]["jobs"][1]["id"] = 101
        result = run_cli("ci", payload=payload)
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate job ID", result.stderr)

    def test_ci_excludes_reruns_without_fabricating_anchor(self) -> None:
        result = run_cli("ci", payload=ci_payload(attempt=2))
        self.assertEqual(result.returncode, 0, result.stderr)
        observation = json.loads(result.stdout)["observations"][0]
        self.assertFalse(observation["eligibility"])
        self.assertIsNone(observation["duration_seconds"])
        self.assertIn("rerun_no_creation_anchor", observation["reasons"])

    def test_local_retains_failed_records_and_metadata(self) -> None:
        payload = {
            "schema_version": 1,
            "source": "local",
            "command": "just check",
            "revision": "abc",
            "environment": "macos-arm64",
            "cache_state": "cold",
            "workload_label": "default",
            "benchmark_source": {"tool": "hyperfine", "evidence_file": "samples.json"},
            "samples": [
                {
                    "id": "success-1",
                    "status": "success",
                    "duration_seconds": 10,
                    "exit_code": 0,
                    "warmup": False,
                },
                {
                    "id": "failed-1",
                    "status": "failed",
                    "duration_seconds": None,
                    "exit_code": 1,
                    "warmup": False,
                },
            ],
        }
        result = run_cli("local", payload=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["context"]["command"], "just check")
        self.assertEqual(len(output["exclusions"]), 1)
        self.assertEqual(output["observations"][1]["reasons"], ["failed"])

    def test_local_rejects_nonfinite_duration(self) -> None:
        payload = {
            "schema_version": 1,
            "source": "local",
            "command": "just check",
            "revision": "abc",
            "environment": "macos",
            "cache_state": "warm",
            "workload_label": "default",
            "benchmark_source": {"tool": "time", "evidence_file": "samples.json"},
            "samples": [
                {
                    "id": "1",
                    "status": "success",
                    "duration_seconds": float("inf"),
                    "exit_code": 0,
                    "warmup": False,
                },
            ],
        }
        result = run_cli("local", payload=payload)
        self.assertEqual(result.returncode, 2)

    def test_compare_reports_median_delta(self) -> None:
        def dataset(values: list[int]) -> dict[str, Any]:
            return {
                "schema_version": 1,
                "source": "local",
                "context": {
                    "command": "just check",
                    "revision": "abc",
                    "environment": "macos",
                    "cache_state": "warm",
                    "workload_label": "default",
                    "benchmark_source": {
                        "tool": "time",
                        "evidence_file": "samples.json",
                    },
                },
                "observations": [
                    {
                        "identity": {"id": str(index)},
                        "duration_seconds": value,
                        "eligibility": True,
                        "reasons": [],
                        "status": "success",
                        "exit_code": 0,
                        "warmup": False,
                        "provenance": {"tool": "time", "evidence_file": "samples.json"},
                    }
                    for index, value in enumerate(values)
                ],
                "exclusions": [],
            }

        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.json"
            after = Path(directory) / "after.json"
            before.write_text(json.dumps(dataset([480, 500, 520])), encoding="utf-8")
            after.write_text(json.dumps(dataset([360, 380, 400])), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "compare",
                    "--before",
                    str(before),
                    "--after",
                    str(after),
                    "--minimum-samples",
                    "3",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["comparability"])
        self.assertEqual(report["before"]["median_seconds"], 500.0)
        self.assertEqual(report["after"]["median_seconds"], 380.0)
        self.assertEqual(report["delta"]["saved_seconds"], 120.0)
        self.assertEqual(report["delta"]["saved_percent"], 24.0)

    def test_compare_rejects_mutated_ci_timing(self) -> None:
        normalized_result = run_cli("ci", payload=ci_payload())
        self.assertEqual(normalized_result.returncode, 0, normalized_result.stderr)
        normalized = json.loads(normalized_result.stdout)
        observation = normalized["observations"][0]
        observation["selected_completed_at"] = "2026-01-01T00:08:01+00:00"
        observation["duration_seconds"] = 481.0
        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.json"
            after = Path(directory) / "after.json"
            before.write_text(json.dumps(normalized), encoding="utf-8")
            after.write_text(json.dumps(normalized), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "compare",
                    "--before",
                    str(before),
                    "--after",
                    str(after),
                    "--minimum-samples",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("timing does not match", result.stderr)

    def test_compare_rejects_boolean_schema_version(self) -> None:
        dataset = {
            "schema_version": True,
            "source": "local",
            "context": {
                "command": "x",
                "revision": "a",
                "environment": "macos",
                "cache_state": "warm",
                "workload_label": "default",
                "benchmark_source": {"tool": "time", "evidence_file": "x"},
            },
            "observations": [],
            "exclusions": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.json"
            after = Path(directory) / "after.json"
            before.write_text(json.dumps(dataset), encoding="utf-8")
            after.write_text(json.dumps(dataset), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "compare",
                    "--before",
                    str(before),
                    "--after",
                    str(after),
                    "--minimum-samples",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("schema_version", result.stderr)

    def test_compare_rejects_malformed_normalized_dataset(self) -> None:
        dataset = {
            "schema_version": 1,
            "source": "local",
            "context": {
                "command": "x",
                "revision": "a",
                "environment": "macos",
                "cache_state": "warm",
                "workload_label": "default",
                "benchmark_source": {"tool": "time", "evidence_file": "x"},
            },
            "observations": [
                {
                    "identity": {"id": "1"},
                    "duration_seconds": 1,
                    "eligibility": True,
                    "reasons": ["lied"],
                }
            ],
            "exclusions": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.json"
            after = Path(directory) / "after.json"
            before.write_text(json.dumps(dataset), encoding="utf-8")
            after.write_text(json.dumps(dataset), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "compare",
                    "--before",
                    str(before),
                    "--after",
                    str(after),
                    "--minimum-samples",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("no reasons", result.stderr)

    def test_compare_report_retains_acknowledgement_plan_ref(self) -> None:
        def dataset(cache_state: str) -> dict[str, Any]:
            return {
                "schema_version": 1,
                "source": "local",
                "context": {
                    "command": "just check",
                    "revision": "abc",
                    "environment": "macos",
                    "cache_state": cache_state,
                    "workload_label": "default",
                    "benchmark_source": {
                        "tool": "time",
                        "evidence_file": "samples.json",
                    },
                },
                "observations": [
                    {
                        "identity": {"id": "1"},
                        "duration_seconds": 10.0,
                        "eligibility": True,
                        "reasons": [],
                        "status": "success",
                        "exit_code": 0,
                        "warmup": False,
                        "provenance": {"tool": "time", "evidence_file": "samples.json"},
                    }
                ],
                "exclusions": [],
            }

        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.json"
            after = Path(directory) / "after.json"
            acknowledgement = Path(directory) / "ack.json"
            before.write_text(json.dumps(dataset("warm")), encoding="utf-8")
            after.write_text(json.dumps(dataset("cold")), encoding="utf-8")
            acknowledgement.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "plan_ref": "approved-plan-7",
                        "differences": [
                            {"field": "cache_state", "before": "warm", "after": "cold"}
                        ],
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "compare",
                    "--before",
                    str(before),
                    "--after",
                    str(after),
                    "--minimum-samples",
                    "1",
                    "--acknowledgements",
                    str(acknowledgement),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["comparability"])
        self.assertEqual(report["acknowledgement_plan_ref"], "approved-plan-7")


if __name__ == "__main__":
    unittest.main()
