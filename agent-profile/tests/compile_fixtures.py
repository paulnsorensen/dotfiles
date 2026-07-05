"""Shared fixtures for compiled profile tests."""

from __future__ import annotations

import json
from pathlib import Path

import yaml

from agent_profile.compiled_types import CompileTarget


def live_profile_yaml(*, compile_targets: dict | None = None, **overrides: object) -> str:
    profile = {
        "name": "live",
        "description": "Live agent deployment profile",
        "include": ["base", "_permissions"],
        "compile_targets": compile_targets
        or {
            "home": {
                "target_root": "$HOME",
                "harnesses": ["claude", "codex", "cursor", "copilot"],
            },
            "opencode": {
                "target_root": "$HOME/.config/opencode",
                "harnesses": ["opencode"],
            },
        },
        "enabled_plugins": {"global@local": True},
        "marketplaces": {"local": "$HOME/.claude/plugins/local"},
    }
    profile.update(overrides)
    return yaml.safe_dump(profile, sort_keys=False)


def write_live_profile(root: Path, **overrides: object) -> Path:
    profile_dir = root / "live"
    profile_dir.mkdir(parents=True, exist_ok=True)
    (profile_dir / "profile.yaml").write_text(live_profile_yaml(**overrides))
    return profile_dir


def write_minimal_includes(root: Path) -> None:
    for name in ("base", "_permissions"):
        profile_dir = root / name
        profile_dir.mkdir(parents=True, exist_ok=True)
        (profile_dir / "profile.yaml").write_text(f"name: {name}\n")


def compiled_target(
    tmp_path: Path,
    *,
    name: str = "home",
    symbolic_root: str = "$HOME",
    harnesses: tuple[str, ...] = ("claude", "codex"),
) -> CompileTarget:
    resolved_root = tmp_path / "targets" / name
    resolved_root.mkdir(parents=True, exist_ok=True)
    return CompileTarget(name, symbolic_root, resolved_root, harnesses)


def write_json(path: Path, data: object) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return path


def write_text(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return path
