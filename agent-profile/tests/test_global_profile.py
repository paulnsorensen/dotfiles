"""test_global_profile.py — coverage for the `global` profile shape and
the surfaces it added (target_default, marketplaces, claude renderer's
live-settings.json merge + un-merge).

These tests use the production claude renderer directly; the StubRenderer
in conftest is for steel-thread CLI orchestration tests, not for live
behavior of a real harness renderer.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile.parse import Manifest, parse_manifest
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.cli import _resolve_target

from tests.conftest import write_profile


# ── target_default + _resolve_target ─────────────────────────────────


def test_resolve_target_explicit_flag_wins(tmp_path):
    """``--target`` always wins over the profile default."""
    explicit = tmp_path / "explicit"
    explicit.mkdir()
    resolved = _resolve_target(explicit, "$HOME/nope")
    assert resolved == explicit


def test_resolve_target_profile_default_when_flag_missing(tmp_path, monkeypatch):
    """Without ``--target``, the profile's ``target_default`` is honored
    (with env + ~ expansion)."""
    monkeypatch.setenv("HOME", str(tmp_path / "fakehome"))
    (tmp_path / "fakehome").mkdir()
    resolved = _resolve_target(None, "$HOME")
    assert resolved == Path(str(tmp_path / "fakehome")).resolve()


def test_resolve_target_falls_through_to_cwd(tmp_path, monkeypatch):
    """Neither flag nor profile default → ``Path.cwd()``."""
    monkeypatch.chdir(tmp_path)
    resolved = _resolve_target(None, None)
    assert resolved == Path.cwd()


def test_resolve_target_unset_var_left_literal(tmp_path, monkeypatch):
    """An unset ``${VAR}`` ref is left as a literal (path won't resolve to a
    real location, but no KeyError) — easier-to-debug surface failure."""
    monkeypatch.delenv("DOTFILES_NOT_SET", raising=False)
    resolved = _resolve_target(None, "${DOTFILES_NOT_SET}/x")
    # Path.resolve() will normalize but won't fail on the literal.
    assert "${DOTFILES_NOT_SET}" in str(resolved)


# ── parse: target_default + marketplaces carry through includes ──────


def test_parse_target_default_outermost_wins(env):
    """``target_default`` is outer-profile-only — like name/description, it
    does NOT merge from includes. An include declaring a different default
    must not leak into the outer manifest."""
    write_profile(
        env.profiles,
        "inner",
        "name: inner\ntarget_default: /tmp/inner-default\n",
    )
    write_profile(
        env.profiles,
        "outer",
        "name: outer\ninclude: [inner]\ntarget_default: /tmp/outer-default\n",
    )
    m = parse_manifest(env.profiles / "outer")
    assert m.target_default == "/tmp/outer-default"


def test_parse_marketplaces_outermost_wins(env):
    """``marketplaces`` is outer-profile-only (mirrors ``enabled_plugins``).
    The include's entry is dropped in favor of the outer profile's."""
    write_profile(
        env.profiles,
        "inner",
        "name: inner\nmarketplaces:\n  inner-mkt: /a\n",
    )
    write_profile(
        env.profiles,
        "outer",
        "name: outer\ninclude: [inner]\nmarketplaces:\n  outer-mkt: /b\n",
    )
    m = parse_manifest(env.profiles / "outer")
    assert m.marketplaces == {"outer-mkt": "/b"}


# ── claude renderer: live settings.json merge ────────────────────────


def _seed_settings(target: Path, content: dict) -> Path:
    """Write a chezmoi-equivalent seed at ``<target>/.claude/settings.json``."""
    path = target / ".claude" / "settings.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(content, indent=2) + "\n")
    return path


def _bare_manifest(**kwargs) -> Manifest:
    """Build a Manifest with just enough fields to drive the renderer."""
    return Manifest(name=kwargs.pop("name", "global"), **kwargs)


def test_claude_renderer_adds_enabledplugins(tmp_path):
    """``enabled_plugins`` lands in ``settings.json``'s ``enabledPlugins``."""
    settings = _seed_settings(tmp_path, {"theme": "dark"})
    manifest = _bare_manifest(enabled_plugins={"global@local": True})

    ClaudeRenderer().render(manifest, tmp_path)

    data = json.loads(settings.read_text())
    assert data["enabledPlugins"] == {"global@local": True}
    assert data["theme"] == "dark"  # sibling preserved


def test_claude_renderer_adds_marketplaces_with_directory_wrap(tmp_path, monkeypatch):
    """``marketplaces`` lands wrapped as a directory source. ``${VAR}``
    refs expand from the process env."""
    monkeypatch.setenv("DOTFILES_DIR", "/opt/dots")
    settings = _seed_settings(tmp_path, {})
    manifest = _bare_manifest(
        marketplaces={"local": "${DOTFILES_DIR}/.claude/plugins/local"}
    )

    ClaudeRenderer().render(manifest, tmp_path)

    data = json.loads(settings.read_text())
    assert data["extraKnownMarketplaces"] == {
        "local": {
            "source": {"source": "directory", "path": "/opt/dots/.claude/plugins/local"}
        }
    }


# ── local directory-marketplace manifest (plugin resolution) ─────────


def test_local_marketplace_manifest_is_written(tmp_path):
    """render emits a directory ``marketplace.json`` listing the profile as
    a plugin, so ``enabledPlugins: <profile>@local`` can resolve."""
    _seed_settings(tmp_path, {})
    ClaudeRenderer().render(
        _bare_manifest(
            name="global",
            description="Live install",
            enabled_plugins={"global@local": True},
        ),
        tmp_path,
    )

    mpath = tmp_path / ".claude/plugins/local/.claude-plugin/marketplace.json"
    assert mpath.is_file()
    data = json.loads(mpath.read_text())
    assert data["name"] == "local"
    assert data["plugins"] == [
        {"name": "global", "source": "./global", "description": "Live install"}
    ]


def test_local_marketplace_resolves_enabled_plugin_end_to_end(tmp_path, monkeypatch):
    """The registered marketplace path, the ``marketplace.json``, and the
    rendered plugin dir all agree. This is the wiring that was broken when
    the path pointed at a nonexistent repo dir — the MCPs never loaded."""
    monkeypatch.setenv("HOME", str(tmp_path))
    _seed_settings(tmp_path, {})
    ClaudeRenderer().render(
        _bare_manifest(
            name="global",
            marketplaces={"local": "~/.claude/plugins/local"},
            enabled_plugins={"global@local": True},
        ),
        tmp_path,
    )

    settings = json.loads((tmp_path / ".claude/settings.json").read_text())
    market_path = Path(
        settings["extraKnownMarketplaces"]["local"]["source"]["path"]
    )
    # The registered marketplace path holds the manifest.
    assert (market_path / ".claude-plugin" / "marketplace.json").is_file()
    mdata = json.loads(
        (market_path / ".claude-plugin/marketplace.json").read_text()
    )
    assert mdata["name"] == "local"
    # The manifest advertises a plugin matching the enabled id global@local.
    plugin = next(p for p in mdata["plugins"] if p["name"] == "global")
    # Its source resolves to a real rendered plugin dir.
    assert (market_path / plugin["source"] / ".claude-plugin/plugin.json").is_file()


def test_local_marketplace_upserts_and_preserves_siblings(tmp_path):
    """A second profile installed into the same local marketplace keeps the
    first's entry; re-rendering the same profile does not duplicate it."""
    _seed_settings(tmp_path, {})
    g = _bare_manifest(name="global", enabled_plugins={"global@local": True})
    r = _bare_manifest(name="review", enabled_plugins={"review@local": True})
    ClaudeRenderer().render(g, tmp_path)
    ClaudeRenderer().render(r, tmp_path)
    ClaudeRenderer().render(g, tmp_path)  # rerun

    data = json.loads(
        (tmp_path / ".claude/plugins/local/.claude-plugin/marketplace.json").read_text()
    )
    assert sorted(p["name"] for p in data["plugins"]) == ["global", "review"]


def test_clean_removes_profile_from_local_marketplace(tmp_path):
    """clean() un-merges the profile's entry; the manifest is deleted only
    once no plugins remain."""
    _seed_settings(tmp_path, {})
    g = _bare_manifest(name="global", enabled_plugins={"global@local": True})
    r = _bare_manifest(name="review", enabled_plugins={"review@local": True})
    ClaudeRenderer().render(g, tmp_path)
    ClaudeRenderer().render(r, tmp_path)
    mpath = tmp_path / ".claude/plugins/local/.claude-plugin/marketplace.json"

    ClaudeRenderer().clean(g, tmp_path)
    data = json.loads(mpath.read_text())
    assert [p["name"] for p in data["plugins"]] == ["review"]

    ClaudeRenderer().clean(r, tmp_path)
    assert not mpath.exists()


def test_claude_renderer_preserves_user_siblings(tmp_path):
    """Pre-existing keys (sandbox, hooks, etc.) survive the merge."""
    settings = _seed_settings(
        tmp_path,
        {
            "sandbox": {"enabled": False},
            "theme": "dark",
            "enabledPlugins": {"user-plugin@user-mkt": True},
            "extraKnownMarketplaces": {
                "user-mkt": {"source": {"source": "github", "repo": "u/u"}}
            },
        },
    )
    manifest = _bare_manifest(
        enabled_plugins={"global@local": True},
        marketplaces={"local": "/opt/local"},
    )

    ClaudeRenderer().render(manifest, tmp_path)

    data = json.loads(settings.read_text())
    assert data["sandbox"] == {"enabled": False}
    assert data["theme"] == "dark"
    # Both old + new entries present.
    assert data["enabledPlugins"] == {
        "user-plugin@user-mkt": True,
        "global@local": True,
    }
    assert set(data["extraKnownMarketplaces"]) == {"user-mkt", "local"}


def test_claude_renderer_merge_is_idempotent(tmp_path):
    """Running ``render`` twice yields the same file content."""
    _seed_settings(tmp_path, {})
    manifest = _bare_manifest(
        enabled_plugins={"global@local": True},
        marketplaces={"local": "/opt/local"},
    )
    ClaudeRenderer().render(manifest, tmp_path)
    first = (tmp_path / ".claude" / "settings.json").read_text()
    ClaudeRenderer().render(manifest, tmp_path)
    second = (tmp_path / ".claude" / "settings.json").read_text()
    assert first == second


def test_claude_renderer_creates_settings_when_absent(tmp_path):
    """When ``settings.json`` doesn't exist yet, the renderer seeds a
    minimal one rather than failing. Operator-direct ``ap install global``
    standalone path."""
    # No seed call — file absent
    assert not (tmp_path / ".claude" / "settings.json").exists()
    manifest = _bare_manifest(
        enabled_plugins={"global@local": True},
        marketplaces={"local": "/opt/local"},
    )
    ClaudeRenderer().render(manifest, tmp_path)
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data == {
        "enabledPlugins": {"global@local": True},
        "extraKnownMarketplaces": {
            "local": {"source": {"source": "directory", "path": "/opt/local"}}
        },
    }


def test_claude_renderer_no_op_when_profile_declares_neither(tmp_path):
    """A profile without ``enabled_plugins`` or ``marketplaces`` doesn't
    touch ``settings.json`` (no file created, no existing file modified)."""
    manifest = _bare_manifest()  # both empty by default
    ClaudeRenderer().render(manifest, tmp_path)
    assert not (tmp_path / ".claude" / "settings.json").exists()


# ── claude renderer: clean() un-merges its keys ──────────────────────


def test_claude_renderer_clean_removes_only_profile_keys(tmp_path):
    """``clean()`` removes the profile's enabledPlugins + marketplaces
    entries while leaving siblings intact (mirrors opencode's surgical
    un-merge)."""
    _seed_settings(
        tmp_path,
        {
            "theme": "dark",
            "enabledPlugins": {
                "user-plugin@user-mkt": True,
                "global@local": True,
            },
            "extraKnownMarketplaces": {
                "user-mkt": {"source": {"source": "github", "repo": "u/u"}},
                "local": {
                    "source": {"source": "directory", "path": "/opt/local"}
                },
            },
        },
    )
    manifest = _bare_manifest(
        enabled_plugins={"global@local": True},
        marketplaces={"local": "/opt/local"},
    )

    ClaudeRenderer().clean(manifest, tmp_path)

    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data["theme"] == "dark"
    assert data["enabledPlugins"] == {"user-plugin@user-mkt": True}
    assert list(data["extraKnownMarketplaces"]) == ["user-mkt"]


def test_claude_renderer_clean_unlinks_when_only_owned_keys(tmp_path):
    """When ``clean()`` reduces the file to ``{}`` (profile owned all
    keys), the file is removed — matches opencode's "the profile owned
    it" rule."""
    _seed_settings(
        tmp_path,
        {
            "enabledPlugins": {"global@local": True},
            "extraKnownMarketplaces": {
                "local": {"source": {"source": "directory", "path": "/opt/local"}}
            },
        },
    )
    manifest = _bare_manifest(
        enabled_plugins={"global@local": True},
        marketplaces={"local": "/opt/local"},
    )

    ClaudeRenderer().clean(manifest, tmp_path)

    assert not (tmp_path / ".claude" / "settings.json").exists()


def test_claude_renderer_clean_no_op_when_settings_absent(tmp_path):
    """``clean()`` against a missing settings.json is a no-op (and does
    not create the file)."""
    manifest = _bare_manifest(
        enabled_plugins={"global@local": True},
        marketplaces={"local": "/opt/local"},
    )

    # Should not raise.
    ClaudeRenderer().clean(manifest, tmp_path)

    assert not (tmp_path / ".claude" / "settings.json").exists()


# ── claude renderer: canonical permission root-render (SSOT) ─────────


def test_root_render_writes_canonical_allow_and_deny(tmp_path):
    """The canonical allow/deny lists (carried in ``settings``) land in root
    ``settings.json``'s ``permissions.{allow,deny}``."""
    settings = _seed_settings(tmp_path, {"permissions": {"defaultMode": "auto"}})
    manifest = _bare_manifest(
        settings={
            "permissions_allow": ["Bash(git:*)", "Edit"],
            "permissions_deny": ["Grep", "Bash(sudo:*)"],
        }
    )

    ClaudeRenderer().render(manifest, tmp_path)

    data = json.loads(settings.read_text())
    assert data["permissions"]["allow"] == ["Bash(git:*)", "Edit"]
    assert data["permissions"]["deny"] == ["Grep", "Bash(sudo:*)"]
    # defaultMode (lever-2 posture, user-owned) survives the render.
    assert data["permissions"]["defaultMode"] == "auto"


def test_root_render_preserves_unrelated_keys(tmp_path):
    """The SSOT render disturbs neither ``hooks``/``sandbox``/``env`` nor the
    user's ``enabledPlugins`` already present in root settings.json."""
    settings = _seed_settings(
        tmp_path,
        {
            "hooks": {"PreToolUse": [{"matcher": "Bash"}]},
            "sandbox": {"enabled": False},
            "env": {"X": "1"},
            "permissions": {"defaultMode": "auto"},
        },
    )
    manifest = _bare_manifest(
        settings={"permissions_allow": ["Edit"], "permissions_deny": ["Grep"]}
    )

    ClaudeRenderer().render(manifest, tmp_path)

    data = json.loads(settings.read_text())
    assert data["hooks"] == {"PreToolUse": [{"matcher": "Bash"}]}
    assert data["sandbox"] == {"enabled": False}
    assert data["env"] == {"X": "1"}


def test_root_render_replaces_stale_lists(tmp_path):
    """Re-rendering re-asserts the canonical lists wholesale (SSOT) — a stale
    entry from a prior render is gone, not unioned."""
    settings = _seed_settings(
        tmp_path,
        {"permissions": {"allow": ["Bash(stale:*)"], "defaultMode": "auto"}},
    )
    manifest = _bare_manifest(
        settings={"permissions_allow": ["Edit"], "permissions_deny": ["Grep"]}
    )

    ClaudeRenderer().render(manifest, tmp_path)

    data = json.loads(settings.read_text())
    assert data["permissions"]["allow"] == ["Edit"]
    assert "Bash(stale:*)" not in data["permissions"]["allow"]


def test_root_render_is_idempotent(tmp_path):
    """Two renders yield byte-identical root settings.json."""
    _seed_settings(tmp_path, {"permissions": {"defaultMode": "auto"}})
    manifest = _bare_manifest(
        settings={"permissions_allow": ["Edit"], "permissions_deny": ["Grep"]}
    )
    ClaudeRenderer().render(manifest, tmp_path)
    first = (tmp_path / ".claude" / "settings.json").read_text()
    ClaudeRenderer().render(manifest, tmp_path)
    second = (tmp_path / ".claude" / "settings.json").read_text()
    assert first == second


def test_root_render_clean_removes_only_allow_deny(tmp_path):
    """``clean`` un-merges the ap-managed allow/deny but preserves
    ``defaultMode`` and other user keys."""
    _seed_settings(
        tmp_path,
        {
            "theme": "dark",
            "permissions": {
                "allow": ["Edit"],
                "deny": ["Grep"],
                "defaultMode": "auto",
            },
        },
    )
    manifest = _bare_manifest(
        settings={"permissions_allow": ["Edit"], "permissions_deny": ["Grep"]}
    )

    ClaudeRenderer().clean(manifest, tmp_path)

    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data["theme"] == "dark"
    assert data["permissions"] == {"defaultMode": "auto"}


def test_root_render_clean_drops_empty_permissions(tmp_path):
    """When the profile owned every ``permissions`` subkey, ``clean`` drops
    the now-empty ``permissions`` container."""
    _seed_settings(
        tmp_path,
        {"theme": "dark", "permissions": {"allow": ["Edit"], "deny": ["Grep"]}},
    )
    manifest = _bare_manifest(
        settings={"permissions_allow": ["Edit"], "permissions_deny": ["Grep"]}
    )

    ClaudeRenderer().clean(manifest, tmp_path)

    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert "permissions" not in data
    assert data["theme"] == "dark"


def test_ssot_create_settings_has_no_permission_lists(tmp_path):
    """SSOT: the chezmoi ``create_settings.json`` seed no longer carries an
    ``allow``/``deny`` block — the canonical fragment owns it, re-asserted on
    sync. Guards against the lists creeping back into two sources."""
    import os

    repo = Path(os.environ.get("DOTFILES_DIR") or Path.home() / "Dev/dotfiles")
    seed = repo / "chezmoi" / "dot_claude" / "create_settings.json"
    if not seed.is_file():
        pytest.skip(f"seed not found at {seed}")
    data = json.loads(seed.read_text())
    perms = data.get("permissions", {})
    assert "allow" not in perms
    assert "deny" not in perms


def test_ssot_round_trip_reasserts_into_real_seed_preserving_keys(tmp_path):
    """SSOT round-trip (spec test plan): the chezmoi ``create_settings.json``
    seed (permission block already stripped) is the live root file; a
    canonical render re-asserts ``permissions.{allow,deny}`` into it while
    every non-permission key the seed owns (``env``/``hooks``/``sandbox``/
    ``enabledPlugins``/``theme``/``editorMode``) — and the lever-2
    ``defaultMode`` — survives untouched. Seeds root from the REAL shipped
    seed so the test fails if a future edit reintroduces an allow/deny block
    there or the renderer starts clobbering a sibling key."""
    import os

    repo = Path(os.environ.get("DOTFILES_DIR") or Path.home() / "Dev/dotfiles")
    seed_path = repo / "chezmoi" / "dot_claude" / "create_settings.json"
    if not seed_path.is_file():
        pytest.skip(f"seed not found at {seed_path}")
    seed = json.loads(seed_path.read_text())

    settings = _seed_settings(tmp_path, seed)
    manifest = _bare_manifest(
        settings={
            "permissions_allow": ["Bash(git:*)", "Edit"],
            "permissions_deny": ["Grep", "Bash(sudo:*)"],
        }
    )

    ClaudeRenderer().render(manifest, tmp_path)
    data = json.loads(settings.read_text())

    # Re-asserted canonical block.
    assert data["permissions"]["allow"] == ["Bash(git:*)", "Edit"]
    assert data["permissions"]["deny"] == ["Grep", "Bash(sudo:*)"]
    # The seed owned defaultMode (lever-2 posture) — it survives the merge.
    assert data["permissions"]["defaultMode"] == seed["permissions"]["defaultMode"]
    # Every non-permission key the seed carried survives byte-for-byte.
    for key in ("env", "hooks", "sandbox", "enabledPlugins", "theme", "editorMode"):
        if key in seed:
            assert data[key] == seed[key], f"seed key {key!r} disturbed by render"


# ── parse: the actual global profile YAML round-trips ────────────────


@pytest.mark.parametrize(
    "field,expected_contains",
    [
        ("name", "global"),
        ("target_default", "$HOME"),
    ],
)
def test_real_global_profile_yaml_parses(field, expected_contains):
    """The shipped ``profiles/global/profile.yaml`` parses with the
    expected operator-overlay fields. Guards against YAML drift."""
    import os

    repo = Path(os.environ.get("DOTFILES_DIR") or Path.home() / "Dev/dotfiles")
    profile_yaml = repo / "profiles" / "global" / "profile.yaml"
    if not profile_yaml.is_file():
        pytest.skip(f"global profile not found at {profile_yaml}")

    # Direct parse_one (no include resolution; we don't need base here).
    from agent_profile.parse import parse_one

    one = parse_one(profile_yaml.parent)
    assert expected_contains in str(one[field])
