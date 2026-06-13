"""test_ingest_plugins.py — _expand_plugins decomposer (spec: ap cross-harness plugin support).

Covers:
- _source_dir stamped at PAYLOAD ROOT (not repo root) — the highest-risk correctness rule.
  A test proves it fails under repo-root stamping.
- MCP ${VAR} passthrough (env literal, not substituted)
- Skills discovery including a references/ subdir (which must NOT become a skill)
- harnesses membership attached to the decomposed MCP
- gate_unless / optional handling
- Skill-name collision fails loud

Path model (mirrors real milknado):
  marketplace root: tmp_path/market/<name>  (has .claude-plugin/marketplace.json)
  payload root:     tmp_path/market/<name>/plugins/<name>  (has .mcp.json + skills/)
  registry path:    = marketplace root
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile.ingest import expand_registries
from agent_profile._validate import ParseError


# ─── fixture helpers ──────────────────────────────────────────────────────────


def _make_plugin_payload(
    root: Path,
    name: str,
    *,
    mcp_args: list | None = None,
    mcp_env: dict | None = None,
    skill_names: list[str] | None = None,
    skill_with_refs: str | None = None,
) -> Path:
    """Build a minimal plugin payload tree under ``root/<name>``.

    Returns the payload root path.
    """
    payload = root / name
    payload.mkdir(parents=True, exist_ok=True)

    # .mcp.json
    mcp_entry: dict = {
        "command": "uvx",
        "args": mcp_args or [f"{name}-mcp"],
    }
    if mcp_env:
        mcp_entry["env"] = mcp_env
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {name: mcp_entry}})
    )

    # skills/
    for skill in skill_names or []:
        d = payload / "skills" / skill
        d.mkdir(parents=True, exist_ok=True)
        (d / "SKILL.md").write_text(f"# {skill}\n")

    # skills with a references/ subdir (must not create a skill for the subdir)
    if skill_with_refs:
        d = payload / "skills" / skill_with_refs
        d.mkdir(parents=True, exist_ok=True)
        (d / "SKILL.md").write_text(f"# {skill_with_refs}\n")
        refs = d / "references"
        refs.mkdir()
        (refs / "flavor-presets.md").write_text("# flavor presets\n")

    return payload


def _wrap_in_marketplace(marketplace_root: Path, name: str, relative_source: str) -> Path:
    """Create a marketplace root with .claude-plugin/marketplace.json.

    The marketplace.json declares one plugin whose source is relative_source
    (e.g. './plugins/myplugin').

    Returns the marketplace_root.
    """
    cp = marketplace_root / ".claude-plugin"
    cp.mkdir(parents=True, exist_ok=True)
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": name,
            "owner": {"name": "test"},
            "plugins": [{"name": name, "source": relative_source}],
        })
    )
    return marketplace_root


def _make_plugin_with_marketplace(
    tmp_path: Path,
    name: str,
    *,
    mcp_args: list | None = None,
    mcp_env: dict | None = None,
    skill_names: list[str] | None = None,
    skill_with_refs: str | None = None,
) -> tuple[Path, Path]:
    """Create a marketplace root + payload for a plugin.

    Returns (marketplace_root, payload_root).
    marketplace_root/plugins/<name>/ is the payload.
    """
    marketplace_root = tmp_path / "market" / name
    marketplace_root.mkdir(parents=True, exist_ok=True)
    _wrap_in_marketplace(marketplace_root, name, f"./plugins/{name}")
    payload = _make_plugin_payload(
        marketplace_root / "plugins",
        name,
        mcp_args=mcp_args,
        mcp_env=mcp_env,
        skill_names=skill_names,
        skill_with_refs=skill_with_refs,
    )
    return marketplace_root, payload


def _make_plugins_registry(repo: Path, entries: dict) -> Path:
    """Write agents/plugins/registry.yaml and return the path."""
    reg = repo / "agents" / "plugins" / "registry.yaml"
    reg.parent.mkdir(parents=True, exist_ok=True)

    import yaml
    reg.write_text(yaml.dump({"plugins": entries}))
    return reg


# ─── tests: _source_dir stamping ─────────────────────────────────────────────


def test_source_dir_is_payload_root_not_repo_root(tmp_path):
    """_expand_plugins stamps _source_dir at the plugin payload root.

    This is the highest-risk correctness rule: renderers copy skill files via
    Path(item['_source_dir']) / path. If stamped at repo_root, they'd copy
    from the wrong tree (the dotfiles root, not the plugin).
    """
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path,
        "myplugin",
        skill_names=["cook"],
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    skill = next(s for s in out["skills"] if s["name"] == "cook")
    assert skill["_source_dir"] == str(payload), (
        f"Expected _source_dir={payload!r}, got {skill['_source_dir']!r}\n"
        "This test would pass under repo-root stamping if _source_dir == str(tmp_path)"
    )
    # Explicitly prove failure mode: repo root is wrong
    assert skill["_source_dir"] != str(tmp_path), (
        "_source_dir must NOT be repo root — renderers would copy from the wrong tree"
    )
    # Also confirm it's not the marketplace root
    assert skill["_source_dir"] != str(market_root), (
        "_source_dir must NOT be marketplace root — that dir has no .mcp.json"
    )


def test_source_dir_repo_root_stamping_copies_wrong_tree(tmp_path):
    """Prove that repo-root _source_dir would point at a non-existent file.

    If a renderer tried to open Path(repo_root) / 'skills/cook' it would find
    nothing — there is no 'skills/cook' at the repo root in this test. Only
    at the payload root.
    """
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path,
        "myplugin",
        skill_names=["cook"],
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    skill = next(s for s in out["skills"] if s["name"] == "cook")

    # With correct stamping: the skill dir resolves from the payload root
    correct_path = Path(skill["_source_dir"]) / skill["path"]
    assert correct_path.is_dir(), f"Skill dir not found at correct path: {correct_path}"
    assert (correct_path / "SKILL.md").is_file()

    # With WRONG (repo-root) stamping: the skill dir would NOT resolve
    wrong_path = Path(str(tmp_path)) / skill["path"]
    assert not wrong_path.is_dir(), (
        "Unexpected: skill dir also exists at repo root — test setup is wrong"
    )


# ─── tests: MCP decomposition ─────────────────────────────────────────────────


def test_mcp_decomposed_from_plugin(tmp_path):
    """A plugin's .mcp.json produces a decomposed MCP item."""
    market_root, payload = _make_plugin_with_marketplace(tmp_path, "myplugin")
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex", "opencode"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcp_names = [m["name"] for m in out["mcps"]]
    assert "myplugin" in mcp_names


def test_mcp_harnesses_from_plugin_registry_entry(tmp_path):
    """The harnesses list from the registry entry attaches to the decomposed MCP."""
    market_root, payload = _make_plugin_with_marketplace(tmp_path, "myplugin")
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex", "opencode", "cursor"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcp = next(m for m in out["mcps"] if m["name"] == "myplugin")
    assert mcp["harnesses"] == ["codex", "opencode", "cursor"]


def test_mcp_env_var_stays_literal_not_substituted(tmp_path):
    """${VAR} in plugin MCP env is carried through as a literal string.

    Same MCP-secret-passthrough rule as _expand_mcps: renderers receive the
    literal '${VAR}' so each harness expands it at launch (not pre-substituted).
    The var is provided in dotenv so ingest doesn't reject it as unset.
    The assertion proves the value in the MCP item is still the literal reference,
    not the resolved value — env expansion is the renderer's job at launch time.
    """
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path,
        "myplugin",
        mcp_env={"MY_SECRET": "${MY_SECRET}"},
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    # Provide MY_SECRET in dotenv so ingest doesn't reject it as unset.
    # The item's env value must still be '${MY_SECRET}', not the resolved value.
    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {"MY_SECRET": "runtime-secret"},
    )
    mcp = next(m for m in out["mcps"] if m["name"] == "myplugin")
    # The literal ${MY_SECRET} must survive — not substituted
    assert mcp["env"]["MY_SECRET"] == "${MY_SECRET}"


# ─── tests: skills discovery ──────────────────────────────────────────────────


def test_skills_discovered_from_plugin_payload(tmp_path):
    """Skills under plugin payload skills/<n>/SKILL.md are decomposed."""
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path,
        "myplugin",
        skill_names=["harvest", "load-roadmap"],
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    skill_names = [s["name"] for s in out["skills"]]
    assert "harvest" in skill_names
    assert "load-roadmap" in skill_names


def test_skills_references_subdir_not_treated_as_skill(tmp_path):
    """A references/ directory inside a skill must NOT generate its own skill item.

    milknado-config has skills/milknado-config/references/flavor-presets.md.
    The references/ dir lacks a SKILL.md so it must be skipped.
    """
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path,
        "myplugin",
        skill_with_refs="milknado-config",
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    skill_names = [s["name"] for s in out["skills"]]
    assert "milknado-config" in skill_names
    assert "references" not in skill_names


def test_skills_path_field_is_relative_to_payload(tmp_path):
    """Each skill item's 'path' field is relative to the payload root.

    Renderers compute: Path(item['_source_dir']) / item['path']
    So 'path' must be 'skills/<name>' (relative to payload, not repo).
    """
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path,
        "myplugin",
        skill_names=["cook"],
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    skill = next(s for s in out["skills"] if s["name"] == "cook")
    # path should be skills/cook (relative to payload root)
    assert skill["path"] == "skills/cook"
    # Full resolution must work
    full = Path(skill["_source_dir"]) / skill["path"]
    assert full.is_dir()


# ─── tests: gate_unless / optional ───────────────────────────────────────────


def test_gate_unless_propagates_to_mcp(tmp_path):
    """gate_unless from the plugin registry entry propagates to the MCP item."""
    market_root, payload = _make_plugin_with_marketplace(tmp_path, "myplugin")
    _make_plugins_registry(
        tmp_path,
        {
            "myplugin": {
                "path": str(market_root),
                "harnesses": ["codex"],
                "gate_unless": "MY_GATE",
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcp = next(m for m in out["mcps"] if m["name"] == "myplugin")
    assert mcp.get("gate_unless") == "MY_GATE"


# ─── tests: skill-name collision ──────────────────────────────────────────────


def test_skill_name_collision_with_existing_registry_fails_loud(tmp_path):
    """If a plugin skill name collides with an existing registry skill, error loud.

    Rule: no silent overwrite of shared skill tree.
    """
    # Local skills tree with 'cook'
    skills_dir = tmp_path / "skills"
    cook_dir = skills_dir / "cook"
    cook_dir.mkdir(parents=True)
    (cook_dir / "SKILL.md").write_text("# cook\n")

    # Plugin also exports 'cook'
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path,
        "myplugin",
        skill_names=["cook"],
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    with pytest.raises((ParseError, ValueError), match="[Cc]ollision|duplicate|already"):
        expand_registries(
            {
                "skills": ["skills/"],  # the existing local skills tree
                "plugins": "agents/plugins/registry.yaml",
            },
            tmp_path,
            {},
        )


# ─── tests: plugin with no skills (MCP only) ─────────────────────────────────


def test_plugin_with_no_skills_directory(tmp_path):
    """A plugin with no skills/ tree still decomposes the MCP."""
    market_root = tmp_path / "market" / "mcp-only"
    _wrap_in_marketplace(market_root, "mcp-only", "./plugins/mcp-only")
    payload = market_root / "plugins" / "mcp-only"
    payload.mkdir(parents=True)
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"mcp-only": {"command": "uvx", "args": ["mcp-only"]}}})
    )
    _make_plugins_registry(
        tmp_path,
        {"mcp-only": {"path": str(market_root), "harnesses": ["crush"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcp_names = [m["name"] for m in out["mcps"]]
    assert "mcp-only" in mcp_names
    assert out["skills"] == []


# ─── tests: milknado fixture (representative golden) ──────────────────────────


@pytest.fixture
def milknado_market(tmp_path):
    """A fixture that mirrors the milknado marketplace + payload structure.

    Hermetic: does not read ~/Dev/milknado — uses a committed test fixture.
    marketplace root: tmp_path/market/milknado  (has .claude-plugin/marketplace.json)
    payload root: market_root/plugins/milknado  (has .mcp.json + skills/)
    Skills: harvest, load-roadmap, milknado-config (with references/ subdir).
    MCP: uvx milknado-mcp (the portable form, post-migration).
    Returns (marketplace_root, payload_root).
    """
    market_root = tmp_path / "market" / "milknado"
    _wrap_in_marketplace(market_root, "milknado", "./plugins/milknado")
    payload = market_root / "plugins" / "milknado"
    payload.mkdir(parents=True)

    # .mcp.json — portable uvx form (post-migration, NOT --from path)
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"milknado": {"command": "uvx", "args": ["milknado-mcp"]}}})
    )

    # skills/
    for skill in ["harvest", "load-roadmap"]:
        d = payload / "skills" / skill
        d.mkdir(parents=True)
        (d / "SKILL.md").write_text(f"# {skill}\n")

    # milknado-config with references/ subdir
    mc = payload / "skills" / "milknado-config"
    mc.mkdir(parents=True)
    (mc / "SKILL.md").write_text("# milknado-config\n")
    refs = mc / "references"
    refs.mkdir()
    (refs / "flavor-presets.md").write_text("# flavor presets\n")

    return market_root, payload


def test_milknado_mcp_portable_uvx(milknado_market, tmp_path):
    """milknado MCP decomposes with the portable uvx milknado-mcp args."""
    market_root, payload = milknado_market
    _make_plugins_registry(
        tmp_path,
        {
            "milknado": {
                "path": str(market_root),
                "harnesses": ["claude", "codex", "opencode", "cursor", "copilot", "crush"],
                "claude_native": True,
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcp = next(m for m in out["mcps"] if m["name"] == "milknado")
    assert mcp["command"] == "uvx"
    assert mcp["args"] == ["milknado-mcp"]


def test_milknado_three_skills_discovered(milknado_market, tmp_path):
    """milknado decomposes into exactly 3 skills."""
    market_root, payload = milknado_market
    _make_plugins_registry(
        tmp_path,
        {
            "milknado": {
                "path": str(market_root),
                "harnesses": ["claude", "codex", "opencode", "cursor", "copilot", "crush"],
            }
        },
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    skill_names = {s["name"] for s in out["skills"]}
    assert skill_names == {"harvest", "load-roadmap", "milknado-config"}
    assert "references" not in skill_names


def test_milknado_source_dir_at_payload_not_repo(milknado_market, tmp_path):
    """All milknado decomposed items have _source_dir at the payload, not repo root."""
    market_root, payload = milknado_market
    _make_plugins_registry(
        tmp_path,
        {"milknado": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    for mcp in out["mcps"]:
        if mcp["name"] == "milknado":
            assert mcp["_source_dir"] == str(payload)
    for skill in out["skills"]:
        assert skill["_source_dir"] == str(payload), (
            f"Skill {skill['name']!r} has wrong _source_dir: {skill['_source_dir']!r}"
        )
