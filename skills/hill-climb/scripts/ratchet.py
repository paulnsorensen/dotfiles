#!/usr/bin/env python3
"""Record, check, and tighten ratchet thresholds for deterministic metrics.

A ratchet threshold moves only in the improving direction. The `check`
command is the ratchet gate: CI runs it and fails on any regression.
Loosening a threshold is a human edit to the ratchet file, never a command.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from statistics import median
from typing import Any

SCHEMA_VERSION = 1
DIRECTIONS = ("lower", "higher")
METRIC_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")

PASS = 0
GATE_FAILURE = 1
INPUT_ERROR = 2

DEFAULT_TIMEOUT = 600.0
NEW_FILE_MODE = 0o644


class InputError(ValueError):
    """Input does not satisfy the ratchet contract."""


def _number(text: str, label: str) -> int | float:
    try:
        value: int | float = int(text)
    except ValueError:
        try:
            value = float(text)
        except ValueError:
            raise InputError(f"{label}: {text!r} is not a number") from None
    if isinstance(value, float) and not math.isfinite(value):
        raise InputError(f"{label}: {text!r} is not finite")
    return value


def _metric_name(name: str) -> str:
    if not METRIC_NAME.match(name):
        raise InputError(f"metric name {name!r} must match {METRIC_NAME.pattern}")
    return name


def _tolerance(value: float) -> float:
    if not 0 <= value < 1:
        raise InputError(f"tolerance {value} must be in [0, 1)")
    return value


def _pairs(raw: list[str]) -> dict[str, int | float]:
    values: dict[str, int | float] = {}
    for item in raw:
        name, sep, text = item.partition("=")
        if not sep:
            raise InputError(f"--value {item!r} must be NAME=NUMBER")
        name = _metric_name(name)
        if name in values:
            raise InputError(f"--value repeats metric {name!r}")
        values[name] = _number(text, f"--value {name}")
    if not values:
        raise InputError("at least one --value NAME=NUMBER is required")
    return values


def _validate(data: Any, path: Path) -> dict[str, Any]:
    if not isinstance(data, dict) or data.get("version") != SCHEMA_VERSION:
        raise InputError(f"{path}: expected an object with version {SCHEMA_VERSION}")
    metrics = data.get("metrics")
    if not isinstance(metrics, dict):
        raise InputError(f"{path}: metrics must be an object")
    for name, entry in metrics.items():
        label = f"{path}: metrics.{name}"
        _metric_name(name)
        if not isinstance(entry, dict):
            raise InputError(f"{label} must be an object")
        if entry.get("direction") not in DIRECTIONS:
            raise InputError(
                f"{label}.direction must be one of {', '.join(DIRECTIONS)}"
            )
        threshold = entry.get("threshold")
        if isinstance(threshold, bool) or not isinstance(threshold, (int, float)):
            raise InputError(f"{label}.threshold must be a number")
        if not math.isfinite(threshold):
            raise InputError(f"{label}.threshold must be finite")
        tolerance = entry.get("tolerance", 0)
        if isinstance(tolerance, bool) or not isinstance(tolerance, (int, float)):
            raise InputError(f"{label}.tolerance must be a number")
        _tolerance(tolerance)
    return data


def _load(path: Path, *, create: bool = False) -> dict[str, Any]:
    if create and not path.exists():
        return {"version": SCHEMA_VERSION, "metrics": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise InputError(f"{path}: ratchet file not found") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise InputError(f"{path}: cannot read ratchet file: {exc}") from None
    except json.JSONDecodeError as exc:
        raise InputError(f"{path}: invalid JSON: {exc}") from None
    return _validate(data, path)


def _save(data: dict[str, Any], path: Path) -> None:
    text = json.dumps(data, indent=2, sort_keys=True) + "\n"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else NEW_FILE_MODE
        fd, tmp = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
        )
    except OSError as exc:
        raise InputError(f"{path}: cannot write ratchet file: {exc}") from None
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except OSError as exc:
        Path(tmp).unlink(missing_ok=True)
        raise InputError(f"{path}: cannot write ratchet file: {exc}") from None
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _better(direction: str, value: float, threshold: float) -> bool:
    return value < threshold if direction == "lower" else value > threshold


def _limit(entry: dict[str, Any]) -> float:
    threshold = entry["threshold"]
    slack = abs(threshold) * entry.get("tolerance", 0)
    return threshold + slack if entry["direction"] == "lower" else threshold - slack


def _verdict(entry: dict[str, Any], value: float) -> str:
    direction = entry["direction"]
    limit = _limit(entry)
    if _better(direction, limit, value):
        return "regressed"
    if _better(direction, value, entry["threshold"]):
        return "improved"
    return "pass"


def _known_values(
    path: Path, metrics: dict[str, Any], raw: list[str]
) -> dict[str, int | float]:
    values = _pairs(raw)
    unknown = sorted(set(values) - set(metrics))
    if unknown:
        raise InputError(f"{path}: unknown metric(s): {', '.join(unknown)}")
    return values


def cmd_add(args: argparse.Namespace) -> int:
    path = Path(args.file)
    data = _load(path, create=True)
    name = _metric_name(args.metric)
    if name in data["metrics"]:
        raise InputError(f"{path}: metric {name!r} already exists; use tighten")
    entry: dict[str, Any] = {
        "direction": args.direction,
        "threshold": _number(args.value, "--value"),
        "tolerance": _tolerance(args.tolerance),
    }
    for key in ("unit", "command", "revision"):
        if getattr(args, key):
            entry[key] = getattr(args, key)
    data["metrics"][name] = entry
    _save(data, path)
    print(json.dumps({"added": name, **entry}, sort_keys=True))
    return PASS


def cmd_check(args: argparse.Namespace) -> int:
    path = Path(args.file)
    metrics = _load(path)["metrics"]
    values = _known_values(path, metrics, args.value)
    results = []
    for name in sorted(metrics):
        entry = metrics[name]
        if name not in values:
            if not args.partial:
                results.append({"metric": name, "status": "missing"})
            continue
        results.append(
            {
                "metric": name,
                "status": _verdict(entry, values[name]),
                "value": values[name],
                "threshold": entry["threshold"],
                "limit": _limit(entry),
                "direction": entry["direction"],
            }
        )
    failed = [r for r in results if r["status"] in ("regressed", "missing")]
    print(
        json.dumps({"pass": not failed, "results": results}, indent=2, sort_keys=True)
    )
    return GATE_FAILURE if failed else PASS


def cmd_tighten(args: argparse.Namespace) -> int:
    path = Path(args.file)
    data = _load(path)
    metrics = data["metrics"]
    values = _known_values(path, metrics, args.value)
    results = []
    refused = False
    for name, value in sorted(values.items()):
        entry = metrics[name]
        before = entry["threshold"]
        if _better(entry["direction"], value, before):
            status = "tightened"
        elif value == before:
            status = "unchanged"
        else:
            status = "refused"
            refused = True
        results.append({"metric": name, "status": status, "from": before, "to": value})
    tightened = [r for r in results if r["status"] == "tightened"]
    written = bool(tightened) and not refused
    if written:
        for result in tightened:
            entry = metrics[result["metric"]]
            entry["threshold"] = result["to"]
            if args.revision:
                entry["revision"] = args.revision
        _save(data, path)
    print(
        json.dumps({"written": written, "results": results}, indent=2, sort_keys=True)
    )
    return GATE_FAILURE if refused else PASS


def _print_failed_run(run: int, detail: dict[str, Any]) -> None:
    report = {"deterministic": False, "failed_run": run, **detail}
    print(json.dumps(report, indent=2, sort_keys=True))


def cmd_measure(args: argparse.Namespace) -> int:
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise InputError("measure requires a command after --")
    if args.runs < 1:
        raise InputError("--runs must be at least 1")
    if not args.timeout > 0:
        raise InputError("--timeout must be greater than 0")
    tolerance = _tolerance(args.tolerance)
    values: list[int | float] = []
    for run in range(1, args.runs + 1):
        try:
            proc = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
                timeout=args.timeout,
            )
        except subprocess.TimeoutExpired:
            _print_failed_run(run, {"error": "timeout", "timeout": args.timeout})
            return GATE_FAILURE
        except OSError as exc:
            raise InputError(f"cannot run {command[0]!r}: {exc}") from None
        if proc.returncode != 0:
            _print_failed_run(
                run,
                {
                    "error": "command-failed",
                    "exit": proc.returncode,
                    "stderr": proc.stderr[-2000:],
                },
            )
            return GATE_FAILURE
        lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
        if not lines:
            raise InputError(f"run {run}: command printed no number")
        values.append(_number(lines[-1], f"run {run} output"))
    low, high, mid = min(values), max(values), median(values)
    spread = 0.0 if high == low else (high - low) / abs(mid) if mid else math.inf
    deterministic = spread <= tolerance
    report = {
        "deterministic": deterministic,
        "runs": len(values),
        "values": values,
        "min": low,
        "max": high,
        "median": mid,
        "spread": spread if math.isfinite(spread) else None,
        "tolerance": tolerance,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return PASS if deterministic else GATE_FAILURE


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ratchet", description=__doc__.splitlines()[0]
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    add = sub.add_parser("add", help="record a new metric and its first threshold")
    add.add_argument("--file", required=True)
    add.add_argument("--metric", required=True)
    add.add_argument("--direction", required=True, choices=DIRECTIONS)
    add.add_argument("--value", required=True)
    add.add_argument("--tolerance", type=float, default=0.0)
    add.add_argument("--unit")
    add.add_argument("--command", help="the command that prints the metric")
    add.add_argument("--revision")
    add.set_defaults(func=cmd_add)

    check = sub.add_parser("check", help="ratchet gate: fail on any regression")
    check.add_argument("--file", required=True)
    check.add_argument("--value", action="append", default=[], metavar="NAME=NUMBER")
    check.add_argument(
        "--partial", action="store_true", help="allow metrics without a value"
    )
    check.set_defaults(func=cmd_check)

    tighten = sub.add_parser("tighten", help="move thresholds to better values only")
    tighten.add_argument("--file", required=True)
    tighten.add_argument("--value", action="append", default=[], metavar="NAME=NUMBER")
    tighten.add_argument("--revision")
    tighten.set_defaults(func=cmd_tighten)

    measure = sub.add_parser(
        "measure", help="run a metric command N times and test determinism"
    )
    measure.add_argument("--runs", type=int, default=5)
    measure.add_argument("--tolerance", type=float, default=0.0)
    measure.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help="seconds allowed per run (default %(default)s)",
    )
    measure.add_argument("command", nargs=argparse.REMAINDER)
    measure.set_defaults(func=cmd_measure)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return args.func(args)
    except InputError as exc:
        print(f"ratchet: {exc}", file=sys.stderr)
        return INPUT_ERROR


if __name__ == "__main__":
    sys.exit(main())
