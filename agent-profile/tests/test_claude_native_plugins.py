"""test_claude_native_plugins.py — Claude-native plugin pass (hybrid delivery).

Key structural fact (mirrors real milknado):
  marketplace root: ~/Dev/milknado  (has .claude-plugin/marketplace.json)
  payload root:     ~/Dev/milknado/plugins/milknado  (has .mcp.json + skills/)
  registry path:    = marketplace root (registry.yaml path: ~/Dev/milknado)

Covers:
- Ingest: path: = marketplace root; payload resolved via marketplace.json plugins[].source
- Ingest: canonical marketplace name derived from marketplace.json name field
- Ingest: marketplace.json missing → ParseError (fail loud)
- Ingest: DEDUP — claude excluded from decomposed MCP harnesses for claude_native plugins
- Ingest: DEDUP — skills from claude_native plugins carry _from_native_plugin flag
- Ingest: plugin MCP env var unset (non-optional) → raises; optional → dropped
- Ingest: inter-plugin skill name collision → ParseError
- Manifest: native_plugins field exists and populated
- Renderer: extraKnownMarketplaces key uses marketplace name; path = marketplace root
- Renderer: enabledPlugins key uses <plugin>@<marketplace_name>
- Renderer: claude plugin marketplace add called with marketplace root (not payload)
- Renderer: decomposed MCP/skills not written for claude_native plugins
- Renderer: _write_agents/_write_commands/_write_hooks skip _from_native_plugin items
- clean(): un-merges native plugin marketplace + enabledPlugins entries
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

from agent_profile.ingest import expand_registries
from agent_profile._validate import ParseError


# ── Fixture helpers ───────────────────────────────────────────────────────────

def _make_marketplace(
    tmp_path: Path,
    market_name: str,
    plugins: list[dict],  # e.g. [{"name": "milknado", "source": "./plugins/milknado"}]
) -> Path:
    """Create a marketplace root with .claude-plugin/marketplace.json.

    Returns the marketplace root path (what registry.yaml path: should point at).
    This mirrors the real milknado layout: marketplace.json lives at
    <marketplace_root>/.claude-plugin/marketplace.json.
    """
    market_root = tmp_path / "mktplace" / market_name
    market_root.mkdir(parents=True, exist_ok=True)
    cp = market_root / ".claude-plugin"
    cp.mkdir()
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": market_name,
            "owner": {"name": "test"},
            "plugins": plugins,
        })
    )
    return market_root


def _make_payload(
    market_root: Path,
    relative_source: str,  # e.g. "./plugins/milknado"
    plugin_name: str,
    *,
    with_mcp: bool = True,
    with_skill: bool = False,
    env: dict | None = None,
) -> Path:
    """Create a plugin payload dir relative to the marketplace root.

    The payload dir is market_root / relative_source (stripping leading ./).
    Returns the absolute payload path.
    """
    rel = relative_source.lstrip("./")
    payload = market_root / rel
    payload.mkdir(parents=True, exist_ok=True)
    if with_mcp:
        mcp_body: dict = {"command": "uvx", "args": [f"{plugin_name}-mcp"]}
        if env:
            mcp_body["env"] = env
        (payload / ".mcp.json").write_text(
            json.dumps({"mcpServers": {plugin_name: mcp_body}})
        )
    if with_skill:
        skill_dir = payload / "skills" / f"{plugin_name}-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text("skill content")
    return payload


def _make_plugins_registry(repo: Path, entries: dict) -> Path:
    reg = repo / "agents" / "plugins" / "registry.yaml"
    reg.parent.mkdir(parents=True, exist_ok=True)
    import yaml
    reg.write_text(yaml.dump({"plugins": entries}))
    return reg


def _make_standard_milknado(
    tmp_path: Path,
    *,
    harnesses: list[str] | None = None,
    claude_native: bool = True,
    with_skill: bool = False,
    env: dict | None = None,
) -> tuple[Path, Path, Path]:
    """Build a standard milknado-style fixture.

    Returns (repo, market_root, payload_root).
    market_root has .claude-plugin/marketplace.json pointing at ./plugins/milknado.
    payload_root has .mcp.json (and optionally skills/).
    registry.yaml path: = market_root.
    """
    repo = tmp_path / "repo"
    repo.mkdir()
    market_root = _make_marketplace(
        tmp_path, "milknado",
        [{"name": "milknado", "source": "./plugins/milknado"}]
    )
    payload = _make_payload(
        market_root, "./plugins/milknado", "milknado",
        with_skill=with_skill, env=env
    )
    entry: dict = {
        "path": str(market_root),
        "harnesses": harnesses or ["claude", "codex", "opencode"],
        "claude_native": claude_native,
        "description": "Mikado engine",
    }
    _make_plugins_registry(repo, {"milknado": entry})
    return repo, market_root, payload


# ── A: Marketplace-root path model ────────────────────────────────────────────

def test_path_is_marketplace_root_not_payload(tmp_path):
    """registry.yaml path: is the marketplace root; payload resolved via marketplace.json.

    The decomposer must read marketplace_root/.claude-plugin/marketplace.json,
    find plugins[].source = './plugins/milknado', and resolve .mcp.json + skills
    from market_root/plugins/milknado — NOT from market_root itself.
    """
    repo, market_root, payload = _make_standard_milknado(tmp_path)

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        repo,
        {},
    )
    mcps = out["mcps"]
    assert len(mcps) == 1, f"Expected 1 MCP, got {len(mcps)}"
    mcp = mcps[0]
    assert mcp["name"] == "milknado"
    # _source_dir must be the payload root, not the marketplace root
    assert mcp["_source_dir"] == str(payload), (
        f"_source_dir should be payload root {payload}, got {mcp['_source_dir']}"
    )
    assert mcp["_source_dir"] != str(market_root), (
        "_source_dir must not be marketplace root (that dir has no .mcp.json)"
    )


def test_marketplace_root_has_no_mcp_json(tmp_path):
    """Proves the fixture separation: .mcp.json is at payload root, not marketplace root.

    This locks in the structural invariant that the marketplace root is NOT
    also the payload root for multi-plugin marketplaces.
    """
    repo, market_root, payload = _make_standard_milknado(tmp_path)
    assert not (market_root / ".mcp.json").is_file(), (
        "marketplace root should not have .mcp.json directly"
    )
    assert (payload / ".mcp.json").is_file(), (
        "payload root should have .mcp.json"
    )
    assert (market_root / ".claude-plugin" / "marketplace.json").is_file(), (
        "marketplace root must have .claude-plugin/marketplace.json"
    )


def test_mcp_decomposed_from_payload_not_marketplace_root(tmp_path):
    """MCP is read from plugins[].source dir, not the marketplace root itself."""
    repo, market_root, payload = _make_standard_milknado(
        tmp_path, harnesses=["codex", "opencode"], claude_native=False
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        repo,
        {},
    )
    mcps = out["mcps"]
    # We get the milknado MCP from the payload, not from any stray file at market_root
    assert len(mcps) == 1
    assert mcps[0]["command"] == "uvx"  # from payload/.mcp.json


# ── A-name: canonical marketplace name from marketplace.json ──────────────────

def test_native_plugin_descriptor_carries_marketplace_name(tmp_path):
    """native_plugins entry carries marketplace_name from marketplace.json, not registry key.

    The marketplace key for extraKnownMarketplaces and the @<name> enabledPlugins
    suffix must come from marketplace.json 'name', not from the YAML registry key.
    """
    repo = tmp_path / "repo"
    repo.mkdir()
    # marketplace.json name = 'my-market', registry key = 'myplugin' (different!)
    market_root = _make_marketplace(
        tmp_path, "my-market",
        [{"name": "myplugin", "source": "./plugins/myplugin"}]
    )
    _make_payload(market_root, "./plugins/myplugin", "myplugin")
    _make_plugins_registry(repo, {"myplugin": {
        "path": str(market_root),
        "harnesses": ["claude"],
        "claude_native": True,
    }})

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    native = out["native_plugins"]
    assert len(native) == 1
    entry = native[0]
    # marketplace_name must be 'my-market' (from marketplace.json), not 'myplugin'
    assert entry.get("marketplace_name") == "my-market", (
        f"marketplace_name should be 'my-market' from marketplace.json, got: {entry}"
    )


def test_native_plugin_descriptor_carries_marketplace_root(tmp_path):
    """native_plugins entry payload_root is the MARKETPLACE root, not the plugin payload.

    The claude plugin marketplace add command and extraKnownMarketplaces path
    both require the directory containing .claude-plugin/marketplace.json.
    """
    repo, market_root, payload = _make_standard_milknado(tmp_path)

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        repo,
        {},
    )
    native = out["native_plugins"]
    assert len(native) == 1
    entry = native[0]
    # marketplace_root must be the marketplace root dir (not the payload)
    assert entry.get("marketplace_root") == str(market_root), (
        f"marketplace_root should be {market_root}, got: {entry}"
    )
    assert entry.get("marketplace_root") != str(payload), (
        "marketplace_root must NOT be the payload root"
    )


# ── C-missing: fail loud on missing marketplace.json ─────────────────────────

def test_missing_marketplace_json_raises(tmp_path):
    """A path: that has no .claude-plugin/marketplace.json raises ParseError.

    Silent failure (no MCPs, no skills, no error) is not acceptable —
    a typo'd path should be caught immediately.
    """
    repo = tmp_path / "repo"
    repo.mkdir()
    bad_path = tmp_path / "no-marketplace-here"
    bad_path.mkdir()
    # No .claude-plugin/marketplace.json at this path
    _make_plugins_registry(repo, {"myplugin": {
        "path": str(bad_path),
        "claude_native": True,
    }})

    with pytest.raises(ParseError, match="marketplace"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})


def test_missing_plugin_path_raises(tmp_path):
    """A path: pointing to a nonexistent directory raises ParseError."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _make_plugins_registry(repo, {"myplugin": {
        "path": str(tmp_path / "does-not-exist"),
        "claude_native": True,
    }})

    with pytest.raises(ParseError, match="marketplace"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})


# ── C-var: env var validation for plugin MCPs ────────────────────────────

def test_plugin_mcp_unset_nonoptional_env_var_raises(tmp_path):
    """Non-optional plugin MCP with unset ${VAR} raises EnvResolutionError.

    Mirrors _expand_mcps: unset vars on non-optional items must fail loud
    to catch typos in env var references.
    """
    from agent_profile.env import EnvResolutionError
    repo, market_root, payload = _make_standard_milknado(
        tmp_path,
        harnesses=["codex"],
        claude_native=False,
        env={"SECRET": "${UNSET_VAR_12345}"},
    )

    with pytest.raises(EnvResolutionError):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})


def test_plugin_mcp_optional_unset_env_var_drops_mcp(tmp_path):
    """Optional plugin MCP with unset ${VAR} is silently dropped.

    Mirrors _expand_mcps: optional items with unset vars are skipped non-fatally,
    consistent with how non-plugin MCPs handle this.
    """
    repo = tmp_path / "repo"
    repo.mkdir()
    market_root = _make_marketplace(
        tmp_path, "myplugin",
        [{"name": "myplugin", "source": "./plugins/myplugin"}]
    )
    # Two servers: one optional with unset var, one without
    payload = market_root / "plugins" / "myplugin"
    payload.mkdir(parents=True)
    (payload / ".mcp.json").write_text(json.dumps({
        "mcpServers": {
            "optional-server": {
                "command": "uvx",
                "args": ["opt-mcp"],
                "env": {"SECRET": "${UNSET_12345}"},
                "optional": True,
            },
            "required-server": {
                "command": "uvx",
                "args": ["req-mcp"],
            },
        }
    }))
    _make_plugins_registry(repo, {"myplugin": {
        "path": str(market_root),
        "harnesses": ["codex"],
        "claude_native": False,
    }})

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    mcps = out["mcps"]
    names = [m["name"] for m in mcps]
    assert "optional-server" not in names, f"Optional server with unset var should be dropped: {names}"
    assert "required-server" in names, f"Required server without env issues should remain: {names}"


# ── Original DEDUP tests (updated fixtures) ───────────────────────────────

def test_claude_native_entry_produces_native_plugin_record(tmp_path):
    """claude_native=True produces a native_plugins record with marketplace info."""
    repo, market_root, payload = _make_standard_milknado(tmp_path)

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    assert "native_plugins" in out
    native = out["native_plugins"]
    assert len(native) == 1
    entry = native[0]
    assert entry["name"] == "milknado"
    assert entry["claude_native"] is True


def test_non_native_entry_produces_no_native_plugin_record(tmp_path):
    """claude_native=False (or omitted) entry has no native_plugins record."""
    repo, market_root, payload = _make_standard_milknado(
        tmp_path, harnesses=["codex"], claude_native=False
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    assert out.get("native_plugins", []) == []


def test_claude_native_mcp_excludes_claude_from_harnesses(tmp_path):
    """DEDUP: claude is removed from decomposed MCP harnesses for claude_native."""
    repo, market_root, payload = _make_standard_milknado(
        tmp_path, harnesses=["claude", "codex", "opencode"],
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    mcps = out["mcps"]
    assert len(mcps) == 1
    harnesses = mcps[0].get("harnesses", [])
    assert "claude" not in harnesses, f"claude should be excluded: {harnesses}"
    assert "codex" in harnesses
    assert "opencode" in harnesses


def test_claude_native_mcp_claude_only_becomes_empty_harnesses(tmp_path):
    """When harnesses=[claude] only, claude_native produces empty harnesses list."""
    repo, market_root, payload = _make_standard_milknado(
        tmp_path, harnesses=["claude"],
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    harnesses = out["mcps"][0].get("harnesses", [])
    assert "claude" not in harnesses
    assert harnesses == []


def test_claude_native_skills_carry_from_native_plugin_flag(tmp_path):
    """DEDUP: skills from claude_native plugins carry _from_native_plugin=True."""
    repo, market_root, payload = _make_standard_milknado(
        tmp_path, with_skill=True
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    skills = out["skills"]
    assert len(skills) == 1
    assert skills[0].get("_from_native_plugin") is True


def test_non_native_skills_have_no_native_flag(tmp_path):
    """Non-native plugin skills do NOT carry _from_native_plugin flag."""
    repo, market_root, payload = _make_standard_milknado(
        tmp_path, harnesses=["codex"], claude_native=False, with_skill=True
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})
    skills = out["skills"]
    assert len(skills) == 1
    assert "_from_native_plugin" not in skills[0] or not skills[0]["_from_native_plugin"]


# ── E-collision: inter-plugin skill collision ──────────────────────────────

def test_inter_plugin_skill_name_collision_raises(tmp_path):
    """Two plugins exporting the same skill name raises ParseError.

    The collision check already handles intra-registry collisions; this
    proves it also catches inter-plugin (two separate plugins, same skill name).
    """
    repo = tmp_path / "repo"
    repo.mkdir()

    # Plugin A: marketplace + payload with 'shared-skill'
    market_a = _make_marketplace(
        tmp_path, "plugin-a",
        [{"name": "plugin-a", "source": "./plugins/plugin-a"}]
    )
    payload_a = _make_payload(market_a, "./plugins/plugin-a", "plugin-a")
    (payload_a / "skills" / "shared-skill").mkdir(parents=True)
    (payload_a / "skills" / "shared-skill" / "SKILL.md").write_text("a")

    # Plugin B: marketplace + payload with the same 'shared-skill'
    market_b = _make_marketplace(
        tmp_path, "plugin-b",
        [{"name": "plugin-b", "source": "./plugins/plugin-b"}]
    )
    payload_b = _make_payload(market_b, "./plugins/plugin-b", "plugin-b")
    (payload_b / "skills" / "shared-skill").mkdir(parents=True)
    (payload_b / "skills" / "shared-skill" / "SKILL.md").write_text("b")

    _make_plugins_registry(repo, {
        "plugin-a": {"path": str(market_a), "harnesses": ["codex"]},
        "plugin-b": {"path": str(market_b), "harnesses": ["codex"]},
    })

    with pytest.raises(ParseError, match="collision"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, repo, {})


# ── Manifest threading ────────────────────────────────────────────────────────

def test_manifest_has_native_plugins_field():
    """Manifest.native_plugins exists and defaults to []."""
    from agent_profile.parse import Manifest
    m = Manifest(name="test")
    assert hasattr(m, "native_plugins")
    assert m.native_plugins == []


# ── Renderer helpers ────────────────────────────────────────────────────────

def _make_manifest_with_native(tmp_path: Path, market_name: str = "milknado"):
    """Return (manifest, market_root) for renderer tests.

    Uses marketplace root != payload root, matching real milknado.
    The native_plugins entry carries marketplace_root and marketplace_name.
    """
    from agent_profile.parse import Manifest
    # marketplace root: tmp_path/mktplace/milknado (has .claude-plugin/marketplace.json)
    market_root = tmp_path / "mktplace" / market_name
    market_root.mkdir(parents=True, exist_ok=True)
    (market_root / ".claude-plugin").mkdir()
    (market_root / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps({
            "name": market_name,
            "owner": {"name": "test"},
            "plugins": [{"name": market_name, "source": f"./plugins/{market_name}"}],
        })
    )
    manifest = Manifest(
        name="base",
        native_plugins=[
            {
                "name": market_name,
                "claude_native": True,
                "marketplace_root": str(market_root),
                "marketplace_name": market_name,
                "description": "Test plugin",
            }
        ],
    )
    return manifest, market_root


# ── Renderer: native pass ─────────────────────────────────────────────────────

def test_claude_renderer_marketplace_path_is_marketplace_root(tmp_path):
    """extraKnownMarketplaces path is the marketplace root, not the plugin payload.

    The marketplace root contains .claude-plugin/marketplace.json which
    Claude needs to resolve plugins. The payload sub-directory does not.
    """
    from agent_profile.renderers.claude import ClaudeRenderer

    manifest, market_root = _make_manifest_with_native(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    settings = target / ".claude" / "settings.json"
    assert settings.is_file()
    data = json.loads(settings.read_text())
    markets = data.get("extraKnownMarketplaces", {})
    # Path must be the marketplace root (which has .claude-plugin/marketplace.json)
    assert any(
        v.get("source", {}).get("path") == str(market_root)
        for v in markets.values()
    ), f"extraKnownMarketplaces must use marketplace root {market_root}: {markets}"
    # Prove the path actually has .claude-plugin/marketplace.json
    for v in markets.values():
        path = v.get("source", {}).get("path", "")
        if path:
            assert (Path(path) / ".claude-plugin" / "marketplace.json").is_file(), (
                f"The registered marketplace path {path} has no "
                ".claude-plugin/marketplace.json — Claude cannot resolve it"
            )


def test_claude_renderer_marketplace_key_from_marketplace_name(tmp_path):
    """extraKnownMarketplaces key comes from marketplace_name (marketplace.json 'name').

    When the registry YAML key differs from marketplace.json name, the canonical
    name from marketplace.json must win.
    """
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    market_root = tmp_path / "mktroot"
    market_root.mkdir()
    (market_root / ".claude-plugin").mkdir()
    # marketplace.json name = 'canonical-name', but registry key = 'registry-key'
    (market_root / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps({"name": "canonical-name", "owner": {"name": "t"}, "plugins": []})
    )
    manifest = Manifest(
        name="base",
        native_plugins=[{
            "name": "registry-key",
            "claude_native": True,
            "marketplace_root": str(market_root),
            "marketplace_name": "canonical-name",
            "description": "",
        }],
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    data = json.loads((target / ".claude" / "settings.json").read_text())
    markets = data.get("extraKnownMarketplaces", {})
    assert "canonical-name" in markets, (
        f"extraKnownMarketplaces key must be marketplace.json name 'canonical-name': {markets}"
    )
    assert "registry-key" not in markets, (
        f"Must not use registry YAML key as marketplace key: {markets}"
    )


def test_claude_renderer_enabled_plugins_key_uses_marketplace_name(tmp_path):
    """enabledPlugins key is <plugin_name>@<marketplace_name>.

    The suffix must be the canonical marketplace name from marketplace.json,
    not the registry YAML key.
    """
    from agent_profile.renderers.claude import ClaudeRenderer

    manifest, market_root = _make_manifest_with_native(tmp_path, "milknado")
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    data = json.loads((target / ".claude" / "settings.json").read_text())
    enabled = data.get("enabledPlugins", {})
    # Key must be milknado@milknado (plugin_name@marketplace_name)
    assert "milknado@milknado" in enabled, (
        f"enabledPlugins must have 'milknado@milknado' key: {enabled}"
    )
    assert enabled["milknado@milknado"] is True


def test_claude_renderer_marketplace_add_uses_marketplace_root(tmp_path):
    """claude plugin marketplace add is called with the marketplace root, not payload.

    The marketplace root (with .claude-plugin/marketplace.json) is what
    claude CLI needs; passing the payload dir fails with 'Marketplace file not found'.
    """
    from agent_profile.renderers.claude import ClaudeRenderer

    manifest, market_root = _make_manifest_with_native(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    calls = mock_run.call_args_list
    marketplace_calls = [
        c for c in calls
        if "marketplace" in str(c) and "add" in str(c)
    ]
    assert marketplace_calls, f"Expected marketplace add call, got: {calls}"

    # The path passed must be the marketplace root (which has .claude-plugin/marketplace.json)
    for call in marketplace_calls:
        args = call.args[0] if call.args else list(call.kwargs.get("args", []))
        passed_path = args[-1] if args else ""
        assert passed_path == str(market_root), (
            f"marketplace add must use marketplace root {market_root}, "
            f"got: {passed_path}"
        )
        # Verify the passed path actually has the required marketplace.json
        assert (Path(passed_path) / ".claude-plugin" / "marketplace.json").is_file(), (
            f"Passed path {passed_path} has no .claude-plugin/marketplace.json"
        )


def test_claude_renderer_skips_native_plugin_skills(tmp_path):
    """ClaudeRenderer._write_skills skips items with _from_native_plugin flag."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    payload = tmp_path / "payload"
    skill_src = payload / "skills" / "my-skill"
    skill_src.mkdir(parents=True)
    (skill_src / "SKILL.md").write_text("skill content")

    manifest, market_root = _make_manifest_with_native(tmp_path)
    manifest = Manifest(
        name="base",
        skills=[{
            "name": "my-skill",
            "path": "skills/my-skill",
            "_source_dir": str(payload),
            "_from_native_plugin": True,
        }],
        native_plugins=manifest.native_plugins,
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    skill_out = target / ".claude" / "skills" / "my-skill"
    assert not skill_out.exists(), (
        f"Native plugin skill must not be written to user scope: {skill_out}"
    )


def test_claude_renderer_dedup_mcp_not_in_user_scope(tmp_path):
    """After DEDUP, an MCP with harnesses=[codex] is not rendered for Claude.

    This test is NOT vacuous: the MCP item has harnesses=[codex,opencode]
    (claude was in the original harnesses but removed by DEDUP). The renderer
    must not register it at user scope for Claude. If DEDUP is removed and the
    item regains harnesses=[claude,codex,opencode], this test would FAIL because
    the plugin .mcp.json would contain milknado.
    """
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    market_root = tmp_path / "market"
    (market_root / ".claude-plugin").mkdir(parents=True)
    (market_root / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps({"name": "milknado", "owner": {"name": "t"}, "plugins": [{"name": "milknado", "source": "./plugins/milknado"}]})
    )
    payload = market_root / "plugins" / "milknado"
    payload.mkdir(parents=True)
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"milknado": {"command": "uvx", "args": ["milknado-mcp"]}}})
    )

    # Manifest with MCP that originally had claude in harnesses but DEDUP removed it.
    # harnesses=["codex", "opencode"] — claude NOT present.
    mcp_item = {
        "name": "milknado",
        "command": "uvx",
        "args": ["milknado-mcp"],
        "harnesses": ["codex", "opencode"],  # claude removed by DEDUP
        "_source_dir": str(payload),
    }
    manifest = Manifest(
        name="base",
        mcps=[mcp_item],
        native_plugins=[{
            "name": "milknado",
            "claude_native": True,
            "marketplace_root": str(market_root),
            "marketplace_name": "milknado",
            "description": "Mikado engine",
        }],
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    # The plugin tree .mcp.json should NOT list milknado as a user-scope MCP entry.
    # mcp_scope="plugin" (default) writes .mcp.json in the plugin dir, not user-scope.
    # The key assertion: milknado is ABSENT from user-scope MCP registration.
    # We verify this by checking the plugin dir's .mcp.json contains only plugin-scoped
    # servers (written by _write_mcp_json from manifest.mcps filtered by harnesses).
    plugin_mcp = target / ".claude" / "plugins" / "local" / "base" / ".mcp.json"
    if plugin_mcp.is_file():
        mcp_data = json.loads(plugin_mcp.read_text())
        servers = mcp_data.get("mcpServers", {})
        # milknado must not appear in the plugin .mcp.json (harnesses=[codex,opencode])
        # If DEDUP is removed, this would fail because claude would be in harnesses
        assert "milknado" not in servers, (
            f"milknado appears in plugin .mcp.json — DEDUP is not working: {servers}"
        )


# ── D: Latent dedup guards on agents/commands/hooks ──────────────────────

def test_claude_renderer_skips_native_agents(tmp_path):
    """ClaudeRenderer._write_agents skips items with _from_native_plugin flag."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    payload = tmp_path / "payload"
    payload.mkdir()
    agent_body = payload / "my-agent.md"
    agent_body.write_text("# Agent")

    manifest, market_root = _make_manifest_with_native(tmp_path)
    manifest = Manifest(
        name="base",
        agents=[{
            "name": "my-agent",
            "body_path": "my-agent.md",
            "_source_dir": str(payload),
            "_from_native_plugin": True,
        }],
        native_plugins=manifest.native_plugins,
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    agent_out = target / ".claude" / "agents" / "my-agent.md"
    assert not agent_out.exists(), (
        f"Native plugin agent must not be written to user scope: {agent_out}"
    )


def test_claude_renderer_skips_native_commands(tmp_path):
    """ClaudeRenderer._write_commands skips items with _from_native_plugin flag."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    payload = tmp_path / "payload"
    payload.mkdir()
    (payload / "my-cmd.md").write_text("# cmd")

    manifest, market_root = _make_manifest_with_native(tmp_path)
    manifest = Manifest(
        name="base",
        commands=[{
            "name": "my-cmd",
            "body_path": "my-cmd.md",
            "_source_dir": str(payload),
            "_from_native_plugin": True,
        }],
        native_plugins=manifest.native_plugins,
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        ClaudeRenderer().render(manifest, target)

    plugin_dir = target / ".claude" / "plugins" / "local" / "base"
    cmd_out = plugin_dir / "commands" / "my-cmd.md"
    assert not cmd_out.exists(), (
        f"Native plugin command must not be written to plugin tree: {cmd_out}"
    )


# ── clean() un-merge ──────────────────────────────────────────────────────────

def test_clean_removes_native_plugin_marketplace_entry(tmp_path):
    """clean() removes the native plugin's extraKnownMarketplaces entry."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    target = tmp_path / "home"
    (target / ".claude").mkdir(parents=True)
    settings_path = target / ".claude" / "settings.json"
    # Include a user-owned key so the file survives after our entries are removed.
    settings_path.write_text(json.dumps({
        "extraKnownMarketplaces": {
            "milknado": {"source": {"source": "directory", "path": "/market/root"}}
        },
        "enabledPlugins": {"milknado@milknado": True},
        "userKey": "preserved",
    }) + "\n")

    manifest = Manifest(
        name="base",
        native_plugins=[{
            "name": "milknado",
            "claude_native": True,
            "marketplace_root": "/market/root",
            "marketplace_name": "milknado",
            "description": "",
        }],
    )

    ClaudeRenderer().clean(manifest, target)

    assert settings_path.is_file()
    data = json.loads(settings_path.read_text())
    assert "milknado" not in data.get("extraKnownMarketplaces", {})
    assert "userKey" in data  # user-owned key survived


def test_clean_removes_native_plugin_enabled_plugins_entry(tmp_path):
    """clean() removes the native plugin's enabledPlugins <name>@<marketplace_name> entry."""
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
        native_plugins=[{
            "name": "milknado",
            "claude_native": True,
            "marketplace_root": "/market/root",
            "marketplace_name": "milknado",
            "description": "",
        }],
    )

    ClaudeRenderer().clean(manifest, target)

    data = json.loads(settings_path.read_text())
    enabled = data.get("enabledPlugins", {})
    milknado_keys = [k for k in enabled if "milknado" in k]
    assert milknado_keys == [], f"milknado entries should be removed: {enabled}"
    assert "other-plugin@local" in enabled


# ── Phase 4: permission-rule rewrite for hallouminate-native ───────────────────

def test_claude_renderer_rewrites_native_mcp_permission_rule(tmp_path):
    """When hallouminate is claude-native, the canonical mcp__hallouminate__*
    allow rule is rewritten to the plugin-namespaced form in settings.json;
    a non-native server's rule (tilth) is left bare."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    manifest = Manifest(
        name="base",
        settings={
            "permissions_allow": ["mcp__hallouminate__*", "mcp__tilth__*"],
            "permissions_deny": [],
        },
        native_plugins=[{
            "name": "hallouminate",
            "claude_native": True,
            "codex_native": True,
            "copilot_native": True,
            "servers": ["hallouminate"],
            "marketplace_root": str(tmp_path / "mkt"),
            "marketplace_name": "hallouminate",
            "description": "wiki",
        }],
    )
    (tmp_path / "mkt" / ".claude-plugin").mkdir(parents=True)
    (tmp_path / "mkt" / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps({"name": "hallouminate", "owner": {"name": "t"},
                    "plugins": [{"name": "hallouminate", "source": "."}]})
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        ClaudeRenderer().render(manifest, target)

    data = json.loads((target / ".claude" / "settings.json").read_text())
    allow = data["permissions"]["allow"]
    assert "mcp__plugin_hallouminate_hallouminate__*" in allow, allow
    assert "mcp__hallouminate__*" not in allow, allow
    assert "mcp__tilth__*" in allow, "non-native server rule must stay bare"


def test_claude_renderer_rewrites_skill_allowed_tools(tmp_path):
    """A skill's inline allowed-tools mcp__hallouminate__* is re-namespaced in the
    claude skill copy when hallouminate is native; tilth + non-MCP entries stay."""
    from agent_profile.parse import Manifest
    from agent_profile.renderers.claude import ClaudeRenderer

    payload = tmp_path / "payload"
    skill_src = payload / "skills" / "rennet"
    skill_src.mkdir(parents=True)
    (skill_src / "SKILL.md").write_text(
        "---\nname: rennet\n"
        "allowed-tools: Task, Skill, Bash(gh:*), mcp__hallouminate__*, mcp__tilth__*\n"
        "---\nbody\n"
    )
    manifest = Manifest(
        name="base",
        skills=[{
            "name": "rennet",
            "path": "skills/rennet",
            "_source_dir": str(payload),
            "harnesses": ["claude"],
        }],
        native_plugins=[{
            "name": "hallouminate",
            "claude_native": True,
            "codex_native": False,
            "copilot_native": False,
            "servers": ["hallouminate"],
            "marketplace_root": str(tmp_path / "mkt"),
            "marketplace_name": "hallouminate",
            "description": "wiki",
        }],
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        ClaudeRenderer().render(manifest, target)

    text = (target / ".claude" / "skills" / "rennet" / "SKILL.md").read_text()
    assert "mcp__plugin_hallouminate_hallouminate__*" in text, text
    assert "mcp__hallouminate__*" not in text, text
    assert "mcp__tilth__*" in text
    assert "Task, Skill, Bash(gh:*)" in text  # non-MCP entries preserved in order


# ── Regression: native_plugins must inherit through includes ───────────────

def test_native_plugins_inherit_through_includes(tmp_path, monkeypatch):
    """An outer profile that ``include``s a base carrying native plugins must
    inherit them.

    Regression for the silent-disable bug (issue #356): ``native_plugins`` was
    in the outermost-profile-only override list, so ``parse_manifest(global)``
    — ``global`` includes ``base`` but declares no own ``native_plugins`` —
    clobbered base's inherited [milknado, hallouminate] back to ``[]``. The
    live installer runs ``ap install global``, so every native plugin silently
    vanished from the rendered settings. native_plugins must merge across
    includes like mcps/agents/skills/hooks, not get overridden like name.
    """
    from agent_profile.parse import parse_manifest

    repo = tmp_path / "repo"
    repo.mkdir()
    market_root = _make_marketplace(
        tmp_path, "milknado",
        [{"name": "milknado", "source": "./plugins/milknado"}],
    )
    _make_payload(market_root, "./plugins/milknado", "milknado")
    _make_plugins_registry(repo, {"milknado": {
        "path": str(market_root),
        "harnesses": ["claude"],
        "claude_native": True,
    }})
    monkeypatch.setenv("DOTFILES_DIR", str(repo))

    profiles = repo / "profiles"
    base = profiles / "base"
    base.mkdir(parents=True)
    (base / "profile.yaml").write_text(
        "name: base\nregistries:\n  plugins: agents/plugins/registry.yaml\n"
    )
    outer = profiles / "outer"
    outer.mkdir()
    (outer / "profile.yaml").write_text("name: outer\ninclude: [base]\n")

    def resolver(name):
        d = profiles / name
        return d if d.is_dir() else None

    base_names = [p["name"] for p in parse_manifest(base, resolver).native_plugins]
    outer_names = [p["name"] for p in parse_manifest(outer, resolver).native_plugins]

    assert base_names == ["milknado"]
    assert outer_names == ["milknado"], (
        "outer profile including base must inherit base's native_plugins; "
        f"got {outer_names} (outermost-override clobbered the inherited value)"
    )
