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
