"""Shared supported harness names and explicit list validation."""

from __future__ import annotations

from typing import Any


SUPPORTED_ITEM_HARNESSES = (
    "claude",
    "codex",
    "cursor",
    "copilot",
)


def validate_supported_harnesses(
    harnesses: Any,
    *,
    context: str,
    error_type: type[Exception] = ValueError,
) -> list[str]:
    """Validate and normalize an explicit item or compile-target harness list."""
    if isinstance(harnesses, str) or not isinstance(harnesses, list | tuple):
        raise error_type(f"{context} harnesses must be a list")

    normalized: list[str] = []
    valid = "|".join(SUPPORTED_ITEM_HARNESSES)
    for harness in harnesses:
        harness_name = str(harness)
        if harness_name not in SUPPORTED_ITEM_HARNESSES:
            raise error_type(
                f"{context} has unknown harness '{harness_name}' (valid: {valid})"
            )
        normalized.append(harness_name)
    return normalized
