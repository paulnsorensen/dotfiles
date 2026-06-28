"""Compute grouped drift between baseline, live, and compiled config.

Pure module: given per-file comparisons (the scratch chezmoi baseline file,
the live target file, and the compiled fragment), report every key/path where
the three sources disagree. The caller (``dots sync`` / ``ap compile`` wiring)
supplies the resolved paths and decides whether reported drift blocks apply.

``DriftRecord.baseline``/``.live``/``.compiled`` use ``None`` for "not present"
— an absent file, an absent key, or an explicit JSON ``null`` all collapse to
``None``. These settings files do not use explicit nulls, so the conflation is
harmless and keeps records JSON-serializable for the ``--json`` caller.

A wholly-absent *live* file is a clean create, not drift, so it yields no
records; baseline/compiled absence is reported (the live file diverges from a
source that has nothing, or everything, to say).
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from agent_profile.compiled_types import DriftRecord


class DriftError(Exception):
    """A handled drift-computation failure (e.g. unparseable JSON)."""


# Sentinel distinguishing "file absent on disk" from "file present, value null".
_ABSENT_FILE = object()


@dataclass(frozen=True)
class FileComparison:
    """One settings/merged file to drift-check across three sources.

    ``relative_path`` is the file's path under its target root (e.g.
    ``.claude/settings.json``); a ``.json`` suffix selects key-level diffing,
    anything else is compared as whole-file text.
    """

    target: str
    relative_path: str
    baseline: Path | None
    live: Path | None
    compiled: Path | None


def compute_drift(comparisons: Iterable[FileComparison]) -> list[DriftRecord]:
    """Return drift records for every key/path the three sources disagree on.

    Records are sorted by ``(target, relative_path, path)`` for deterministic
    output and stable grouping.
    """
    records: list[DriftRecord] = []
    for comparison in comparisons:
        records.extend(_diff_file(comparison))
    records.sort(key=lambda r: (r.target, r.relative_path, r.path))
    return records


def format_drift(records: Sequence[DriftRecord]) -> str:
    """Render drift records as a grouped human diff: target → file → key/path.

    Returns an empty string when there is no drift, so callers can branch on
    truthiness.
    """
    if not records:
        return ""
    ordered = sorted(records, key=lambda r: (r.target, r.relative_path, r.path))
    lines: list[str] = []
    current: tuple[str, str] | None = None
    for record in ordered:
        group = (record.target, record.relative_path)
        if group != current:
            if current is not None:
                lines.append("")
            lines.append(f"{record.target}  {record.relative_path}")
            current = group
        lines.append(f"  {record.path or '(whole file)'}")
        lines.append(f"    baseline: {_render(record.baseline)}")
        lines.append(f"    live:     {_render(record.live)}")
        lines.append(f"    compiled: {_render(record.compiled)}")
    return "\n".join(lines) + "\n"


def _diff_file(comparison: FileComparison) -> list[DriftRecord]:
    is_json = comparison.relative_path.endswith(".json")
    live = _read(comparison.live, is_json)
    if live is _ABSENT_FILE:
        return []
    baseline = _read(comparison.baseline, is_json)
    compiled = _read(comparison.compiled, is_json)

    base_leaves = _leaves(baseline)
    live_leaves = _leaves(live)
    comp_leaves = _leaves(compiled)

    keys = set(base_leaves) | set(live_leaves) | set(comp_leaves)
    records: list[DriftRecord] = []
    for key in sorted(keys):
        base_leaf = base_leaves.get(key)
        live_leaf = live_leaves.get(key)
        comp_leaf = comp_leaves.get(key)
        if base_leaf == live_leaf == comp_leaf:
            continue
        records.append(
            DriftRecord(
                target=comparison.target,
                relative_path=comparison.relative_path,
                path=key,
                baseline=base_leaf,
                live=live_leaf,
                compiled=comp_leaf,
            )
        )
    return records


def _read(path: Path | None, is_json: bool) -> Any:
    if path is None or not path.exists():
        return _ABSENT_FILE
    text = path.read_text()
    if not is_json:
        return text
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise DriftError(f"{path}: invalid JSON ({exc.msg})") from exc


def _leaves(value: Any) -> dict[str, Any]:
    """Flatten a value into ``{dotted_path: leaf}``.

    Non-empty dicts recurse; lists, scalars, and empty dicts are leaves. An
    absent file contributes nothing. A non-dict root (or text content) becomes
    a single leaf at the empty path.
    """
    if value is _ABSENT_FILE:
        return {}
    out: dict[str, Any] = {}
    _walk(value, "", out)
    return out


def _walk(value: Any, prefix: str, out: dict[str, Any]) -> None:
    if isinstance(value, dict) and value:
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else str(key)
            _walk(child, child_prefix, out)
    else:
        out[prefix] = value


def _render(value: Any) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False)
