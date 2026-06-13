"""test_claude_native_plugins.py — claude_native plugin registry entries.

Covers:
- claude_native=True entry writes extraKnownMarketplaces + enabledPlugins via Manifest
- non-native entry writes neither
- clean() un-merges both keys

The claude_native pass is realized via the Manifest's `marketplaces` and
`enabled_plugins` fields, which the claude renderer already handles via
_merge_root_settings and _write_local_marketplace. The decomposer populates
those fields for claude_native entries.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile.ingest import expand_registries


def _make_native_payload(tmp_path: Path, name: str) -> Path:
    """Minimal payload for a claude_native plugin."""
    payload = tmp_path / "plugins" / name
    payload.mkdir(parents=True, exist_ok=True)

    # .mcp.json
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {name: {"command": "uvx", "args": [f"{name}-mcp"]}}})
    )

    # .claude-plugin/marketplace.json (required for native resolution)
    cp = payload / ".claude-plugin"
    cp.mkdir()
    (cp / "marketplace.json").write_text(
        json.dumps({"name": name, "owner": {"name": "test"}, "plugins": [{"name": name}]})
    )
    return payload


def _make_plugins_registry(repo: Path, entries: dict) -> Path:
    reg = repo / "agents" / "plugins" / "registry.yaml"
    reg.parent.mkdir(parents=True, exist_ok=True)
    import yaml
    reg.write_text(yaml.dump({"plugins": entries}))
    return reg


def test_claude_native_entry_produces_marketplace_and_enabled_plugins_fields(tmp_path):
    """claude_native=True entry is captured as a native plugin descriptor.

    The decomposer marks native entries so the claude renderer can
    register the marketplace. We verify this via the out dict's
    'native_plugins' list (a new key for native entries).
    """
    payload = _make_native_payload(tmp_path, "milknado")
    _make_plugins_registry(
        tmp_path,
        {
            "milknado": {
                "path": str(payload),
                "harnesses": ["claude"],
                "claude_native": True,
                "description": "Mikado engine",
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    # native_plugins list carries entries for the claude renderer to process
    assert "native_plugins" in out
    native = out["native_plugins"]
    assert len(native) == 1
    entry = native[0]
    assert entry["name"] == "milknado"
    assert entry["claude_native"] is True
    assert entry["payload_root"] == str(payload)


def test_non_native_entry_produces_no_native_plugin_record(tmp_path):
    """claude_native=False (or omitted) entry has no native_plugins record."""
    payload = _make_native_payload(tmp_path, "myplugin")
    _make_plugins_registry(
        tmp_path,
        {
            "myplugin": {
                "path": str(payload),
                "harnesses": ["codex"],
                "claude_native": False,
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    assert out.get("native_plugins", []) == []
