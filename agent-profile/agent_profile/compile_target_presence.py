"""Validation for compiled profile deployment targets."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


class CompileTargetPresenceError(Exception):
    """Raised when a profile cannot be compiled because targets are missing."""


def require_compile_targets(profile_dir: Path) -> dict[str, Any]:
    """Return compile_targets, failing loud when the profile omits them."""

    profile_path = profile_dir / "profile.yaml"
    data = yaml.safe_load(profile_path.read_text()) or {}
    if "compile_targets" not in data:
        name = data.get("name") or profile_dir.name
        raise CompileTargetPresenceError(
            f"ap compile: profile '{name}' must define compile_targets"
        )
    return data["compile_targets"]
