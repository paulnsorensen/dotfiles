"""Gate files: the schema, the reader, the writer, and the validator."""

from __future__ import annotations

import json
import math
import re
from pathlib import Path
from typing import Any

import hc_git
from hc_stats import GUARD_COMPOSITE_VERSION

GATE_DIR = "harness-climb/gates"
GATE_DEFAULTS: dict[str, Any] = {
    "guard_composite_version": GUARD_COMPOSITE_VERSION,
    "min_sessions": 20,
    "soak_days": 7,
    "sync_grace_days": 2,
    "token_per_gain": 1.0,
    "direction": "lower",
}
DIRECTIONS = ("lower", "higher")
GATE_REQUIRED = ("thread", "round", "component", "targeted_query")
_GATE_PATH = re.compile(rf"^{re.escape(GATE_DIR)}/(.+)-r(\d+)\.json$")


def gate_path(thread: str, rnd: int) -> str:
    return f"{GATE_DIR}/{thread}-r{rnd}.json"


def parse_gate_path(path: str) -> tuple[str, int] | None:
    """The (thread, round) that a gate path names, or None. It inverts `gate_path`."""
    match = _GATE_PATH.match(path)
    return (match.group(1), int(match.group(2))) if match else None


def normalize_gate(raw: dict[str, Any]) -> dict[str, Any]:
    missing = [k for k in GATE_REQUIRED if k not in raw]
    if missing:
        raise ValueError(f"gate file lacks {', '.join(missing)}")
    gate = {**GATE_DEFAULTS, **raw}
    if gate["direction"] not in DIRECTIONS:
        raise ValueError("gate direction must be lower or higher")
    if not isinstance(gate["min_sessions"], int) or gate["min_sessions"] < 2:
        raise ValueError("gate min_sessions must be an integer of at least 2")
    for key in ("soak_days", "sync_grace_days", "token_per_gain"):
        value = gate[key]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value < 0
        ):
            raise ValueError(f"gate {key} must be a finite non-negative number")
    if gate["soak_days"] <= 0:
        raise ValueError("gate soak_days must be positive")
    return gate


def read_gate_at(repo: str | Path, rev: str, path: str) -> dict[str, Any]:
    """Read a gate file from a commit tree, never from the working tree."""
    proc = hc_git.git(repo, "show", f"{rev}:{path}", check=False)
    if proc.returncode != 0:
        raise hc_git.GitError(f"gate file {path} not found in {rev}")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise hc_git.GitError(f"gate file {path} in {rev} is not JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise hc_git.GitError(f"gate file {path} in {rev} is not an object")
    return data


def write_gate(repo: Path, gate: dict[str, Any]) -> str:
    """Write the gate file into the working tree. Returns its repo-relative path."""
    rel = gate_path(gate["thread"], gate["round"])
    target = repo / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(gate, indent=2, sort_keys=True) + "\n")
    return rel


def gate_merge(repo: str | Path, ref: str, gate_file: str) -> tuple[str, int] | None:
    """The first-parent commit on `ref` that added `gate_file`, with its commit time.

    A re-added gate file resolves to its newest add. Only history reachable from
    `ref` counts, so an unmerged branch commit never resolves.
    """
    log = hc_git.git_out(
        repo, "log", "--first-parent", "--diff-filter=A", "--format=%H %ct",
        "-n", "1", ref, "--", gate_file,
    )  # fmt: skip
    if not log.strip():
        return None
    sha, ctime = log.split()
    return sha, int(ctime)
