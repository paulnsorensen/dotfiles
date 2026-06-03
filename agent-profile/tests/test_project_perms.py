"""test_project_perms.py — render_project_permissions + ap perms CLI.

Covers the repo-level permission overlay: both renderer methods
(committed and --local), the ap perms CLI subcommand, and the
fall-through-guard (missing fragment → error, floor not rendered).
"""

from __future__ import annotations

import json
import tomllib
from pathlib import Path

import pytest

from agent_profile import cli
from agent_profile.parse import parse_manifest, Manifest
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer

from .conftest import write_profile


# ── helpers ────────────────────────────────────────────────────────────


def _minimal_manifest(allow=None, deny=None) -> Manifest:
    """Build a Manifest with only permissions populated (perms-only fragment)."""
    settings = {}
    if allow:
        settings["permissions_allow"] = allow
    if deny:
        settings["permissions_deny"] = deny
    return Manifest(
        name="_permissions",
        description="project perms fragment",
        mcps=[],
        agents=[],
        skills=[],
        commands=[],
        hooks=[],
        settings=settings,
    )


def _write_perm_fragment(target: Path, allow=None, deny=None) -> Path:
    """Create <target>/.agent-profiles/_permissions/profile.yaml."""
    frag_dir = target / ".agent-profiles" / "_permissions"
    frag_dir.mkdir(parents=True)
    lines = ["name: _permissions"]
    if allow or deny:
        lines.append("settings:")
        if allow:
            lines.append("  permissions_allow:")
            for a in allow:
                lines.append(f"    - '{a}'")
        if deny:
            lines.append("  permissions_deny:")
            for d in deny:
                lines.append(f"    - '{d}'")
    (frag_dir / "profile.yaml").write_text("\n".join(lines) + "\n")
    return frag_dir


def run(argv) -> int:
    return cli.main(argv)


# ── ClaudeRenderer.render_project_permissions ──────────────────────────


def test_claude_project_perms_writes_settings_json(tmp_path):
    """WHY: render_project_permissions must write permissions into
    <target>/.claude/settings.json (the committed project config)."""
    m = _minimal_manifest(allow=["Bash(git:*)", "Edit"], deny=["Grep"])
    ClaudeRenderer().render_project_permissions(m, tmp_path)
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data["permissions"]["allow"] == ["Bash(git:*)", "Edit"]
    assert data["permissions"]["deny"] == ["Grep"]


def test_claude_project_perms_local_writes_settings_local_json(tmp_path):
    """WHY: --local must target settings.local.json (gitignored personal
    layer) instead of settings.json."""
    m = _minimal_manifest(allow=["Bash(git:*)"])
    ClaudeRenderer().render_project_permissions(m, tmp_path, local=True)
    assert not (tmp_path / ".claude" / "settings.json").exists()
    data = json.loads((tmp_path / ".claude" / "settings.local.json").read_text())
    assert data["permissions"]["allow"] == ["Bash(git:*)"]
    assert data["permissions"]["deny"] == []


def test_claude_project_perms_preserves_sibling_keys(tmp_path):
    """WHY: own-our-keys semantics — other settings.json content (defaultMode,
    user MCP command/args, etc.) must survive a perms-only re-render."""
    settings_path = tmp_path / ".claude" / "settings.json"
    settings_path.parent.mkdir(parents=True)
    settings_path.write_text(json.dumps({
        "permissions": {"allow": ["old"], "deny": [], "defaultMode": "allow"},
        "enabledPlugins": {"some-plugin": True},
    }) + "\n")

    m = _minimal_manifest(allow=["Bash(git:*)"], deny=["Grep"])
    ClaudeRenderer().render_project_permissions(m, tmp_path)

    data = json.loads(settings_path.read_text())
    # Permissions overwritten verbatim.
    assert data["permissions"]["allow"] == ["Bash(git:*)"]
    assert data["permissions"]["deny"] == ["Grep"]
    # defaultMode preserved (sibling key inside permissions).
    assert data["permissions"]["defaultMode"] == "allow"
    # enabledPlugins preserved (sibling of permissions).
    assert data["enabledPlugins"] == {"some-plugin": True}


def test_claude_project_perms_idempotent(tmp_path):
    """WHY: re-running must overwrite allow/deny verbatim (not accumulate)."""
    m = _minimal_manifest(allow=["Edit"], deny=["Grep"])
    renderer = ClaudeRenderer()
    renderer.render_project_permissions(m, tmp_path)
    renderer.render_project_permissions(m, tmp_path)
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data["permissions"]["allow"] == ["Edit"]
    assert data["permissions"]["deny"] == ["Grep"]


def test_claude_project_perms_returns_empty_list(tmp_path):
    """WHY: settings.json is a shared/merged file, not manifest-tracked —
    render_project_permissions must return [] like _merge_root_settings."""
    m = _minimal_manifest(allow=["Edit"])
    result = ClaudeRenderer().render_project_permissions(m, tmp_path)
    assert result == []


def test_claude_project_perms_no_plugins_or_mcps_written(tmp_path):
    """WHY: this is a perms-ONLY render — must not touch plugins, skills,
    agents, hooks, or MCP server definitions in the repo."""
    m = _minimal_manifest(allow=["Edit"])
    ClaudeRenderer().render_project_permissions(m, tmp_path)
    # The only file written must be .claude/settings.json.
    claude_dir = tmp_path / ".claude"
    written = [p.relative_to(tmp_path) for p in claude_dir.rglob("*") if p.is_file()]
    assert written == [Path(".claude/settings.json")]


# ── CodexRenderer.render_project_permissions ──────────────────────────


def test_codex_project_perms_writes_rules_file(tmp_path):
    """WHY: a Bash allow rule in the fragment must lower into
    <target>/.codex/rules/ap-canonical.rules."""
    m = _minimal_manifest(allow=["Bash(git:*)"])
    CodexRenderer().render_project_permissions(m, tmp_path)
    rules_path = tmp_path / ".codex" / "rules" / "ap-canonical.rules"
    assert rules_path.is_file()
    text = rules_path.read_text()
    assert "git" in text


def test_codex_project_perms_lever3_writes_enabled_tools(tmp_path):
    """WHY: mcp__<s>__<t> allow rule must yield enabled_tools for <s>
    in <target>/.codex/config.toml. This is the lever-3 assertion."""
    m = _minimal_manifest(allow=["mcp__tilth__tilth_read"])
    CodexRenderer().render_project_permissions(m, tmp_path)
    doc = tomllib.loads((tmp_path / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["enabled_tools"] == ["tilth_read"]


def test_codex_project_perms_lever3_writes_disabled_tools(tmp_path):
    """WHY: mcp__<s>__<t> deny rule must yield disabled_tools for <s>
    in <target>/.codex/config.toml."""
    m = _minimal_manifest(deny=["mcp__tilth__tilth_write"])
    CodexRenderer().render_project_permissions(m, tmp_path)
    doc = tomllib.loads((tmp_path / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["disabled_tools"] == ["tilth_write"]


def test_codex_project_perms_local_is_noop(tmp_path):
    """WHY: Codex has no gitignored personal-settings analog. Under
    local=True render_project_permissions must write nothing."""
    m = _minimal_manifest(allow=["Bash(git:*)"])
    CodexRenderer().render_project_permissions(m, tmp_path, local=True)
    assert not (tmp_path / ".codex").exists()


def test_codex_project_perms_returns_list(tmp_path):
    """WHY: return value mirrors _write_rules' out list (may track the
    rules file path or be empty when no Bash rules)."""
    m = _minimal_manifest(allow=["Bash(git:*)"])
    result = CodexRenderer().render_project_permissions(m, tmp_path)
    assert isinstance(result, list)


def test_codex_project_perms_no_rules_file_when_no_bash_rules(tmp_path):
    """WHY: when the fragment carries only MCP rules (no Bash), no rules
    file is written (matches CodexRenderer._write_rules behavior)."""
    m = _minimal_manifest(allow=["mcp__tilth__tilth_read"])
    CodexRenderer().render_project_permissions(m, tmp_path)
    rules_path = tmp_path / ".codex" / "rules" / "ap-canonical.rules"
    assert not rules_path.exists()


# ── ap perms CLI ───────────────────────────────────────────────────────


def test_cmd_perms_writes_claude_and_codex(tmp_path, env):
    """WHY: ap perms in a repo containing the fragment must write
    .claude/settings.json AND .codex/rules/ap-canonical.rules."""
    _write_perm_fragment(tmp_path, allow=["Bash(git:*)"])
    result = run(["perms", "--target", str(tmp_path)])
    assert result == 0
    assert (tmp_path / ".claude" / "settings.json").is_file()
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert "Bash(git:*)" in data["permissions"]["allow"]
    assert (tmp_path / ".codex" / "rules" / "ap-canonical.rules").is_file()


def test_cmd_perms_missing_fragment_errors_non_zero(tmp_path, env, capsys):
    """WHY: the fall-through-guard test. Without the fragment ap perms must
    exit non-zero with a clear message and write nothing — it must NOT
    render the global floor into the repo."""
    result = run(["perms", "--target", str(tmp_path)])
    assert result != 0
    err = capsys.readouterr().err
    assert "_permissions" in err or "no repo permission overlay" in err
    # Nothing written.
    assert not (tmp_path / ".claude" / "settings.json").exists()
    assert not (tmp_path / ".codex").exists()


def test_cmd_perms_local_writes_settings_local_json(tmp_path, env):
    """WHY: ap perms --local must write settings.local.json (not
    settings.json) and skip Codex."""
    _write_perm_fragment(tmp_path, allow=["Bash(git:*)"])
    result = run(["perms", "--local", "--target", str(tmp_path)])
    assert result == 0
    assert not (tmp_path / ".claude" / "settings.json").exists()
    assert (tmp_path / ".claude" / "settings.local.json").is_file()
    # Codex skipped under --local.
    assert not (tmp_path / ".codex").exists()


def test_cmd_perms_local_emits_codex_skip_note(tmp_path, env, capsys):
    """WHY: --local skips Codex with a one-line note (not silently)."""
    _write_perm_fragment(tmp_path, allow=["Bash(git:*)"])
    run(["perms", "--local", "--target", str(tmp_path)])
    captured = capsys.readouterr()
    combined = captured.out + captured.err
    assert "codex" in combined.lower()


def test_cmd_perms_missing_fragment_writes_nothing(tmp_path, env):
    """WHY: companion to the non-zero exit test — verifies the filesystem
    invariant that render_project_permissions is never called when the
    fragment is absent."""
    run(["perms", "--target", str(tmp_path)])
    assert not (tmp_path / ".claude").exists()
    assert not (tmp_path / ".codex").exists()


def test_claude_project_perms_no_regression_render_unchanged(tmp_path):
    """WHY: adding render_project_permissions must not alter ClaudeRenderer.render()
    — the user-level floor render path is additive-only; this verifies the
    existing _merge_root_settings path still writes permissions.allow."""
    m = _minimal_manifest(allow=["Edit"])
    # render() calls _merge_root_settings which writes settings.json at target.
    ClaudeRenderer().render(m, tmp_path)
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data["permissions"]["allow"] == ["Edit"]


def test_cmd_perms_codex_lever3_via_cli(tmp_path, env):
    """WHY: lever-3 round-trip via the CLI — mcp__<s>__<t> in the fragment
    flows to enabled_tools/<s> in .codex/config.toml."""
    _write_perm_fragment(tmp_path, allow=["mcp__tilth__tilth_read"])
    result = run(["perms", "--target", str(tmp_path)])
    assert result == 0
    doc = tomllib.loads((tmp_path / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["enabled_tools"] == ["tilth_read"]
