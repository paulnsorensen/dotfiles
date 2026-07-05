from __future__ import annotations

import os
import re
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from agent_profile.compiled_types import CompileTarget, VALID_COMPILE_HARNESSES

_ENV_REF_RE = re.compile(r"\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)")


class CompileTargetValidationError(ValueError):
    pass


def validate_compile_targets(
    raw: Any,
    *,
    manifest_path: Path,
    env: Mapping[str, str] | None = None,
) -> tuple[CompileTarget, ...]:
    if raw in (None, {}):
        return ()
    if not isinstance(raw, Mapping):
        raise CompileTargetValidationError(
            f"ap_parse_one: {manifest_path} compile_targets must be a mapping"
        )

    targets: list[CompileTarget] = []
    harness_owners: dict[str, str] = {}
    env_map = os.environ if env is None else env

    for name, config in raw.items():
        target_name = str(name)
        if not isinstance(config, Mapping):
            raise _target_error(manifest_path, target_name, "must be a mapping")

        symbolic_root = config.get("target_root")
        if not symbolic_root:
            raise _target_error(
                manifest_path, target_name, "is missing required field 'target_root'"
            )

        harnesses = config.get("harnesses")
        if not harnesses:
            raise _target_error(
                manifest_path, target_name, "is missing required field 'harnesses'"
            )

        resolved_root = _resolve_root(
            str(symbolic_root), manifest_path=manifest_path, target_name=target_name, env=env_map
        )
        normalized_harnesses = _validate_harnesses(
            harnesses,
            manifest_path=manifest_path,
            target_name=target_name,
            harness_owners=harness_owners,
        )
        targets.append(
            CompileTarget(
                target_name,
                str(symbolic_root),
                resolved_root,
                tuple(normalized_harnesses),
            )
        )

    return tuple(targets)


def _resolve_root(
    symbolic_root: str,
    *,
    manifest_path: Path,
    target_name: str,
    env: Mapping[str, str],
) -> Path:
    expanded = os.path.expanduser(_expand_env(symbolic_root, env))
    unresolved = _ENV_REF_RE.search(expanded)
    if unresolved:
        raise _target_error(
            manifest_path,
            target_name,
            f"has unresolved env var {unresolved.group(0)!r} in target_root",
        )

    root = Path(expanded)
    if not root.is_absolute():
        raise _target_error(manifest_path, target_name, "target_root must resolve absolute")
    return root.resolve()


def _expand_env(value: str, env: Mapping[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        token = match.group(0)
        key = token[2:-1] if token.startswith("${") else token[1:]
        return env.get(key, token)

    return _ENV_REF_RE.sub(replace, value)


def _validate_harnesses(
    harnesses: Any,
    *,
    manifest_path: Path,
    target_name: str,
    harness_owners: dict[str, str],
) -> list[str]:
    if isinstance(harnesses, str) or not isinstance(harnesses, list | tuple):
        raise _target_error(manifest_path, target_name, "harnesses must be a list")

    normalized: list[str] = []
    for harness in harnesses:
        harness_name = str(harness)
        if harness_name not in VALID_COMPILE_HARNESSES:
            valid = "|".join(VALID_COMPILE_HARNESSES)
            raise _target_error(
                manifest_path,
                target_name,
                f"has unknown harness '{harness_name}' (valid: {valid})",
            )
        owner = harness_owners.get(harness_name)
        if owner is not None:
            raise _target_error(
                manifest_path,
                target_name,
                f"duplicates harness '{harness_name}' already assigned to target '{owner}'",
            )
        harness_owners[harness_name] = target_name
        normalized.append(harness_name)

    return normalized


def _target_error(
    manifest_path: Path, target_name: str, message: str
) -> CompileTargetValidationError:
    return CompileTargetValidationError(
        f"ap_parse_one: {manifest_path} compile target '{target_name}' {message}"
    )
