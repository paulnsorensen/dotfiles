"""test_renderer_crush.py — merge + clean tests for the Crush renderer."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile.parse import Manifest
from agent_profile.renderers.base import Renderer, MergedConfigError
from agent_profile.renderers.crush import CrushRenderer


def _manifest(tmp_path: Path) -> Manifest:
    src = tmp_path / "src"
    src.mkdir(parents=True, exist_ok=True)
    (src / "hooks").mkdir()
    (src / "hooks" / "guard.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
    return Manifest(
        name="crushy",
        mcps=[
            {
                "name": "stdio-one",
                "command": "npx",
                "args": ["-y", "foo-mcp"],
                "env": {"KEY": "value"},
                "disabled_tools": ["write"],
                "timeout": 12,
                "harnesses": ["crush"],
                "_source_dir": str(src),
            },
            {
                "name": "http-one",
                "type": "http",
                "url": "https://example.com/mcp",
                "headers": {"Authorization": "Bearer t"},
                "harnesses": ["crush"],
                "_source_dir": str(src),
            },
            {
                "name": "claude-only",
                "command": "nope",
                "harnesses": ["claude"],
                "_source_dir": str(src),
            },
        ],
        hooks=[
            {
                "name": "guard",
                "event": "PreToolUse",
                "matcher": "^bash$",
                "script": "hooks/guard.sh",
                "timeout": 7,
                "harnesses": ["crush"],
                "_source_dir": str(src),
            },
            {
                "name": "ignored",
                "event": "SessionStart",
                "script": "hooks/guard.sh",
                "harnesses": ["crush"],
                "_source_dir": str(src),
            },
        ],
    )


def test_implements_renderer_protocol():
    renderer = CrushRenderer()
    assert isinstance(renderer, Renderer)
    assert renderer.name == "crush"


def test_render_merges_mcp_and_hooks(tmp_path: Path):
    manifest = _manifest(tmp_path)
    target = tmp_path / "target"
    tracked = CrushRenderer().render(manifest, target)

    cfg = json.loads((target / ".config" / "crush" / "crush.json").read_text())
    assert cfg["mcp"]["stdio-one"] == {
        "type": "stdio",
        "command": "npx",
        "args": ["-y", "foo-mcp"],
        "env": {"KEY": "value"},
        "disabled_tools": ["write"],
        "timeout": 12,
    }
    assert cfg["mcp"]["http-one"] == {
        "type": "http",
        "url": "https://example.com/mcp",
        "headers": {"Authorization": "Bearer t"},
    }
    assert "claude-only" not in cfg["mcp"]
    assert cfg["hooks"]["PreToolUse"] == [
        {
            "command": str(target / ".config" / "crush" / "hooks" / "guard.sh"),
            "matcher": "^bash$",
            "timeout": 7,
        }
    ]
    assert ".config/crush/hooks/guard.sh" in tracked
    assert ".config/crush/crush.json" not in tracked


def test_render_preserves_user_entries(tmp_path: Path):
    manifest = _manifest(tmp_path)
    target = tmp_path / "target"
    cfg_path = target / ".config" / "crush" / "crush.json"
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text(
        json.dumps(
            {
                "mcp": {"user": {"type": "stdio", "command": "keep"}},
                "hooks": {"PreToolUse": [{"command": "/tmp/user-hook.sh"}]},
                "options": {"debug": True},
            }
        )
    )

    CrushRenderer().render(manifest, target)
    cfg = json.loads(cfg_path.read_text())
    assert "user" in cfg["mcp"]
    assert cfg["options"] == {"debug": True}
    assert {"command": "/tmp/user-hook.sh"} in cfg["hooks"]["PreToolUse"]


def test_clean_removes_only_profile_entries(tmp_path: Path):
    manifest = _manifest(tmp_path)
    target = tmp_path / "target"
    renderer = CrushRenderer()
    renderer.render(manifest, target)

    cfg_path = target / ".config" / "crush" / "crush.json"
    data = json.loads(cfg_path.read_text())
    data["mcp"]["user"] = {"type": "stdio", "command": "keep"}
    data["hooks"]["PreToolUse"].append({"command": "/tmp/user-hook.sh"})
    cfg_path.write_text(json.dumps(data, indent=2) + "\n")

    renderer.clean(manifest, target)
    cleaned = json.loads(cfg_path.read_text())
    assert cleaned["mcp"] == {"user": {"type": "stdio", "command": "keep"}}
    assert cleaned["hooks"]["PreToolUse"] == [{"command": "/tmp/user-hook.sh"}]


def test_clean_removes_bootstrapped_file(tmp_path: Path):
    manifest = _manifest(tmp_path)
    target = tmp_path / "target"
    renderer = CrushRenderer()
    renderer.render(manifest, target)
    renderer.clean(manifest, target)
    assert not (target / ".config" / "crush" / "crush.json").exists()


def test_non_object_config_raises(tmp_path: Path):
    target = tmp_path / "target"
    cfg_path = target / ".config" / "crush" / "crush.json"
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text("[]")
    with pytest.raises(MergedConfigError):
        CrushRenderer().render(_manifest(tmp_path), target)
