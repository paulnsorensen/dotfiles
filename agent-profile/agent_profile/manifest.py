"""manifest.py — track files installed by each profile for surgical uninstall.

Behavioral port of agent-profile/lib/manifest.sh. The manifest lives at
``<target>/.agent-profile/manifest.json``::

    {
      "<profile>": {
        "files":       ["<rel-path>", ...],   # whole-file artifacts -> rm
        "merged_json": {...resolved manifest at install time...}
      }
    }

``files`` are removed on uninstall, but only when no *other* installed
profile also claims the same path (ref-counting for shared artefacts like
``.mcp.json``, ``opencode.json``, ``.claude/agents/<shared>.md``).
``merged_json`` is the resolved manifest passed to each renderer's
``clean`` so it can surgically undo merges even after the profile dir is
deleted.

File lists are always stored sorted + deduped (the bash uses jq
``unique``, which sorts). Corruption fails loud (parity: silent no-op on
uninstall is a correctness bug).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class ManifestCorrupt(Exception):
    """Raised when the on-disk manifest is missing/malformed. Message
    matches the ``ap: manifest at <path> is corrupt: <reason>`` shape the
    bash emits to stderr before exiting 1."""


def manifest_path(target: Path) -> Path:
    return Path(str(target).rstrip("/")) / ".agent-profile/manifest.json"


def _validate(path: Path) -> None:
    """Validate the manifest parses and is shaped sanely. Non-existent
    file is a no-op. Port of ``_ap_manifest_validate``."""
    if not path.is_file():
        return
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        raise ManifestCorrupt(
            f"ap: manifest at {path} is corrupt: not valid JSON"
        )
    if not isinstance(data, dict):
        kind = _json_type(data)
        raise ManifestCorrupt(
            f"ap: manifest at {path} is corrupt: "
            f"top-level must be an object, got {kind}"
        )
    bad = [k for k, v in data.items() if not isinstance(v, dict)]
    if bad:
        raise ManifestCorrupt(
            f"ap: manifest at {path} is corrupt: "
            f"non-object entries for profile(s): {','.join(bad)}"
        )


def _json_type(value: Any) -> str:
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if value is None:
        return "null"
    return "object"


def _load(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    return json.loads(path.read_text())


def _dump(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n")


def manifest_init(target: Path) -> None:
    """Ensure the manifest file exists (seed ``{}``) and validate it."""
    path = manifest_path(target)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file():
        _dump(path, {})
    _validate(path)


def record_file(target: Path, profile: str, rel_path: str) -> None:
    """Add ``rel_path`` to ``profile``'s file list (sorted, deduped).

    Test-only helper: the production CLI records file lists in bulk via
    ``cli._set_files`` / ``cli._union_files`` and never calls this. Kept as
    part of the manifest module's tested public surface (per-file recording
    + ref-count assertions in ``tests/test_core.py``)."""
    manifest_init(target)
    path = manifest_path(target)
    data = _load(path)
    entry = data.setdefault(profile, {"files": []})
    files = set(entry.get("files") or [])
    files.add(rel_path)
    entry["files"] = sorted(files)
    _dump(path, data)


def files(target: Path, profile: str) -> list[str]:
    """Return ``profile``'s recorded file list (already sorted)."""
    path = manifest_path(target)
    if not path.is_file():
        return []
    _validate(path)
    return list((_load(path).get(profile) or {}).get("files") or [])


def clear(target: Path, profile: str) -> None:
    """Drop ``profile``'s entry from the manifest."""
    path = manifest_path(target)
    if not path.is_file():
        return
    _validate(path)
    data = _load(path)
    data.pop(profile, None)
    _dump(path, data)


def profiles(target: Path) -> list[str]:
    """Return all profile names recorded in the manifest."""
    path = manifest_path(target)
    if not path.is_file():
        return []
    _validate(path)
    return list(_load(path).keys())


def record_merged_json(
    target: Path, profile: str, merged_json: dict[str, Any]
) -> None:
    """Cache the resolved manifest so uninstall works after profile delete."""
    manifest_init(target)
    path = manifest_path(target)
    data = _load(path)
    entry = data.setdefault(profile, {"files": []})
    entry["merged_json"] = merged_json
    _dump(path, data)


def merged_json(target: Path, profile: str) -> dict[str, Any] | None:
    """Return the cached resolved manifest for ``profile``, or ``None``."""
    path = manifest_path(target)
    if not path.is_file():
        return None
    _validate(path)
    return (_load(path).get(profile) or {}).get("merged_json")


def other_profiles_claim_file(target: Path, profile: str, file: str) -> bool:
    """True iff a *different* recorded profile also lists ``file``.

    Drives the ref-counted uninstall decision: a shared artefact survives
    while any other profile still owns it. Port of
    ``ap_manifest_other_profiles_claim_file``.
    """
    path = manifest_path(target)
    if not path.is_file():
        return False
    _validate(path)
    data = _load(path)
    for key, value in data.items():
        if key == profile:
            continue
        if file in (value.get("files") or []):
            return True
    return False


# Path-prefix -> harness-owner classifier. Drives selective-install orphan
# detection so a `--harness claude` re-run doesn't delete files the other
# harnesses still claim. Empty list => unknown (caller preserves the file).
def _path_owners(file: str) -> list[str]:
    """Port of ``_ap_path_owners``."""
    if file.startswith(".claude/plugins/local/"):
        return ["claude"]
    # Top-level .claude/agents/<n>.md is the cross-harness shared write
    # target — claude, opencode, and cursor all write there.
    if file.startswith(".claude/agents/"):
        return ["claude", "opencode", "cursor"]
    if file.startswith(".codex/"):
        return ["codex"]
    if file.startswith(".cursor/"):
        return ["cursor"]
    if file.startswith(".opencode/"):
        return ["opencode"]
    if file.startswith(".github/"):
        return ["copilot"]
    # .agents/skills/<n>/ is shared by codex+opencode+cursor.
    if file.startswith(".agents/skills/"):
        return ["codex", "opencode", "cursor"]
    return []


def _owner_overlap(selected: list[str], owners: list[str]) -> bool:
    """True iff any selected harness is in the owner list. Empty owners =>
    False (don't claim ownership; caller preserves the file). Port of
    ``_ap_owner_overlap``."""
    if not owners:
        return False
    return any(s in owners for s in selected)


def diff_and_clean(
    target: Path,
    profile: str,
    new_files: list[str],
    selected_harnesses: list[str] | None = None,
) -> None:
    """On re-install, remove ``old_files - new_files`` from disk.

    Files still claimed by another profile are kept on disk (ref-counted).
    When ``selected_harnesses`` is given (selective install), only files
    whose path prefix maps to one of those harnesses are orphan
    candidates. Port of ``ap_manifest_diff_and_clean``.

    Safe to call when no prior install exists (no-op).
    """
    path = manifest_path(target)
    if not path.is_file():
        return
    _validate(path)
    data = _load(path)

    old = (data.get(profile) or {}).get("files") or []
    new_set = set(new_files)
    dropped = [f for f in old if f not in new_set]
    if not dropped:
        return

    base = Path(str(target).rstrip("/"))
    for f in dropped:
        if not f:
            continue
        if selected_harnesses is not None:
            if not _owner_overlap(selected_harnesses, _path_owners(f)):
                continue
        if other_profiles_claim_file(target, profile, f):
            continue
        abs_path = base / f
        if abs_path.exists() or abs_path.is_symlink():
            _rm_rf(abs_path)


def select_files(
    old_files: list[str],
    new_files: list[str],
    selected_harnesses: list[str],
) -> list[str]:
    """Merge a selective install's ``new_files`` into ``old_files``,
    dropping only orphans whose path prefix is owned by one of
    ``selected_harnesses`` (files owned by other harnesses survive).

    Owns the owner-overlap orphan filter so the CLI does not reach into
    the private ``_path_owners`` / ``_owner_overlap`` helpers. Result is
    sorted + deduped (manifest invariant)."""
    new_set = set(new_files)
    in_scope_orphans = {
        old_f
        for old_f in old_files
        if old_f not in new_set
        and _owner_overlap(selected_harnesses, _path_owners(old_f))
    }
    kept = [f for f in old_files if f not in in_scope_orphans]
    return sorted(set(kept) | new_set)


def _rm_rf(path: Path) -> None:
    """rm -rf semantics for a file or directory tree."""
    import shutil

    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def remove_path(path: Path) -> None:
    """Public ``rm -rf`` for a tracked artefact path.

    The CLI's uninstall sweep calls this instead of reaching into the
    private :func:`_rm_rf` (mirrors the public :func:`select_files` seam
    added for the same reason)."""
    _rm_rf(path)
