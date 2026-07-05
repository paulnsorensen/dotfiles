"""Shared data shapes for compiled profile deployment."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

VALID_COMPILE_HARNESSES = (
    "claude",
    "codex",
    "opencode",
    "cursor",
    "copilot",
)

# Live compiled deployment no longer owns any harness-global merged settings.
# Those files move to chezmoi management, so compile emits only generated
# fragments and records no user-owned merged config paths for apply/drift.
MERGED_SETTINGS_BY_HARNESS: dict[str, tuple[str, ...]] = {}


@dataclass(frozen=True)
class CompileTarget:
    """One named live deployment target from ``compile_targets``."""

    name: str
    symbolic_root: str
    resolved_root: Path
    harnesses: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "symbolic_root": self.symbolic_root,
            "resolved_root": str(self.resolved_root),
            "harnesses": list(self.harnesses),
        }


@dataclass(frozen=True)
class CompiledFile:
    """A generated fragment that should be applied under a target root."""

    target: str
    harness: str
    fragment_path: Path
    relative_path: str
    generated: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "target": self.target,
            "harness": self.harness,
            "fragment_path": str(self.fragment_path),
            "relative_path": self.relative_path,
            "generated": self.generated,
        }


@dataclass(frozen=True)
class DriftRecord:
    """One reported difference between baseline, live, and compiled config."""

    target: str
    relative_path: str
    path: str
    baseline: Any
    live: Any
    compiled: Any

    def to_dict(self) -> dict[str, Any]:
        return {
            "target": self.target,
            "relative_path": self.relative_path,
            "path": self.path,
            "baseline": self.baseline,
            "live": self.live,
            "compiled": self.compiled,
        }


@dataclass(frozen=True)
class CompiledManifest:
    """Manifest written by ``ap compile`` and consumed by apply/drift steps."""

    profile: str
    source_id: str
    manifest_path: Path
    targets: tuple[CompileTarget, ...]
    files: tuple[CompiledFile, ...] = ()
    drift: tuple[DriftRecord, ...] = ()
    # Legacy field retained for manifest compatibility. Fresh compile now leaves
    # live/global Claude user-scope MCP registration to chezmoi/user ownership,
    # so renderers emit an empty tuple here.
    user_mcps: tuple[dict[str, Any], ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "profile": self.profile,
            "source_id": self.source_id,
            "manifest_path": str(self.manifest_path),
            "compile_targets": [target.to_dict() for target in self.targets],
            "files": [file.to_dict() for file in self.files],
            "drift": [record.to_dict() for record in self.drift],
            "user_mcps": [dict(mcp) for mcp in self.user_mcps],
        }


@dataclass(frozen=True)
class ApplyState:
    """Previously managed generated files for compiled-manifest apply."""

    managed_files: tuple[str, ...] = field(default_factory=tuple)

    def to_dict(self) -> dict[str, Any]:
        return {"managed_files": list(self.managed_files)}
