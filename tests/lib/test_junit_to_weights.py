from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "junit_to_weights.py"


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        text=True,
        capture_output=True,
        check=False,
    )


def write(directory: Path, name: str, content: str) -> str:
    path = directory / name
    path.write_text(content, encoding="utf-8")
    return str(path)


SUITE_XML = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites time="6.500">
<testsuite name="a.bats" tests="1" failures="0" errors="0" skipped="0" time="1.500">
    <testcase classname="a.bats" name="t" time="1.500" />
</testsuite>
<testsuite name="b.bats" tests="1" failures="0" errors="0" skipped="0" time="5.000">
    <testcase classname="b.bats" name="t" time="5.000" />
</testsuite>
</testsuites>
"""


class MultiFileOrderingTest(unittest.TestCase):
    def test_multi_file_produces_ordered_weighted_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            report = write(directory, "report.xml", SUITE_XML)
            result = run_cli(report)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "b.bats\t5.00\na.bats\t1.50\n")


class ShardMergeTest(unittest.TestCase):
    def test_shard_reports_merge_without_duplicate_rows(self) -> None:
        shard_one = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites time="2.000">
<testsuite name="a.bats" tests="1" failures="0" errors="0" skipped="0" time="2.000">
    <testcase classname="a.bats" name="t" time="2.000" />
</testsuite>
</testsuites>
"""
        shard_two = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites time="3.000">
<testsuite name="c.bats" tests="1" failures="0" errors="0" skipped="0" time="3.000">
    <testcase classname="c.bats" name="t" time="3.000" />
</testsuite>
</testsuites>
"""
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            report_one = write(directory, "shard-1.xml", shard_one)
            report_two = write(directory, "shard-2.xml", shard_two)
            result = run_cli(report_one, report_two)
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = result.stdout.splitlines()
            self.assertEqual(rows, ["c.bats\t3.00", "a.bats\t2.00"])
            self.assertEqual(len(rows), len({row.split("\t")[0] for row in rows}))

    def test_header_from_existing_weights_file_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            report = write(directory, "report.xml", SUITE_XML)
            existing = write(
                directory,
                "shard-weights.tsv",
                "# header line one\n# header line two\na.bats\t9.99\n",
            )
            result = run_cli(report, "--header-from", existing)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout,
                "# header line one\n# header line two\nb.bats\t5.00\na.bats\t1.50\n",
            )


class FailureModeTest(unittest.TestCase):
    def test_malformed_xml_fails_loudly(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            report = write(directory, "broken.xml", "<testsuites><testsuite")
            result = run_cli(report)
            self.assertEqual(result.returncode, 1)
            self.assertIn("not valid XML", result.stderr)

    def test_missing_time_attribute_fails_loudly(self) -> None:
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites time="1.000">
<testsuite name="a.bats" tests="1" failures="0" errors="0" skipped="0">
    <testcase classname="a.bats" name="t" time="1.000" />
</testsuite>
</testsuites>
"""
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            report = write(directory, "no-time.xml", xml)
            result = run_cli(report)
            self.assertEqual(result.returncode, 1)
            self.assertIn("missing 'time'", result.stderr)


if __name__ == "__main__":
    unittest.main()
