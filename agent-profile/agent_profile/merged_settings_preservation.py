"""Guard user-owned merged settings files during compiled-manifest apply.

``ap apply-compiled`` reconciles live target roots against a compiled
manifest: it copies fragment files into place and deletes previously managed
*generated* files that the new manifest no longer lists. Merged settings files
(e.g. ``settings.json`` that mixes generated keys with hand-written user keys)
are different -- they carry user-owned content and must never be deleted, only
drift-checked. This module is the single source of truth for "is this manifest
file a user-owned merged settings file -> preserve it".

Ownership is recorded on each manifest file record (the seed model): generated
fragments carry ``generated=True`` (the compiler owns them; normal reconcile
applies), while user-owned merged settings carry ``generated=False`` (preserve).

Records and manifests may arrive as the :mod:`agent_profile.compiled_types`
dataclasses or as the JSON mappings ``ap apply-compiled`` reads off disk; both
forms are accepted. Paths are matched on the manifest's ``relative_path``
identity -- callers must express deletion candidates the same way.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from typing import Any

from agent_profile.compiled_types import CompiledFile, CompiledManifest

FileRecord = CompiledFile | Mapping[str, Any]
ManifestLike = CompiledManifest | Mapping[str, Any]

# Migration safety: older apply-state snapshots may still list harness-global
# config files that agent-profile no longer owns. Never reconcile-delete them.
DISCONNECTED_GLOBAL_SETTINGS = frozenset(
    {
        ".claude/settings.json",
        ".codex/config.toml",
        "opencode.json",
        ".cursor/mcp.json",
        ".copilot/mcp-config.json",
        ".config/crush/crush.json",
    }
)


def _generated(record: FileRecord) -> bool:
    if isinstance(record, CompiledFile):
        return record.generated
    if isinstance(record, Mapping):
        return bool(record.get("generated", True))
    raise TypeError(f"unsupported manifest file record: {record!r}")


def _relative_path(record: FileRecord) -> str:
    if isinstance(record, CompiledFile):
        return record.relative_path
    if isinstance(record, Mapping):
        return str(record["relative_path"])
    raise TypeError(f"unsupported manifest file record: {record!r}")


def _files(manifest: ManifestLike) -> tuple[FileRecord, ...]:
    if isinstance(manifest, CompiledManifest):
        return manifest.files
    if isinstance(manifest, Mapping):
        return tuple(manifest.get("files", ()))
    raise TypeError(f"unsupported manifest: {manifest!r}")


def is_user_owned_merged(record: FileRecord) -> bool:
    """Return True when a manifest file record is a user-owned merged setting.

    Generated fragments are owned by the compiler and may be reconciled or
    deleted; merged settings carry user keys and must be preserved.
    """

    return not _generated(record)


def preserved_paths(manifest: ManifestLike) -> frozenset[str]:
    """Relative paths the apply step must never delete."""

    return frozenset(
        _relative_path(record)
        for record in _files(manifest)
        if is_user_owned_merged(record)
    )


def filter_preserved(candidates: Iterable[str], manifest: ManifestLike) -> list[str]:
    """Drop preserved settings from deletion ``candidates``.

    This excludes both user-owned merged settings still present in the compiled
    manifest and the legacy global settings paths that the compiler stopped
    managing during the chezmoi ownership handoff. Input order is preserved.
    """

    preserved = preserved_paths(manifest) | DISCONNECTED_GLOBAL_SETTINGS
    return [path for path in candidates if path not in preserved]
