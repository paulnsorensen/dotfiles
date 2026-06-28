"""Apply a compiled manifest to live target roots and reconcile removals.

``ap compile`` writes ``<cache>/manifest.json`` plus harness-scoped fragment
directories. This module copies each managed *generated* fragment to its
target's resolved root and deletes generated files recorded in the prior apply
state that are absent from the new manifest.

Deletion is strictly bounded: only paths recorded in the prior
:class:`~agent_profile.compiled_types.ApplyState` are ever removed. Files the
apply state does not track — including user-owned merged settings — are never
touched here. Whole-file merge preservation is a separate concern.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from agent_profile.compiled_types import ApplyState
from agent_profile.merged_settings_preservation import is_user_owned_merged

DEFAULT_STATE_FILENAME = "apply-state.json"


class ApplyError(Exception):
    """A handled ``ap apply-compiled`` failure."""


@dataclass(frozen=True)
class ApplyResult:
    """Outcome of one ``apply_compiled`` run."""

    copied: tuple[str, ...]
    deleted: tuple[str, ...]
    state_path: Path
    state: ApplyState


def read_apply_state(state_path: Path) -> ApplyState:
    """Read prior apply state; an absent file means nothing was managed yet."""
    state_path = Path(state_path)
    if not state_path.exists():
        return ApplyState()
    try:
        raw = json.loads(state_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ApplyError(
            f"ap apply-compiled: cannot read apply state {state_path}: {exc}"
        ) from exc
    managed = raw.get("managed_files", []) if isinstance(raw, dict) else None
    if not isinstance(managed, list) or not all(isinstance(p, str) for p in managed):
        raise ApplyError(
            f"ap apply-compiled: apply state {state_path} has invalid managed_files"
        )
    return ApplyState(managed_files=tuple(managed))


def write_apply_state(state_path: Path, state: ApplyState) -> None:
    state_path = Path(state_path)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state.to_dict(), indent=2, sort_keys=True) + "\n")


def _read_manifest(manifest_path: Path) -> dict[str, Any]:
    if not manifest_path.is_file():
        raise ApplyError(f"ap apply-compiled: manifest '{manifest_path}' not found")
    try:
        data = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ApplyError(
            f"ap apply-compiled: cannot read manifest {manifest_path}: {exc}"
        ) from exc
    if not isinstance(data, dict):
        raise ApplyError(f"ap apply-compiled: manifest {manifest_path} is not an object")
    return data


def _target_roots(data: dict[str, Any]) -> dict[str, Path]:
    targets = data.get("compile_targets")
    if not isinstance(targets, list):
        raise ApplyError("ap apply-compiled: manifest compile_targets must be a list")
    roots: dict[str, Path] = {}
    for target in targets:
        if not isinstance(target, dict):
            raise ApplyError("ap apply-compiled: each compile target must be an object")
        name = target.get("name")
        resolved = target.get("resolved_root")
        if not isinstance(name, str) or not name:
            raise ApplyError("ap apply-compiled: compile target missing name")
        if not isinstance(resolved, str) or not resolved:
            raise ApplyError(
                f"ap apply-compiled: compile target '{name}' missing resolved_root"
            )
        roots[name] = Path(resolved)
    return roots


def _managed_pairs(
    data: dict[str, Any], roots: dict[str, Path]
) -> list[tuple[Path, Path]]:
    """Return ``(fragment_path, dest_path)`` for each managed generated file.

    Non-generated entries (whole merged files) are skipped — merging and
    preservation of user-owned settings is owned elsewhere.
    """
    files = data.get("files")
    if not isinstance(files, list):
        raise ApplyError("ap apply-compiled: manifest files must be a list")
    pairs: list[tuple[Path, Path]] = []
    for entry in files:
        if not isinstance(entry, dict):
            raise ApplyError("ap apply-compiled: each manifest file must be an object")
        if not entry.get("generated", True):
            continue
        target = entry.get("target")
        fragment = entry.get("fragment_path")
        relative = entry.get("relative_path")
        if target not in roots:
            raise ApplyError(
                f"ap apply-compiled: file references unknown target '{target}'"
            )
        if not isinstance(fragment, str) or not fragment:
            raise ApplyError("ap apply-compiled: manifest file missing fragment_path")
        if not isinstance(relative, str) or not relative:
            raise ApplyError("ap apply-compiled: manifest file missing relative_path")
        pairs.append((Path(fragment), roots[target] / relative))
    return pairs


def _preserved_dests(data: dict[str, Any], roots: dict[str, Path]) -> set[str]:
    """Resolved destination paths of user-owned merged settings to never delete.

    A merged settings file previously applied as generated (clobber-copy) but
    now marked ``generated=False`` would otherwise be reconciled out of the
    prior apply state and deleted — destroying user content (ADR-001/spec 92).
    """
    preserved: set[str] = set()
    for entry in data.get("files", []):
        if not isinstance(entry, dict) or not is_user_owned_merged(entry):
            continue
        target = entry.get("target")
        relative = entry.get("relative_path")
        if target in roots and isinstance(relative, str):
            preserved.add(str(roots[target] / relative))
    return preserved


def apply_compiled(
    manifest_path: Path, *, state_path: Path | None = None
) -> ApplyResult:
    """Copy managed fragments to resolved roots and reconcile removals.

    ``state_path`` defaults to ``apply-state.json`` beside the manifest, the
    stable per-source/profile cache location ``dots sync`` reuses each run.
    """
    manifest_path = Path(manifest_path)
    state_path = (
        manifest_path.parent / DEFAULT_STATE_FILENAME
        if state_path is None
        else Path(state_path)
    )

    data = _read_manifest(manifest_path)
    roots = _target_roots(data)
    pairs = _managed_pairs(data, roots)
    preserved = _preserved_dests(data, roots)
    prior = read_apply_state(state_path)

    copied: list[str] = []
    managed: set[str] = set()
    for fragment, dest in pairs:
        if not fragment.is_file():
            raise ApplyError(f"ap apply-compiled: fragment '{fragment}' is missing")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(fragment, dest)
        copied.append(str(dest))
        managed.add(str(dest))

    deleted: list[str] = []
    for prior_path in prior.managed_files:
        if prior_path in managed or prior_path in preserved:
            continue
        path = Path(prior_path)
        if path.is_file():
            path.unlink()
            deleted.append(prior_path)

    new_state = ApplyState(managed_files=tuple(sorted(managed)))
    write_apply_state(state_path, new_state)

    return ApplyResult(
        copied=tuple(copied),
        deleted=tuple(deleted),
        state_path=state_path,
        state=new_state,
    )


def cmd_apply_compiled(args: list[str], out_stream: Any) -> int:
    if not args:
        raise ApplyError("Usage: ap apply-compiled <manifest>")
    if len(args) > 1:
        raise ApplyError(f"ap apply-compiled: unexpected argument '{args[1]}'")
    result = apply_compiled(Path(args[0]))
    print(
        f"applied {len(result.copied)} file(s), removed {len(result.deleted)}",
        file=out_stream,
    )
    return 0
