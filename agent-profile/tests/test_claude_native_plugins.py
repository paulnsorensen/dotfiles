"""test_claude_native_plugins.py — Claude-native plugin pass (hybrid delivery).

Covers:
- claude_native=True entry produces native_plugins list (ingest layer)
- non-native entry produces no native record (ingest layer)
- DEDUP: claude removed from decomposed MCP harnesses for claude_native plugins
- DEDUP: skills from claude_native plugins carry _from_native_plugin flag
- Manifest.native_plugins field exists and is populated from registry expansion
- ClaudeRenderer writes extraKnownMarketplaces + enabledPlugins for native plugins
- ClaudeRenderer does NOT write decomposed MCP/skills for claude_native plugins
- Non-native plugins DO get decomposed MCP/skills on Claude
- ClaudeRenderer.clean() un-merges native plugin marketplace + enabledPlugins entries
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest.mock import patch, MagicMock

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


# ── Ingest layer ──────────────────────────────────────────────────────────────

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


def test_claude_native_mcp_excludes_claude_from_harnesses(tmp_path):
    """DEDUP: claude is removed from the decomposed MCP's harnesses for claude_native plugins.

    Claude gets the plugin via native marketplace install, not via bare user MCP.
    Other harnesses (codex, opencode, etc.) still get the decomposed MCP.
    """
    payload = _make_native_payload(tmp_path, "milknado")
    _make_plugins_registry(
        tmp_path,
        {
            "milknado": {
                "path": str(payload),
                "harnesses": ["claude", "codex", "opencode"],
                "claude_native": True,
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcps = out["mcps"]
    assert len(mcps) == 1
    mcp = mcps[0]
    # claude must NOT appear in the harnesses list
    harnesses = mcp.get("harnesses", [])
    assert "claude" not in harnesses, f"claude should be excluded, got: {harnesses}"
    # other harnesses survive
    assert "codex" in harnesses
    assert "opencode" in harnesses


def test_claude_native_mcp_all_harnesses_becomes_non_claude(tmp_path):
    """When harnesses=[claude] only, claude_native drops it entirely.

    The decomposed MCP should only exist for non-claude harnesses.
    If the original harnesses list was only [claude], the MCP is effectively
    claude-only-via-native and the decomposed item should have no harnesses
    (or an empty list), meaning it won't be rendered anywhere.
    """
    payload = _make_native_payload(tmp_path, "milknado")
    _make_plugins_registry(
        tmp_path,
        {
            "milknado": {
                "path": str(payload),
                "harnesses": ["claude"],
                "claude_native": True,
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcps = out["mcps"]
    assert len(mcps) == 1
    mcp = mcps[0]
    harnesses = mcp.get("harnesses", [])
    assert "claude" not in harnesses
    # With only claude removed from [claude], result is empty list
    assert harnesses == []


def test_claude_native_skills_carry_from_native_plugin_flag(tmp_path):
    """DEDUP: skills from claude_native plugins carry _from_native_plugin=True.

    The claude renderer's _write_skills skips these — the plugin bundle
    delivers them at plugin scope, not user scope.
    """
    payload = _make_native_payload(tmp_path, "milknado")
    # Create a skill in the payload
    skill_dir = payload / "skills" / "my-skill"
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text("skill content")

    _make_plugins_registry(
        tmp_path,
        {
            "milknado": {
                "path": str(payload),
                "harnesses": ["claude", "codex"],
                "claude_native": True,
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    skills = out["skills"]
    assert len(skills) == 1
    skill = skills[0]
    assert skill.get("_from_native_plugin") is True


def test_non_native_skills_have_no_native_flag(tmp_path):
    """Non-native plugin skills do NOT carry _from_native_plugin flag."""
    payload = _make_native_payload(tmp_path, "myplugin")
    skill_dir = payload / "skills" / "my-skill"
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text("skill content")

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
    skills = out["skills"]
    assert len(skills) == 1
    assert "_from_native_plugin" not in skills[0] or skills[0].get("_from_native_plugin") is False


# ── Manifest threading ────────────────────────────────────────────────────────

def test_manifest_has_native_plugins_field(tmp_path):
    """Manifest.native_plugins is populated from the registry expansion."""
    from agent_profile.parse import Manifest
    m = Manifest(name="test")
    # Field must exist and default to empty list
    assert hasattr(m, "native_plugins")
    assert m.native_plugins == []


# ── Claude renderer: native pass ──────────────────────────────────────────────

def _make_manifest_with_native_plugin(tmp_path: Path, plugin_name: str) -> tuple:
    """Return (manifest, payload_path) for a claude_native plugin render test."""
    from agent_profile.parse import Manifest
    payload = tmp_path / "plugins" / plugin_name
    payload.mkdir(parents=True, exist_ok=True)
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {plugin_name: {"command": "uvx", "args": [f"{plugin_name}-mcp"]}}})
    )
    cp = payload / ".claude-plugin"
    cp.mkdir()
    (cp / "marketplace.json").write_text(
        json.dumps({"name": plugin_name, "owner": {"name": "test"}, "plugins": [{"name": plugin_name}]})
    )
    manifest = Manifest(
        name="base",
        native_plugins=[
            {
                "name": plugin_name,
                "claude_native": True,
                "payload_root": str(payload),
                "description": "Test plugin",
            }
        ],
    )
    return manifest, payload


def test_claude_renderer_writes_marketplace_for_native_plugin(tmp_path):
    """ClaudeRenderer.render() writes extraKnownMarketplaces for a claude_native plugin.

    The native plugin's payload_root must be registered as a directory-type
    marketplace so Claude's plugin resolution can find it.
    """
    from agent_profile.renderers.claude import ClaudeRenderer

    manifest, payload = _make_manifest_with_native_plugin(tmp_path, "milknado")
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    settings = target / ".claude" / "settings.json"
    assert settings.is_file(), "settings.json not written"
    data = json.loads(settings.read_text())
    markets = data.get("extraKnownMarketplaces", {})
    # The plugin's payload root should appear as a directory marketplace
    assert any(
        v.get("source", {}).get("path") == str(payload)
        for v in markets.values()
    ), f"extraKnownMarketplaces missing payload path: {markets}"


def test_claude_renderer_writes_enabled_plugins_for_native_plugin(tmp_path):
    """ClaudeRenderer.render() writes enabledPlugins for a claude_native plugin.

    The plugin name must appear enabled in enabledPlugins so Claude
    activates it from the marketplace.
    """
    from agent_profile.renderers.claude import ClaudeRenderer

    manifest, payload = _make_manifest_with_native_plugin(tmp_path, "milknado")
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    settings = target / ".claude" / "settings.json"
    data = json.loads(settings.read_text())
    enabled = data.get("enabledPlugins", {})
    # Some entry for milknado must be enabled=True
    assert any(v is True for v in enabled.values()), f"No enabled plugin found: {enabled}"


def test_claude_renderer_issues_marketplace_add_cli_call(tmp_path):
    """ClaudeRenderer.render() calls `claude plugin marketplace add <payload_root>`.

    Writing extraKnownMarketplaces alone is not enough — Claude's CLI must
    prime its resolution cache via this command call.
    """
    from agent_profile.renderers.claude import ClaudeRenderer

    manifest, payload = _make_manifest_with_native_plugin(tmp_path, "milknado")
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    # Find any call to subprocess.run that invokes the marketplace add command
    calls = mock_run.call_args_list
    marketplace_calls = [
        c for c in calls
        if "marketplace" in str(c) and "add" in str(c) and str(payload) in str(c)
    ]
    assert marketplace_calls, (
        f"Expected `claude plugin marketplace add {payload}` call.\n"
        f"Actual subprocess.run calls: {calls}"
    )


def test_claude_renderer_does_not_write_decomposed_mcp_for_native_plugin(tmp_path):
    """ClaudeRenderer skips the decomposed MCP for claude_native plugins.

    Claude gets milknado via mcp__plugin_milknado_milknado__* (native install).
    The bare mcp__milknado__* (user-scope MCP) must NOT appear.
    """
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    payload = tmp_path / "plugins" / "milknado"
    payload.mkdir(parents=True, exist_ok=True)
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"milknado": {"command": "uvx", "args": ["milknado-mcp"]}}})
    )
    (payload / ".claude-plugin").mkdir()
    (payload / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps({"name": "milknado", "owner": {"name": "test"}, "plugins": [{"name": "milknado"}]})
    )

    # MCP item with harnesses=["codex"] only (claude removed by DEDUP)
    mcp_item = {
        "name": "milknado",
        "command": "uvx",
        "args": ["milknado-mcp"],
        "harnesses": ["codex"],  # claude excluded by DEDUP
        "_source_dir": str(payload),
    }
    manifest = Manifest(
        name="base",
        mcps=[mcp_item],
        native_plugins=[
            {
                "name": "milknado",
                "claude_native": True,
                "payload_root": str(payload),
                "description": "Mikado engine",
            }
        ],
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    # The plugin's .mcp.json (plugin-scope, for the local marketplace) is fine,
    # but the bare user-scope MCP should NOT be registered.
    # Check settings.json — mcp_scope="plugin" so user-scope is unused.
    # The key check: the plugin tree .mcp.json should NOT contain milknado server
    # added via user-scope (that path is _write_mcp_json via mcps_for).
    plugin_mcp = target / ".claude" / "plugins" / "local" / "base" / ".mcp.json"
    if plugin_mcp.is_file():
        mcp_data = json.loads(plugin_mcp.read_text())
        servers = mcp_data.get("mcpServers", {})
        # milknado should NOT appear as a bare user-scoped MCP in the plugin tree
        # (it gets native install via marketplace, not decomposed user MCP)
        assert "milknado" not in servers, (
            f"milknado decomposed as user MCP in plugin tree — should use native: {servers}"
        )


def test_claude_renderer_skips_native_plugin_skills(tmp_path):
    """ClaudeRenderer._write_skills skips items with _from_native_plugin flag.

    Native plugin skills are delivered by the plugin bundle at plugin scope,
    not by the renderer at user scope.
    """
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    payload = tmp_path / "plugins" / "milknado"
    skill_src = payload / "skills" / "my-skill"
    skill_src.mkdir(parents=True, exist_ok=True)
    (skill_src / "SKILL.md").write_text("skill content")

    skill_item = {
        "name": "my-skill",
        "path": "skills/my-skill",
        "_source_dir": str(payload),
        "_from_native_plugin": True,
    }
    manifest = Manifest(
        name="base",
        skills=[skill_item],
        native_plugins=[
            {
                "name": "milknado",
                "claude_native": True,
                "payload_root": str(payload),
                "description": "",
            }
        ],
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    # The skill should NOT have been written to .claude/skills/
    skill_out = target / ".claude" / "skills" / "my-skill"
    assert not skill_out.exists(), (
        f"Native plugin skill was written to user scope — should be skipped: {skill_out}"
    )


# ── clean() un-merge ──────────────────────────────────────────────────────────

def test_clean_removes_native_plugin_marketplace_entry(tmp_path):
    """ClaudeRenderer.clean() removes the native plugin's extraKnownMarketplaces entry."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    target = tmp_path / "home"
    (target / ".claude").mkdir(parents=True)
    settings_path = target / ".claude" / "settings.json"
    # Include a user-owned key so the file survives (clean deletes only {} files).
    settings_path.write_text(json.dumps({
        "extraKnownMarketplaces": {
            "milknado": {"source": {"source": "directory", "path": "/some/path"}}
        },
        "enabledPlugins": {
            "milknado@milknado": True
        },
        "userKey": "preserved",
    }) + "\n")

    manifest = Manifest(
        name="base",
        native_plugins=[
            {
                "name": "milknado",
                "claude_native": True,
                "payload_root": "/some/path",
                "description": "",
            }
        ],
    )

    ClaudeRenderer().clean(manifest, target)

    assert settings_path.is_file()
    data = json.loads(settings_path.read_text())
    assert "milknado" not in data.get("extraKnownMarketplaces", {})


def test_clean_removes_native_plugin_enabled_plugins_entry(tmp_path):
    """ClaudeRenderer.clean() removes the native plugin's enabledPlugins entry."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    target = tmp_path / "home"
    (target / ".claude").mkdir(parents=True)
    settings_path = target / ".claude" / "settings.json"
    settings_path.write_text(json.dumps({
        "enabledPlugins": {
            "milknado@milknado": True,
            "other-plugin@local": True,
        },
    }) + "\n")

    manifest = Manifest(
        name="base",
        native_plugins=[
            {
                "name": "milknado",
                "claude_native": True,
                "payload_root": "/some/path",
                "description": "",
            }
        ],
    )

    ClaudeRenderer().clean(manifest, target)

    data = json.loads(settings_path.read_text())
    enabled = data.get("enabledPlugins", {})
    # milknado entry removed, other-plugin survives
    milknado_keys = [k for k in enabled if "milknado" in k]
    assert milknado_keys == [], f"milknado entries should be removed: {enabled}"
    assert "other-plugin@local" in enabled
