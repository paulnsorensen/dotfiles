"""The field gate: a verdict for a merged round, read from its merge commit."""

from __future__ import annotations

import argparse
import json
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

import hc_gate
import hc_git
import hc_stats
from hc_core import emit, repo_root
from hc_db import RefreshFailed, VersionUnavailable, load_rows, resolve_db


def _both(reason: str, **extra: Any) -> dict[str, Any]:
    inconclusive = {"verdict": hc_stats.INCONCLUSIVE, "reason": reason}
    return {
        "harnesses": {h: dict(inconclusive) for h in hc_stats.HARNESSES},
        "candidate": hc_stats.INCONCLUSIVE,
        **extra,
    }


def _early_verdict(
    out: dict[str, Any],
    gate: dict[str, Any],
    sync: tuple[int, str] | None,
    grace_end: float,
    now: float,
) -> dict[str, Any] | None:
    """A verdict that timing alone settles, or None when the soak window is over."""
    if sync is None:
        if now <= grace_end:
            return {**out, "status": "not-due", "due": grace_end}
        return {**out, **_both("sync-late")}
    after_start = float(sync[0])
    if after_start > grace_end:
        return {**out, **_both("sync-late")}
    due = after_start + gate["soak_days"] * hc_stats.DAY
    if now < due:
        return {**out, "status": "not-due", "due": due}
    return None


def _judge_rows(
    out: dict[str, Any],
    gate: dict[str, Any],
    rows: list[dict[str, Any]] | None,
    db: Callable[[], Path],
    after_start: float,
) -> dict[str, Any]:
    if rows is None:
        try:
            path = db()
        except RefreshFailed:
            return {**out, **_both("db-stale")}
        if not path.is_file():
            return {**out, "status": "no-db"}
        soak = gate["soak_days"] * hc_stats.DAY
        try:
            rows = load_rows(path, gate, after_start - 2 * soak, after_start + soak)
        except VersionUnavailable:
            return {**out, **_both("version-unavailable")}
    per = {
        h: hc_stats.evaluate_harness(h, gate, rows, after_start)
        for h in hc_stats.HARNESSES
    }
    candidate = hc_stats.combine(r["verdict"] for r in per.values())
    action = "open-revert-pr" if candidate == hc_stats.REVERT else out["action"]
    return {**out, "harnesses": per, "candidate": candidate, "action": action}


def field_gate(
    repo: Path,
    thread: str,
    rnd: int,
    merge: str,
    history_text: str,
    rows: list[dict[str, Any]] | None,
    now: float,
    db: Callable[[], Path] = resolve_db,
) -> dict[str, Any]:
    """Verdict dict. Reads settings from the merge commit and mutates nothing.

    `db` resolves the database only when the verdict needs rows.
    """
    gate = hc_gate.normalize_gate(
        hc_gate.read_gate_at(repo, merge, hc_gate.gate_path(thread, rnd))
    )
    out: dict[str, Any] = {
        "status": "ok",
        "thread": thread,
        "round": rnd,
        "merge": merge,
        "gate": gate,
        "action": "none",
    }
    if gate["guard_composite_version"] not in hc_stats.GUARD_COMPOSITE:
        return {**out, **_both("guard-version-unknown")}
    history = hc_git.parse_sync_history(history_text)
    sync = hc_git.first_sync_containing(repo, merge, history)
    if sync is not None:
        out["sync"] = {"epoch": sync[0], "sha": sync[1]}
    grace = gate["sync_grace_days"] * hc_stats.DAY
    grace_end = hc_git.commit_time(repo, merge) + grace
    early = _early_verdict(out, gate, sync, grace_end, now)
    if early is not None:
        return early
    after_start = float(sync[0])
    soak = gate["soak_days"] * hc_stats.DAY
    if hc_git.has_regressing_sync(
        repo, merge, history, after_start, after_start + soak
    ):
        return {**out, **_both("sync-regressed")}
    return _judge_rows(out, gate, rows, db, after_start)


def cmd_field_gate(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    history = Path(args.history) if args.history else hc_git.default_history_path()
    history_text = history.read_text() if history.is_file() else ""
    rows = json.loads(Path(args.rows).read_text()) if args.rows else None
    now = args.now if args.now is not None else time.time()
    result = field_gate(
        repo,
        args.thread,
        args.round,
        args.merge,
        history_text,
        rows,
        now,
        resolve_db,
    )
    emit(result)
    return 0 if result["status"] in ("ok", "not-due") else 1
