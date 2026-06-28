"""Validation for compiled profile deployment targets."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from agent_profile.compile_target_validation import (
    CompileTargetValidationError,
    validate_compile_targets,
)
from agent_profile.harness_field_coverage import (
    HarnessFieldCoverageError,
    validate_harness_field_coverage,
)


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
    try:
        compile_targets = validate_compile_targets(
            data["compile_targets"], manifest_path=profile_path
        )
        validate_harness_field_coverage(
            data, compile_targets, manifest_path=profile_path
        )
    except (CompileTargetValidationError, HarnessFieldCoverageError) as exc:
        raise CompileTargetPresenceError(str(exc)) from exc
    return data["compile_targets"]
