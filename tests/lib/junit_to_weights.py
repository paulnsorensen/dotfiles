#!/usr/bin/env python3
"""Convert Bats JUnit reports into tests/shard-weights.tsv rows.

Bats' JUnit reporter (`--report-formatter junit --output DIR`) writes one
<testsuite> per bats file, whose `time` attribute sums that file's test
durations. That is real per-file CPU cost, and it stays correct under
`bats --jobs N`, so it is exactly the weight tests/lib/shard.sh wants.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


class JUnitFormatError(ValueError):
    """A JUnit report file does not have the shape a weights row needs."""


def parse_weights(paths: list[str]) -> dict[str, float]:
    """Merge per-file Bats durations from one or more JUnit reports.

    Later paths win on a basename collision, so the result never holds
    duplicate rows even when several shard reports are given together.
    """
    weights: dict[str, float] = {}
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            raise JUnitFormatError(f"{path}: not valid XML ({exc})") from exc
        for suite in root.iter("testsuite"):
            name = suite.get("name")
            if not name:
                raise JUnitFormatError(f"{path}: <testsuite> missing 'name'")
            time_value = suite.get("time")
            if time_value is None:
                raise JUnitFormatError(
                    f"{path}: <testsuite name={name!r}> missing 'time'"
                )
            try:
                seconds = float(time_value)
            except ValueError as exc:
                raise JUnitFormatError(
                    f"{path}: <testsuite name={name!r}> has non-numeric "
                    f"time {time_value!r}"
                ) from exc
            weights[Path(name).name] = seconds
    return weights


def format_weights(weights: dict[str, float], header: list[str]) -> str:
    """Render weights as a shard-weights.tsv document, heaviest file first."""
    rows = sorted(weights.items(), key=lambda item: (-item[1], item[0]))
    lines = list(header)
    lines.extend(f"{name}\t{seconds:.2f}" for name, seconds in rows)
    return "\n".join(lines) + "\n"


def read_header(path: str | None) -> list[str]:
    """Return the leading '#' comment lines of an existing weights file."""
    if path is None:
        return []
    header: list[str] = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.startswith("#"):
            break
        header.append(line)
    return header


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "reports",
        nargs="+",
        help="JUnit XML file(s) from 'bats --report-formatter junit'",
    )
    parser.add_argument(
        "--header-from",
        help="existing weights TSV to copy the '#' comment header from",
    )
    parser.add_argument("--output", help="write the TSV here instead of stdout")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        weights = parse_weights(args.reports)
        header = read_header(args.header_from)
        document = format_weights(weights, header)
    except JUnitFormatError as exc:
        print(f"junit-to-weights: {exc}", file=sys.stderr)
        return 1
    if args.output:
        Path(args.output).write_text(document, encoding="utf-8")
    else:
        sys.stdout.write(document)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
