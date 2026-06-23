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


# ─── tests: malformed payload .mcp.json fails loud (review fix M1) ────────────


def test_malformed_mcp_json_fails_loud(tmp_path):
    """A payload .mcp.json that is not valid JSON raises ParseError instead of
    being silently swallowed into an empty mapping (which would drop every MCP
    server with no diagnostic). Parity with the marketplace.json parse handler.
    """
    market_root = tmp_path / "market" / "myplugin"
    _wrap_in_marketplace(market_root, "myplugin", "./plugins/myplugin")
    payload = market_root / "plugins" / "myplugin"
    payload.mkdir(parents=True)
    (payload / ".mcp.json").write_text("{ this is not valid json ")
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    with pytest.raises(ParseError, match=r"\.mcp\.json"):
        expand_registries(
            {"plugins": "agents/plugins/registry.yaml"},
            tmp_path,
            {},
        )


# ─── tests: marketplace.json source path safety (review fix L1) ──────────────


@pytest.mark.parametrize("bad_source", ["../escape", "/abs/payload", "foo/../bar"])
def test_marketplace_source_rejects_traversal_and_absolute(tmp_path, bad_source):
    """A marketplace.json plugin `source` containing '..' or an absolute path is
    rejected loud. `lstrip('./')` silently collapsed these; PurePosixPath
    normalization plus an explicit guard rejects them instead.
    """
    market_root = tmp_path / "market" / "myplugin"
    cp = market_root / ".claude-plugin"
    cp.mkdir(parents=True)
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": "myplugin",
            "plugins": [{"name": "myplugin", "source": bad_source}],
        })
    )
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    with pytest.raises(ParseError, match="must be a relative path"):
        expand_registries(
            {"plugins": "agents/plugins/registry.yaml"},
            tmp_path,
            {},
        )


# ─── tests: MCP-name collision fails loud (review fix L4) ────────────────────


def test_plugin_mcp_name_collision_with_registry_fails_loud(tmp_path):
    """A plugin MCP server name colliding with an existing registry MCP errors
    loud — the same guarantee the skill path already enforces. Silent shadowing
    (last writer wins in the renderer servers dict) is what this prevents.
    """
    import yaml

    mcp_reg = tmp_path / "agents" / "mcp" / "registry.yaml"
    mcp_reg.parent.mkdir(parents=True, exist_ok=True)
    mcp_reg.write_text(yaml.dump({"mcps": {"myplugin": {"command": "x", "args": []}}}))

    # Plugin exports an MCP server named 'myplugin' (helper default) → collision.
    market_root, _ = _make_plugin_with_marketplace(tmp_path, "myplugin")
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    with pytest.raises(ParseError, match="[Cc]ollision"):
        expand_registries(
            {
                "mcps": "agents/mcp/registry.yaml",
                "plugins": "agents/plugins/registry.yaml",
            },
            tmp_path,
            {},
        )


# ─── tests: multi-plugin marketplace decomposes only the named plugin (L2) ───


def test_multi_plugin_marketplace_decomposes_only_matching_name(tmp_path):
    """When a marketplace.json lists multiple plugins, only the payload whose
    name matches the registry key is decomposed — not every plugin (which would
    double-expand and pull in unrequested primitives).
    """
    market_root = tmp_path / "market" / "multi"
    cp = market_root / ".claude-plugin"
    cp.mkdir(parents=True)
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": "multi",
            "plugins": [
                {"name": "alpha", "source": "./plugins/alpha"},
                {"name": "beta", "source": "./plugins/beta"},
            ],
        })
    )
    for pname in ("alpha", "beta"):
        p = market_root / "plugins" / pname
        p.mkdir(parents=True)
        (p / ".mcp.json").write_text(
            json.dumps({"mcpServers": {pname: {"command": "uvx", "args": [pname]}}})
        )
        sd = p / "skills" / f"{pname}-skill"
        sd.mkdir(parents=True)
        (sd / "SKILL.md").write_text(f"# {pname}-skill\n")

    # Registry names only 'alpha'.
    _make_plugins_registry(
        tmp_path,
        {"alpha": {"path": str(market_root), "harnesses": ["codex"]}},
    )

    out = expand_registries(
        {"plugins": "agents/plugins/registry.yaml"},
        tmp_path,
        {},
    )
    mcp_names = {m["name"] for m in out["mcps"]}
    skill_names = {s["name"] for s in out["skills"]}
    assert mcp_names == {"alpha"}, f"beta must not decompose: {mcp_names}"
    assert skill_names == {"alpha-skill"}, f"beta-skill must not decompose: {skill_names}"


# ─── tests: registry key must match a marketplace plugin name (review fix AM1) ─


def test_registry_key_not_matching_marketplace_plugin_name_fails_loud(tmp_path):
    """When the registry key names no plugins[] entry in the marketplace.json,
    ingest raises ParseError instead of silently decomposing to nothing — which,
    for a claude_native entry, would still register a marketplace with no
    primitives behind it.
    """
    market_root = tmp_path / "market" / "milknado"
    cp = market_root / ".claude-plugin"
    cp.mkdir(parents=True)
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": "milknado",
            "plugins": [{"name": "milknado", "source": "./plugins/milknado"}],
        })
    )
    # Payload exists, but the registry key (below) is 'milknado-engine' ≠ 'milknado'.
    p = market_root / "plugins" / "milknado"
    p.mkdir(parents=True)
    (p / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"milknado": {"command": "uvx", "args": ["milknado-mcp"]}}})
    )
    _make_plugins_registry(
        tmp_path,
        {
            "milknado-engine": {
                "path": str(market_root),
                "claude_native": True,
                "harnesses": ["codex"],
            }
        },
    )

    with pytest.raises(ParseError, match=r"no plugins\[\] entry named"):
        out = expand_registries(
            {"plugins": "agents/plugins/registry.yaml"},
            tmp_path,
            {},
        )
        # Guard against a silent-drop regression: if no raise, the native
        # descriptor would still have been emitted with empty primitives.
        assert out["native_plugins"] == [], "claude_native descriptor emitted with no payload"


# ─── tests: metadata.pluginRoot prefixes source (hallouminate shape) ─────────


def _wrap_in_marketplace_plugin_root(
    marketplace_root: Path, name: str, plugin_root: str, source: str
) -> Path:
    """marketplace.json with metadata.pluginRoot — the hallouminate manifest shape.

    pluginRoot is a base dir prefixed onto plugins[].source, so the payload lives
    at marketplace_root/<plugin_root>/<source>. (milknado, by contrast, inlines
    the whole path in source and sets no pluginRoot.)
    """
    cp = marketplace_root / ".claude-plugin"
    cp.mkdir(parents=True, exist_ok=True)
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": name,
            "owner": {"name": "test"},
            "metadata": {"pluginRoot": plugin_root},
            "plugins": [{"name": name, "source": source}],
        })
    )
    return marketplace_root


def test_plugin_root_metadata_resolves_payload(tmp_path):
    """metadata.pluginRoot prefixes plugins[].source — hallouminate's manifest shape.

    hallouminate uses pluginRoot "./plugins" + source "./hallouminate", so the
    payload is at <market>/plugins/hallouminate. Without pluginRoot support the
    decomposer resolved <market>/hallouminate and silently decomposed nothing
    (name matched, so the no-match guard never fired).
    """
    market_root = tmp_path / "market" / "hallou"
    market_root.mkdir(parents=True)
    _wrap_in_marketplace_plugin_root(market_root, "hallou", "./plugins", "./hallou")
    payload = _make_plugin_payload(
        market_root / "plugins", "hallou", skill_names=["wiki-query", "wiki-init"]
    )
    _make_plugins_registry(
        tmp_path, {"hallou": {"path": str(market_root), "harnesses": ["codex"]}}
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})

    assert "hallou" in {m["name"] for m in out["mcps"]}, "MCP not decomposed under pluginRoot"
    assert {s["name"] for s in out["skills"]} == {"wiki-query", "wiki-init"}
    # _source_dir stamped at the pluginRoot-resolved payload, NOT <market>/hallou
    mcp = next(m for m in out["mcps"] if m["name"] == "hallou")
    assert mcp["_source_dir"] == str(payload)
    assert Path(mcp["_source_dir"]) == market_root / "plugins" / "hallou"


def test_plugin_root_absent_resolves_relative_to_marketplace_root(tmp_path):
    """No metadata.pluginRoot → source resolves relative to the marketplace root
    (milknado shape). pluginRoot support must not regress this path.
    """
    market_root, payload = _make_plugin_with_marketplace(
        tmp_path, "myplugin", skill_names=["cook"]
    )
    _make_plugins_registry(
        tmp_path, {"myplugin": {"path": str(market_root), "harnesses": ["codex"]}}
    )
    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    skill = next(s for s in out["skills"] if s["name"] == "cook")
    assert skill["_source_dir"] == str(payload)


@pytest.mark.parametrize("bad_root", ["../escape", "/abs/root", "foo/../bar"])
def test_plugin_root_rejects_traversal_and_absolute(tmp_path, bad_root):
    """metadata.pluginRoot gets the same traversal/absolute rejection as source —
    both feed _resolve_market_relative."""
    market_root = tmp_path / "market" / "p"
    market_root.mkdir(parents=True)
    _wrap_in_marketplace_plugin_root(market_root, "p", bad_root, "./p")
    _make_plugins_registry(
        tmp_path, {"p": {"path": str(market_root), "harnesses": ["codex"]}}
    )
    with pytest.raises(ParseError, match="must be a relative path"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_plugin_root_empty_string_falls_back_to_marketplace_root(tmp_path):
    """An explicit metadata.pluginRoot: "" resolves source against the marketplace
    root (the empty-`rel` → `base` branch in _resolve_market_relative), identical
    to omitting pluginRoot entirely.
    """
    market_root = tmp_path / "market" / "e"
    market_root.mkdir(parents=True)
    _wrap_in_marketplace_plugin_root(market_root, "e", "", "./plugins/e")
    payload = _make_plugin_payload(market_root / "plugins", "e", skill_names=["s1"])
    _make_plugins_registry(
        tmp_path, {"e": {"path": str(market_root), "harnesses": ["codex"]}}
    )
    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    skill = next(s for s in out["skills"] if s["name"] == "s1")
    assert skill["_source_dir"] == str(payload)


def test_plugin_root_non_string_fails_loud_with_parse_error(tmp_path):
    """A non-string metadata.pluginRoot raises ParseError (with the plugin name),
    not a raw TypeError from PurePosixPath — parity with every other marketplace
    parse failure in the loop.
    """
    market_root = tmp_path / "market" / "p"
    cp = market_root / ".claude-plugin"
    cp.mkdir(parents=True)
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": "p",
            "metadata": {"pluginRoot": ["not", "a", "string"]},
            "plugins": [{"name": "p", "source": "./p"}],
        })
    )
    _make_plugins_registry(
        tmp_path, {"p": {"path": str(market_root), "harnesses": ["codex"]}}
    )
    with pytest.raises(ParseError, match="must be a string"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


# ─── tests: claude_native gates the decomposed-MCP claude namespace ───────────


@pytest.mark.parametrize("native,claude_kept", [(False, True), (True, False)])
def test_claude_native_controls_claude_in_decomposed_mcp_harnesses(
    tmp_path, native, claude_kept
):
    """claude_native gates whether `claude` survives in the decomposed MCP's
    harnesses — the invariant behind hallouminate's claude_native: false.

    false → claude retained → bare mcp__<server>__* tool namespace (preserves
            mcp__hallouminate__* that the global CLAUDE.md routing relies on).
    true  → claude deduped → Claude gets the server via the native marketplace
            install (plugin-scoped mcp__plugin_<name>_<server>__*).
    """
    market_root, _ = _make_plugin_with_marketplace(tmp_path, "myplugin")
    _make_plugins_registry(
        tmp_path,
        {
            "myplugin": {
                "path": str(market_root),
                "harnesses": ["claude", "codex"],
                "claude_native": native,
            }
        },
    )
    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    mcp = next(m for m in out["mcps"] if m["name"] == "myplugin")
    assert ("claude" in mcp["harnesses"]) is claude_kept


# ─── tests: git source (portability — no ~/Dev checkout assumption) ────────────────


def _make_local_git_repo(repo_dir: Path, name: str) -> Path:
    """Create a local bare-ish git repo usable as a file:// remote.

    Initialises a real git repo at repo_dir, commits a minimal
    milknado-style plugin layout (marketplace.json + payload .mcp.json +
    one skill), and returns the repo_dir path.  Tests point 'git:' at this
    path so no network access is needed.
    """
    import subprocess

    repo_dir.mkdir(parents=True, exist_ok=True)

    # Minimal plugin layout
    cp = repo_dir / ".claude-plugin"
    cp.mkdir()
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": name,
            "plugins": [{"name": name, "source": f"./plugins/{name}"}],
        })
    )
    payload = repo_dir / "plugins" / name
    payload.mkdir(parents=True)
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {name: {"command": "uvx", "args": [f"{name}-mcp"]}}})
    )
    skill_dir = payload / "skills" / f"{name}-skill"
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text(f"# {name}-skill\n")

    env = {"GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@test",
           "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@test"}
    import os
    env.update(os.environ)
    subprocess.run(["git", "init"], cwd=repo_dir, check=True, capture_output=True)
    subprocess.run(["git", "checkout", "-b", "main"], cwd=repo_dir,
                   check=True, capture_output=True, env=env)
    subprocess.run(["git", "add", "-A"], cwd=repo_dir, check=True,
                   capture_output=True, env=env)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo_dir,
                   check=True, capture_output=True, env=env)
    return repo_dir


def test_git_source_resolves_mcp_and_skill(tmp_path):
    """A git: entry fetches the plugin and decomposes it correctly.

    Motivation: ap install base must not abort on a machine without the
    ~/Dev checkout. The git source clones into ~/.cache/ap/plugins/<name>
    and the existing decomposition runs unchanged from that cache dir.
    """
    repo = _make_local_git_repo(tmp_path / "repo", "myplugin")
    cache_root = tmp_path / "cache"
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {
            "git": str(repo),
            "branch": "main",
            "harnesses": ["codex"],
        }},
    )

    from agent_profile.ingest import _expand_plugins
    import yaml
    reg_path = tmp_path / "agents" / "plugins" / "registry.yaml"
    out_mcps, out_skills, _out_agents, _out_hooks, out_native = _expand_plugins(
        reg_path, tmp_path, {}, cache_root=cache_root
    )

    mcp_names = [m["name"] for m in out_mcps]
    assert "myplugin" in mcp_names, "MCP must decompose from git-cloned repo"
    skill_names = [s["name"] for s in out_skills]
    assert "myplugin-skill" in skill_names, "Skill must decompose from git-cloned repo"
    # Cache dir must exist and contain the plugin
    assert (cache_root / "myplugin" / ".claude-plugin" / "marketplace.json").is_file()


def test_git_source_subdir(tmp_path):
    """subdir: shifts the marketplace root inside the cloned repo.

    A plugin whose marketplace.json is nested under e.g. 'plugin-root/'
    in the repo uses subdir: 'plugin-root' to point the decomposer at the
    right directory instead of the repo root.
    """
    repo_dir = tmp_path / "repo"
    repo_dir.mkdir()
    # marketplace lives under a 'plugin-root' subdir
    subdir = repo_dir / "plugin-root"
    subdir.mkdir()
    cp = subdir / ".claude-plugin"
    cp.mkdir()
    (cp / "marketplace.json").write_text(
        json.dumps({
            "name": "nested",
            "plugins": [{"name": "nested", "source": "./plugins/nested"}],
        })
    )
    payload = subdir / "plugins" / "nested"
    payload.mkdir(parents=True)
    (payload / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"nested": {"command": "uvx", "args": ["nested-mcp"]}}})
    )

    import subprocess, os
    env = {"GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@test",
           "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@test"}
    env.update(os.environ)
    subprocess.run(["git", "init"], cwd=repo_dir, check=True, capture_output=True)
    subprocess.run(["git", "checkout", "-b", "main"], cwd=repo_dir,
                   check=True, capture_output=True, env=env)
    subprocess.run(["git", "add", "-A"], cwd=repo_dir, check=True,
                   capture_output=True, env=env)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo_dir,
                   check=True, capture_output=True, env=env)

    cache_root = tmp_path / "cache"
    _make_plugins_registry(
        tmp_path,
        {"nested": {
            "git": str(repo_dir),
            "branch": "main",
            "subdir": "plugin-root",
            "harnesses": ["codex"],
        }},
    )
    from agent_profile.ingest import _expand_plugins
    reg_path = tmp_path / "agents" / "plugins" / "registry.yaml"
    out_mcps, _, _, _, _ = _expand_plugins(reg_path, tmp_path, {}, cache_root=cache_root)
    assert "nested" in [m["name"] for m in out_mcps], (
        "MCP from nested subdir must decompose correctly"
    )
    # _source_dir must be inside the subdir, not at the cache root
    mcp = next(m for m in out_mcps if m["name"] == "nested")
    assert "plugin-root" in mcp["_source_dir"], (
        "_source_dir must resolve through subdir into the cloned repo"
    )


def test_git_and_path_both_set_raises(tmp_path):
    """Both git: and path: in one entry raises ParseError immediately.

    The mutual-exclusivity rule prevents ambiguous resolution and
    makes misconfigurations fail loud rather than silently picking one.
    """
    market_root, _ = _make_plugin_with_marketplace(tmp_path, "myplugin")
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {
            "git": "https://example.com/repo",
            "path": str(market_root),
            "harnesses": ["codex"],
        }},
    )
    with pytest.raises(ParseError, match="exactly one of"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_neither_git_nor_path_raises(tmp_path):
    """An entry with neither git: nor path: raises ParseError immediately.

    A bare entry name with only 'harnesses' is almost always a typo;
    fail loud rather than silently decomposing nothing.
    """
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {"harnesses": ["codex"]}},
    )
    with pytest.raises(ParseError, match="exactly one of"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_git_branch_defaults_to_main(tmp_path):
    """When branch: is omitted, 'main' is used.

    A plugin entry with only git: (no branch:) must still clone from
    the 'main' branch and decompose correctly.
    """
    repo = _make_local_git_repo(tmp_path / "repo", "myplugin")
    cache_root = tmp_path / "cache"
    _make_plugins_registry(
        tmp_path,
        {"myplugin": {
            "git": str(repo),
            # no branch: — default must be 'main'
            "harnesses": ["codex"],
        }},
    )
    from agent_profile.ingest import _expand_plugins
    reg_path = tmp_path / "agents" / "plugins" / "registry.yaml"
    out_mcps, _, _, _, _ = _expand_plugins(reg_path, tmp_path, {}, cache_root=cache_root)
    assert "myplugin" in [m["name"] for m in out_mcps], (
        "branch defaults to 'main'; clone must succeed without explicit branch:"
    )


def test_git_cache_reuse_when_network_fails(tmp_path):
    """If the network fetch fails but a populated cache exists, use the cache.

    Machines without network access (or with the repo gone) must not abort
    ap install base as long as the cache is populated.
    """
    from agent_profile.ingest import _resolve_git_plugin

    # Seed a populated cache dir (simulates a prior successful clone).
    cache_dir = tmp_path / "cache" / "myplugin"
    cache_dir.mkdir(parents=True)
    (cache_dir / "sentinel.txt").write_text("cached")

    # Pointing at a non-existent URL; fetch will fail.
    result = _resolve_git_plugin("https://invalid.example/nope", "main", cache_dir)
    # Must return the cache_dir, not raise.
    assert result == cache_dir
    # Cached content must still be intact.
    assert (cache_dir / "sentinel.txt").is_file()


# ─── codex_native cross-harness install ────────────────────────────────────────
# Mirrors the claude_native ingest contract: codex_native strips `codex` from the
# decomposed MCP harnesses, stamps a SEPARATE _from_codex_native_plugin skill flag
# (not _from_native_plugin), and emits a native descriptor carrying codex_native.


def test_codex_native_strips_codex_from_mcp_harnesses(tmp_path):
    """DEDUP: codex is removed from decomposed MCP harnesses for codex_native.

    Codex gets the plugin via its native marketplace install; leaving codex in
    the decomposed harnesses would double-deliver the MCP into config.toml.
    """
    _make_plugin_with_marketplace(tmp_path, "milknado")
    _make_plugins_registry(
        tmp_path,
        {"milknado": {
            "path": str(tmp_path / "market" / "milknado"),
            "harnesses": ["claude", "codex", "opencode"],
            "codex_native": True,
        }},
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    mcps = out["mcps"]
    assert len(mcps) == 1
    harnesses = mcps[0].get("harnesses", [])
    assert "codex" not in harnesses, f"codex should be excluded: {harnesses}"
    assert "claude" in harnesses, "claude must remain (claude_native not set)"
    assert "opencode" in harnesses


def test_codex_native_and_claude_native_strip_both(tmp_path):
    """When both native flags are set, both harnesses are stripped independently."""
    _make_plugin_with_marketplace(tmp_path, "milknado")
    _make_plugins_registry(
        tmp_path,
        {"milknado": {
            "path": str(tmp_path / "market" / "milknado"),
            "harnesses": ["claude", "codex", "opencode"],
            "claude_native": True,
            "codex_native": True,
        }},
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    harnesses = out["mcps"][0].get("harnesses", [])
    assert harnesses == ["opencode"], f"both native harnesses must be stripped: {harnesses}"


def test_codex_native_skills_carry_codex_flag_only(tmp_path):
    """codex_native skills carry _from_codex_native_plugin, NOT _from_native_plugin.

    Reusing the claude flag would make the claude renderer wrongly skip a
    codex-only-native plugin's skills. The two flags must stay independent.
    """
    _make_plugin_with_marketplace(
        tmp_path, "milknado", skill_names=["milknado-skill"]
    )
    _make_plugins_registry(
        tmp_path,
        {"milknado": {
            "path": str(tmp_path / "market" / "milknado"),
            "harnesses": ["claude", "codex"],
            "codex_native": True,
        }},
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    skills = out["skills"]
    assert len(skills) == 1
    assert skills[0].get("_from_codex_native_plugin") is True
    assert "_from_native_plugin" not in skills[0], (
        "codex-only-native must NOT stamp the claude flag — "
        "that would hide the skill from the claude renderer"
    )


def test_codex_native_descriptor_carries_codex_flag(tmp_path):
    """codex_native=True produces a native_plugins record with codex_native true."""
    _make_plugin_with_marketplace(tmp_path, "milknado")
    _make_plugins_registry(
        tmp_path,
        {"milknado": {
            "path": str(tmp_path / "market" / "milknado"),
            "harnesses": ["codex"],
            "codex_native": True,
        }},
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    native = out["native_plugins"]
    assert len(native) == 1
    assert native[0]["codex_native"] is True
    assert native[0]["claude_native"] is False
    assert native[0]["name"] == "milknado"
    assert native[0]["marketplace_name"] == "milknado"


def test_codex_native_false_produces_no_native_record(tmp_path):
    """A plugin with neither native flag emits no native descriptor."""
    _make_plugin_with_marketplace(tmp_path, "plain")
    _make_plugins_registry(
        tmp_path,
        {"plain": {
            "path": str(tmp_path / "market" / "plain"),
            "harnesses": ["codex"],
        }},
    )

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})
    assert out.get("native_plugins", []) == []


# ─── plugin agents and hooks ─────────────────────────────────────────────────


def _write_plugin_agent(payload: Path, filename: str, frontmatter: dict | None = None, body: str = "Agent body\n") -> None:
    agents_dir = payload / "agents"
    agents_dir.mkdir(parents=True, exist_ok=True)
    if frontmatter is None:
        (agents_dir / filename).write_text(body)
        return
    import yaml
    (agents_dir / filename).write_text("---\n" + yaml.safe_dump(frontmatter, sort_keys=False) + "---\n" + body)


def _write_plugin_hook_manifest(
    payload: Path,
    *,
    command: str = "${CLAUDE_PLUGIN_ROOT}/hooks/foo.sh",
    event: str = "PostToolUse",
    matcher: str = "Write",
    hook_name: str = "foo.sh",
) -> None:
    plugin_dir = payload / ".claude-plugin"
    plugin_dir.mkdir(parents=True, exist_ok=True)
    hooks_dir = payload / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    (hooks_dir / hook_name).write_text("#!/bin/sh\necho hook\n")
    (plugin_dir / "plugin.json").write_text(json.dumps({
        "name": payload.name,
        "hooks": {
            event: [{
                "matcher": matcher,
                "hooks": [{"type": "command", "command": command, "timeout": 7, "async": True}],
            }]
        },
    }))


def test_agents_discovered_from_plugin_payload(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_agent(payload, "b.md", {"description": "B"})
    _write_plugin_agent(payload, "a.md", {"name": "alpha", "description": "A"})
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})

    assert [agent["name"] for agent in out["agents"]] == ["alpha", "b"]
    assert out["agents"][0]["body_path"] == "agents/a.md"
    assert out["agents"][0]["_source_dir"] == str(payload)
    assert out["agents"][0]["harnesses"] == ["claude", "codex", "opencode", "cursor", "copilot"]


def test_agent_frontmatter_metadata_is_normalized(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_agent(payload, "worker.md", {
        "name": "worker",
        "description": "Does work",
        "tools": "Read, Grep, Bash",
        "disallowedTools": ["Edit", "Write"],
        "model": "sonnet",
        "models": {"opencode": "gpt-5.4"},
        "color": "blue",
        "effort": "high",
        "skills": "scout, gh",
    })
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    agent = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})["agents"][0]

    assert agent["tools"] == ["Read", "Grep", "Bash"]
    assert agent["disallowedTools"] == ["Edit", "Write"]
    assert agent["skills"] == ["scout", "gh"]
    assert agent["models"] == {"claude": "sonnet", "opencode": "gpt-5.4"}
    assert agent["color"] == "blue"
    assert agent["effort"] == "high"


def test_plugin_agent_name_collision_with_registry_fails_loud(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_agent(payload, "dupe.md", {"name": "dupe"})
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})
    agents_reg = tmp_path / "agents" / "registry.yaml"
    agents_reg.parent.mkdir(parents=True, exist_ok=True)
    agents_reg.write_text("agents:\n  dupe:\n    body_path: agents/dupe.md\n")

    with pytest.raises(ParseError, match="plugin agent name collision: 'dupe'"):
        expand_registries({"agents": "agents/registry.yaml", "plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_claude_native_and_codex_native_agents_are_excluded(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_agent(payload, "worker.md", {"name": "worker"})
    _make_plugins_registry(tmp_path, {"plug": {
        "path": str(tmp_path / "market" / "plug"),
        "harnesses": ["claude", "codex", "opencode"],
        "claude_native": True,
        "codex_native": True,
    }})

    agent = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})["agents"][0]

    assert agent["harnesses"] == ["opencode"]
    assert agent["_from_native_plugin"] is True
    assert agent["_from_codex_native_plugin"] is True


def test_hook_script_decomposed_from_plugin_manifest(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_hook_manifest(payload)
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    hook = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})["hooks"][0]

    assert hook["name"] == "plug-PostToolUse-0-0-foo"
    assert hook["event"] == "PostToolUse"
    assert hook["matcher"] == "Write"
    assert hook["script"] == "hooks/foo.sh"
    assert hook["timeout"] == 7
    assert hook["async"] is True
    assert hook["harnesses"] == ["claude", "codex", "cursor", "copilot"]
    assert hook["_source_dir"] == str(payload)


def test_hook_literal_command_is_claude_only(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_hook_manifest(payload, command="echo literal")
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    hook = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})["hooks"][0]

    assert hook["command"] == "echo literal"
    assert hook["harnesses"] == ["claude"]


def test_hook_literal_command_is_dropped_when_claude_native(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_hook_manifest(payload, command="echo literal")
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug"), "claude_native": True}})

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})

    assert out["hooks"] == []


def test_hook_name_collision_fails_loud(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_hook_manifest(payload)
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})
    hooks_reg = tmp_path / "agents" / "hooks" / "registry.yaml"
    hooks_reg.parent.mkdir(parents=True, exist_ok=True)
    hooks_reg.write_text("hooks:\n  plug-PostToolUse-0-0-foo:\n    event: PostToolUse\n    script: hooks/foo.sh\n")

    with pytest.raises(ParseError, match="plugin hook name collision: 'plug-PostToolUse-0-0-foo'"):
        expand_registries({"hooks": "agents/hooks/registry.yaml", "plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_commands_directory_is_ignored(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    commands = payload / "commands"
    commands.mkdir()
    (commands / "do.md").write_text("command body\n")
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    out = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})

    assert "commands" not in out


# ─── plugin agent / hook fail-loud + boundary hardening ──────────────────────


def test_agent_without_frontmatter_uses_stem_name(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_agent(payload, "plain.md", frontmatter=None)
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    agent = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})["agents"][0]

    assert agent["name"] == "plain"
    assert agent["body_path"] == "agents/plain.md"
    assert agent["harnesses"] == ["claude", "codex", "opencode", "cursor", "copilot"]
    assert "description" not in agent
    assert "models" not in agent
    assert "tools" not in agent


def test_agent_models_frontmatter_must_be_mapping(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_agent(payload, "worker.md", {"name": "worker", "models": "gpt-5"})
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    with pytest.raises(ParseError, match="frontmatter models in .* must be a mapping"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_hook_script_missing_file_fails_loud(tmp_path):
    # A ${CLAUDE_PLUGIN_ROOT} script that resolves but is absent must fail loud,
    # not silently drop the hook (the silent-breakage trap the resolver guards).
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    _write_plugin_hook_manifest(
        payload,
        command="${CLAUDE_PLUGIN_ROOT}/hooks/missing.sh",
        hook_name="present.sh",
    )
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    with pytest.raises(ParseError, match="hook script .* was not found"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_malformed_plugin_json_fails_loud(tmp_path):
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    plugin_dir = payload / ".claude-plugin"
    plugin_dir.mkdir(parents=True, exist_ok=True)
    (plugin_dir / "plugin.json").write_text("{not valid json")
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    with pytest.raises(ParseError, match=r"failed to parse .*plugin\.json"):
        expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})


def test_hook_names_unique_across_outer_entries_same_event(tmp_path):
    # Two PostToolUse hooks running the same script under different matchers must
    # decompose to distinct names. They share plugin+event+stem, so uniqueness has
    # to come from the (outer, inner) coordinate — otherwise both collapse to one
    # name and trip the collision guard on an otherwise-valid manifest.
    _market, payload = _make_plugin_with_marketplace(tmp_path, "plug")
    hooks_dir = payload / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    (hooks_dir / "fmt.sh").write_text("#!/bin/sh\necho fmt\n")
    plugin_dir = payload / ".claude-plugin"
    plugin_dir.mkdir(parents=True, exist_ok=True)
    (plugin_dir / "plugin.json").write_text(json.dumps({
        "name": "plug",
        "hooks": {
            "PostToolUse": [
                {"matcher": "Write", "hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/fmt.sh"}]},
                {"matcher": "Edit", "hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/fmt.sh"}]},
            ]
        },
    }))
    _make_plugins_registry(tmp_path, {"plug": {"path": str(tmp_path / "market" / "plug")}})

    hooks = expand_registries({"plugins": "agents/plugins/registry.yaml"}, tmp_path, {})["hooks"]

    names = [h["name"] for h in hooks]
    assert names == ["plug-PostToolUse-0-0-fmt", "plug-PostToolUse-1-0-fmt"]
    assert len(set(names)) == 2
    assert [h["matcher"] for h in hooks] == ["Write", "Edit"]
