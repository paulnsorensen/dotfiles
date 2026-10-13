"""Shared errors, JSON output, and state paths for the harness-climb commands."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import hc_git


class InputError(ValueError):
    """The caller gave input the contract rejects."""


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def read_json(path: Path, default: Any) -> Any:
    """Parsed JSON from `path`, or `default` when the file is absent."""
    return json.loads(path.read_text()) if path.is_file() else default


def repo_root(arg: str | None) -> Path:
    if arg:
        return Path(arg).resolve()
    return Path(hc_git.git_out(".", "rev-parse", "--show-toplevel"))


def state_root(args: argparse.Namespace, repo: Path) -> Path:
    return Path(args.state_dir).resolve() if args.state_dir else repo / ".harness-climb"


def round_dir(root: Path, thread: str, rnd: int) -> Path:
    return root / thread / "rounds" / f"r{rnd}"


def stop_reason(root: Path, thread: str) -> str | None:
    stop = root / thread / "STOP"
    if not stop.is_file():
        return None
    lines = stop.read_text().splitlines()
    return lines[0] if lines else ""


def stopped(args: argparse.Namespace, repo: Path) -> bool:
    reason = stop_reason(state_root(args, repo), args.thread)
    if reason is None:
        return False
    emit({"status": "stopped", "reason": reason})
    return True
