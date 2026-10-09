"""Gate files: the schema, the reader, the writer, and the validator."""

from __future__ import annotations

import json
import math
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
GATE_REQUIRED = ("thread", "round", "component", "targeted_query")


def gate_path(thread: str, rnd: int) -> str:
    return f"{GATE_DIR}/{thread}-r{rnd}.json"


def normalize_gate(raw: dict[str, Any]) -> dict[str, Any]:
    missing = [k for k in GATE_REQUIRED if k not in raw]
    if missing:
        raise ValueError(f"gate file lacks {', '.join(missing)}")
    gate = {**GATE_DEFAULTS, **raw}
    if gate["direction"] not in ("lower", "higher"):
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
