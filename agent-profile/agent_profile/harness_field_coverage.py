from __future__ import annotations

from pathlib import Path
from typing import Any

from agent_profile.compiled_types import CompileTarget

_CLAUDE_FIELDS = ("enabled_plugins", "marketplaces")


class HarnessFieldCoverageError(ValueError):
    pass


def validate_harness_field_coverage(
    raw_profile: dict[str, Any],
    compile_targets: tuple[CompileTarget, ...],
    *,
    manifest_path: Path,
) -> None:
    target_harnesses = {
        harness for target in compile_targets for harness in target.harnesses
    }
    if "claude" in target_harnesses:
        return

    for field in _CLAUDE_FIELDS:
        if raw_profile.get(field):
            name = raw_profile.get("name") or manifest_path.parent.name
            raise HarnessFieldCoverageError(
                f"ap compile: profile '{name}' field '{field}' "
                "requires compile target harness 'claude'"
            )
