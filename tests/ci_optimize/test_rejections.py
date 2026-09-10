from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .test_cli import SCRIPT, ci_payload, run_cli


def _naive_created_at_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"][0]["run"]["created_at"] = "2026-01-01T00:00:00"
    return payload


def _collection_identity_mismatch_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"][0]["collection"]["run_id"] = 555
    return payload


def _job_run_id_mismatch_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"][0]["job_pages"][0]["jobs"][0]["run_id"] = 555
    return payload


def _job_run_attempt_mismatch_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"][0]["job_pages"][0]["jobs"][0]["run_attempt"] = 555
    return payload


def _conflicting_total_count_payload() -> dict[str, Any]:
    payload = ci_payload()
    jobs = payload["captures"][0]["job_pages"][0]["jobs"]
    payload["captures"][0]["job_pages"] = [
        {"total_count": 2, "jobs": [jobs[0]]},
        {"total_count": 3, "jobs": [jobs[1]]},
    ]
    return payload


def _text_too_long_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"][0]["context"]["repository"] = "a" * 1001
    return payload


def _duplicate_selected_job_ids_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"][0]["collection"]["selected_job_ids"] = [101, 101]
    return payload


def _selected_not_subset_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"][0]["collection"]["selected_job_ids"] = [999]
    return payload


def _duplicate_run_identity_payload() -> dict[str, Any]:
    payload = ci_payload()
    payload["captures"].append(json.loads(json.dumps(payload["captures"][0])))
    return payload


class CiRejectionTests(unittest.TestCase):
    def test_ci_rejects_invalid_input(self) -> None:
        cases = [
            (
                "naive_created_at",
                _naive_created_at_payload,
                "run.created_at must include a timezone",
            ),
            (
                "collection_identity_mismatch",
                _collection_identity_mismatch_payload,
                "collection request does not match run identity",
            ),
            (
                "job_run_id_mismatch",
                _job_run_id_mismatch_payload,
                "job.run_id does not match run identity",
            ),
            (
                "job_run_attempt_mismatch",
                _job_run_attempt_mismatch_payload,
                "job.run_attempt does not match run identity",
            ),
            (
                "conflicting_total_count",
                _conflicting_total_count_payload,
                "job page totals conflict",
            ),
            (
                "text_too_long",
                _text_too_long_payload,
                "context.repository is too long",
            ),
            (
                "duplicate_selected_job_ids",
                _duplicate_selected_job_ids_payload,
                "selected_job_ids contains duplicate IDs",
            ),
            (
                "selected_not_subset",
                _selected_not_subset_payload,
                "selected_job_ids must be a subset of expected_job_ids",
            ),
            (
                "duplicate_run_identity",
                _duplicate_run_identity_payload,
                "duplicate run_id/run_attempt pair",
            ),
        ]
        for name, builder, expected in cases:
            with self.subTest(name=name):
                result = run_cli("ci", payload=builder())
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr)


def _local_dataset(cache_state: str) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "source": "local",
        "context": {
            "command": "just check",
            "revision": "abc",
            "environment": "macos",
            "cache_state": cache_state,
            "workload_label": "default",
            "benchmark_source": {"tool": "time", "evidence_file": "samples.json"},
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


def _run_compare(
    before: dict[str, Any],
    after: dict[str, Any],
    *,
    minimum_samples: str = "1",
    acknowledgements: dict[str, Any] | None = None,
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        before_path = Path(directory) / "before.json"
        after_path = Path(directory) / "after.json"
        before_path.write_text(json.dumps(before), encoding="utf-8")
        after_path.write_text(json.dumps(after), encoding="utf-8")
        args = [
            "compare",
            "--before",
            str(before_path),
            "--after",
            str(after_path),
            "--minimum-samples",
            minimum_samples,
        ]
        if acknowledgements is not None:
            ack_path = Path(directory) / "ack.json"
            ack_path.write_text(json.dumps(acknowledgements), encoding="utf-8")
            args.extend(["--acknowledgements", str(ack_path)])
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            text=True,
            capture_output=True,
            check=False,
        )


class CheckCiObservationTests(unittest.TestCase):
    def test_compare_rejects_normalized_observation_missing_status(self) -> None:
        normalized = json.loads(run_cli("ci", payload=ci_payload()).stdout)
        del normalized["observations"][0]["status"]
        result = _run_compare(normalized, normalized)
        self.assertEqual(result.returncode, 2)
        self.assertIn("observation.status", result.stderr)

    def test_compare_relabels_provenance_captured_at(self) -> None:
        normalized = json.loads(run_cli("ci", payload=ci_payload()).stdout)
        normalized["observations"][0]["provenance"]["captured_at"] = None
        result = _run_compare(normalized, normalized)
        self.assertEqual(result.returncode, 2)
        self.assertIn("observation.provenance.captured_at", result.stderr)
        self.assertNotIn("collection.captured_at", result.stderr)

    def test_compare_relabels_run_conclusion(self) -> None:
        normalized = json.loads(run_cli("ci", payload=ci_payload()).stdout)
        normalized["observations"][0]["conclusion"] = 123
        result = _run_compare(normalized, normalized)
        self.assertEqual(result.returncode, 2)
        self.assertIn("observation.conclusion", result.stderr)
        self.assertNotIn("run.conclusion", result.stderr)

    def test_compare_leaves_unrelated_reconstruction_message_untouched(self) -> None:
        normalized = json.loads(run_cli("ci", payload=ci_payload()).stdout)
        normalized["observations"][0]["jobs"][0]["status"] = 123
        result = _run_compare(normalized, normalized)
        self.assertEqual(result.returncode, 2)
        self.assertIn("job.status must be a non-empty string", result.stderr)


class CompareRejectionTests(unittest.TestCase):
    def test_compare_rejects_context_variants_mismatch(self) -> None:
        normalized = json.loads(run_cli("ci", payload=ci_payload()).stdout)
        normalized["context_variants"] = 2
        result = _run_compare(normalized, normalized)
        self.assertEqual(result.returncode, 2)
        self.assertIn("context_variants does not match observations", result.stderr)

    def test_compare_rejects_disallowed_acknowledgement_field(self) -> None:
        ack = {
            "schema_version": 1,
            "plan_ref": "p",
            "differences": [{"field": "workflow", "before": "x", "after": "y"}],
        }
        result = _run_compare(
            _local_dataset("warm"), _local_dataset("cold"), acknowledgements=ack
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("acknowledgement field is not allowed", result.stderr)

    def test_compare_rejects_duplicate_acknowledgement_field(self) -> None:
        ack = {
            "schema_version": 1,
            "plan_ref": "p",
            "differences": [
                {"field": "cache_state", "before": "warm", "after": "cold"},
                {"field": "cache_state", "before": "warm", "after": "cold"},
            ],
        }
        result = _run_compare(
            _local_dataset("warm"), _local_dataset("cold"), acknowledgements=ack
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate acknowledgement difference", result.stderr)


class FromHyperfineTests(unittest.TestCase):
    def test_from_hyperfine_datasets_are_comparable(self) -> None:
        export = {
            "results": [
                {"command": "just check", "times": [1.5, 1.6], "exit_codes": [0, 0]}
            ]
        }
        with tempfile.TemporaryDirectory() as directory:
            export_path = Path(directory) / "hyperfine.json"
            export_path.write_text(json.dumps(export), encoding="utf-8")
            flags = [
                "--input",
                str(export_path),
                "--command",
                "just check",
                "--environment",
                "macos",
                "--cache-state",
                "warm",
                "--workload-label",
                "default",
            ]
            before_result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "from-hyperfine",
                    *flags,
                    "--revision",
                    "before-sha",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(before_result.returncode, 0, before_result.stderr)
            before_normalized = json.loads(before_result.stdout)
            self.assertNotIn(
                "version", before_normalized["context"]["benchmark_source"]
            )
            expected_captured_at = datetime.fromtimestamp(
                export_path.stat().st_mtime, tz=timezone.utc
            ).isoformat()
            self.assertEqual(
                before_normalized["context"]["captured_at"], expected_captured_at
            )
            after_result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "from-hyperfine",
                    *flags,
                    "--revision",
                    "after-sha",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(after_result.returncode, 0, after_result.stderr)
            before_path = Path(directory) / "before.json"
            after_path = Path(directory) / "after.json"
            before_path.write_text(before_result.stdout, encoding="utf-8")
            after_path.write_text(after_result.stdout, encoding="utf-8")
            compare_result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "compare",
                    "--before",
                    str(before_path),
                    "--after",
                    str(after_path),
                    "--minimum-samples",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(compare_result.returncode, 0, compare_result.stderr)
        report = json.loads(compare_result.stdout)
        self.assertIsInstance(report["before"]["median_seconds"], float)

    def test_from_hyperfine_rejects_null_exit_code(self) -> None:
        export = {
            "results": [{"command": "x", "times": [1.0, 1.1], "exit_codes": [0, None]}]
        }
        with tempfile.TemporaryDirectory() as directory:
            export_path = Path(directory) / "hyperfine.json"
            export_path.write_text(json.dumps(export), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "from-hyperfine",
                    "--input",
                    str(export_path),
                    "--command",
                    "x",
                    "--revision",
                    "abc",
                    "--environment",
                    "macos",
                    "--cache-state",
                    "warm",
                    "--workload-label",
                    "default",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("exit_codes[1] must be an integer", result.stderr)

    def test_from_hyperfine_rejects_length_mismatch(self) -> None:
        export = {"results": [{"command": "x", "times": [1.0, 1.1], "exit_codes": [0]}]}
        with tempfile.TemporaryDirectory() as directory:
            export_path = Path(directory) / "hyperfine.json"
            export_path.write_text(json.dumps(export), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "from-hyperfine",
                    "--input",
                    str(export_path),
                    "--command",
                    "x",
                    "--revision",
                    "abc",
                    "--environment",
                    "macos",
                    "--cache-state",
                    "warm",
                    "--workload-label",
                    "default",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "hyperfine result.times and exit_codes must be the same length",
            result.stderr,
        )


if __name__ == "__main__":
    unittest.main()
