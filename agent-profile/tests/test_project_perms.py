"""test_project_perms.py — render_project_permissions + ap perms CLI.

Covers the repo-level permission overlay: both renderer methods
(committed and --local), the ap perms CLI subcommand, and the
fall-through-guard (missing fragment → error, floor not rendered).
"""

from __future__ import annotations

import json
import tomllib
from pathlib import Path

from agent_profile import cli
from agent_profile.parse import parse_manifest, Manifest
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer


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


# ── Hardening: assertion strength ─────────────────────────────────────


def test_codex_project_perms_rules_file_exact_prefix_rule_format(tmp_path):
    """WHY: the rules file must contain a valid prefix_rule() starlark call
    with the correct pattern and decision — not just any line containing 'git'.
    This locks the _render_rules_file format against regressions."""
    m = _minimal_manifest(allow=["Bash(git:*)"], deny=["Bash(sudo:*)"])
    CodexRenderer().render_project_permissions(m, tmp_path)
    text = (tmp_path / ".codex" / "rules" / "ap-canonical.rules").read_text()
    assert 'prefix_rule(\n    pattern = ["git"],\n    decision = "allow",\n)' in text
    assert 'prefix_rule(\n    pattern = ["sudo"],\n    decision = "forbidden",\n)' in text


# ── Hardening: idempotency with siblings through second run ────────────


def test_claude_project_perms_idempotent_siblings_survive_re_run(tmp_path):
    """WHY: sibling keys (defaultMode, user mcpServers) must survive a second
    re-render, not just the first. Idempotency and own-our-keys must hold
    together: allow/deny overwritten verbatim, nothing else disturbed."""
    settings_path = tmp_path / ".claude" / "settings.json"
    settings_path.parent.mkdir(parents=True)
    settings_path.write_text(json.dumps({
        "permissions": {"allow": ["old"], "deny": [], "defaultMode": "allow"},
        "mcpServers": {"user-mcp": {"command": "npx", "args": ["my-mcp"]}},
    }) + "\n")

    m = _minimal_manifest(allow=["Bash(git:*)"], deny=["Grep"])
    renderer = ClaudeRenderer()
    renderer.render_project_permissions(m, tmp_path)
    renderer.render_project_permissions(m, tmp_path)  # second run

    data = json.loads(settings_path.read_text())
    # allow/deny overwritten verbatim — not accumulated from "old"
    assert data["permissions"]["allow"] == ["Bash(git:*)"]
    assert data["permissions"]["deny"] == ["Grep"]
    # sibling inside permissions untouched
    assert data["permissions"]["defaultMode"] == "allow"
    # sibling of permissions untouched
    assert data["mcpServers"] == {"user-mcp": {"command": "npx", "args": ["my-mcp"]}}


# ── Hardening: standalone-fragment guarantee ───────────────────────────


def test_standalone_fragment_does_not_include_global_floor(tmp_path, env):
    """WHY: the fragment must be parsed standalone so the global floor's allow
    list does NOT leak into the project overlay. Name-based discovery would
    fall through to the floor and union its ~62 entries into the project file,
    making it a replacement instead of a pure delta."""
    frag_dir = _write_perm_fragment(
        tmp_path, allow=["Bash(my-project-tool:*)"], deny=["Bash(badcmd:*)"]
    )
    # Parse standalone (exactly what cmd_perms does internally)
    manifest = parse_manifest(frag_dir)
    allow = manifest.settings.get("permissions_allow", [])
    deny = manifest.settings.get("permissions_deny", [])

    # Only the fragment's own entries — NOT any floor entry
    assert allow == ["Bash(my-project-tool:*)"]
    assert deny == ["Bash(badcmd:*)"]
    # Spot-check: a known floor entry must not be present
    assert "Bash(git:*)" not in allow, (
        "global floor allow list leaked into the project fragment; "
        "parse_manifest must be called on the fragment directory directly"
    )


def test_cmd_perms_fragment_allow_does_not_include_floor_in_written_file(tmp_path, env):
    """WHY: end-to-end companion to the standalone-parse unit test. The written
    settings.json must contain ONLY the fragment's allow list — floor entries
    must not appear even after the full cmd_perms → ClaudeRenderer path."""
    # Fragment has exactly one rule that is NOT in the global floor
    _write_perm_fragment(tmp_path, allow=["Bash(my-project-tool:*)"])
    run(["perms", "--target", str(tmp_path)])
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    allow = data["permissions"]["allow"]
    assert allow == ["Bash(my-project-tool:*)"]
    # A rule known to be in the global floor must NOT appear
    assert "Bash(git:*)" not in allow, (
        "global floor allow list leaked into the project settings.json"
    )


# ── Hardening: boundary behaviour ─────────────────────────────────────


def test_claude_project_perms_deny_only_fragment(tmp_path):
    """WHY: a fragment with no allow key (only deny) is a valid boundary case.
    The renderer must write an empty allow list, not error or leave the key absent."""
    m = _minimal_manifest(deny=["Grep", "Glob"])
    ClaudeRenderer().render_project_permissions(m, tmp_path)
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data["permissions"]["allow"] == []
    assert data["permissions"]["deny"] == ["Grep", "Glob"]


def test_codex_project_perms_no_extra_files_written(tmp_path):
    """WHY: the Codex render is also perms-ONLY. render_project_permissions
    must not write skills, agents, hooks, or MCP server connection definitions
    into the repo's .codex directory — only rules and/or config.toml."""
    m = _minimal_manifest(allow=["Bash(git:*)", "mcp__tilth__tilth_read"])
    CodexRenderer().render_project_permissions(m, tmp_path)
    codex_dir = tmp_path / ".codex"
    written = sorted(p.relative_to(tmp_path) for p in codex_dir.rglob("*") if p.is_file())
    allowed = {
        Path(".codex/rules/ap-canonical.rules"),
        Path(".codex/config.toml"),
    }
    unexpected = set(written) - allowed
    assert not unexpected, f"unexpected files written into repo .codex/: {unexpected}"


def test_claude_project_perms_creates_parent_dirs(tmp_path):
    """WHY: the target may be a repo root that has no .claude/ directory yet.
    render_project_permissions must create parent directories as needed."""
    target = tmp_path / "new-repo"  # doesn't exist yet
    m = _minimal_manifest(allow=["Edit"])
    ClaudeRenderer().render_project_permissions(m, target)
    assert (target / ".claude" / "settings.json").is_file()


def test_codex_project_perms_creates_parent_dirs(tmp_path):
    """WHY: same parent-creation guarantee for the Codex renderer."""
    target = tmp_path / "new-repo"  # doesn't exist yet
    m = _minimal_manifest(allow=["Bash(git:*)"])
    CodexRenderer().render_project_permissions(m, target)
    assert (target / ".codex" / "rules" / "ap-canonical.rules").is_file()


# ── Hardening: CLI harness filtering ──────────────────────────────────


def test_cmd_perms_harness_claude_only_skips_codex(tmp_path, env):
    """WHY: --harness claude must restrict the render to Claude only.
    Codex files must not be written, and the command must succeed."""
    _write_perm_fragment(tmp_path, allow=["Bash(git:*)"])
    result = run(["perms", "--harness", "claude", "--target", str(tmp_path)])
    assert result == 0
    assert (tmp_path / ".claude" / "settings.json").is_file()
    assert not (tmp_path / ".codex").exists()


def test_cmd_perms_harness_codex_only_skips_claude(tmp_path, env):
    """WHY: --harness codex must restrict the render to Codex only.
    Claude settings.json must not be written."""
    _write_perm_fragment(tmp_path, allow=["Bash(git:*)"])
    result = run(["perms", "--harness", "codex", "--target", str(tmp_path)])
    assert result == 0
    assert (tmp_path / ".codex" / "rules" / "ap-canonical.rules").is_file()
    assert not (tmp_path / ".claude" / "settings.json").exists()


# ── Hardening: mcp__* only (no Bash) via CLI ──────────────────────────


def test_cmd_perms_mcp_only_fragment_no_rules_file(tmp_path, env):
    """WHY: a fragment with only mcp__* rules (no Bash) must not produce
    a Codex rules file — only config.toml tool scopes. Exercised via the
    CLI so the full cmd_perms → CodexRenderer path is covered."""
    _write_perm_fragment(tmp_path, allow=["mcp__tilth__tilth_read"])
    result = run(["perms", "--target", str(tmp_path)])
    assert result == 0
    assert not (tmp_path / ".codex" / "rules" / "ap-canonical.rules").exists()
    doc = tomllib.loads((tmp_path / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["enabled_tools"] == ["tilth_read"]


def test_cmd_perms_unsupported_harness_errors(tmp_path, env, capsys):
    """WHY: --harness carrying only out-of-scope/typo'd values (no claude or
    codex) must error loudly with a non-zero exit and write nothing — not
    silently no-op with exit 0. Mirrors the loud failure every other
    subcommand gives on an unknown harness."""
    _write_perm_fragment(tmp_path, allow=["Bash(git:*)"])
    result = run(["perms", "--harness", "opencode", "--target", str(tmp_path)])
    assert result != 0
    err = capsys.readouterr().err
    assert "claude, codex" in err
    assert not (tmp_path / ".claude").exists()
    assert not (tmp_path / ".codex").exists()


def test_cmd_perms_mixed_supported_and_unsupported_harness_errors(
    tmp_path, env, capsys
):
    """WHY: an explicit --harness mixing a supported and an unsupported value
    (claude,opencode) must fail loud naming the bad value — NOT silently drop
    opencode and render Claude only. The all-harness default still filters
    quietly down to claude/codex; an explicit typo must not slip through."""
    _write_perm_fragment(tmp_path, allow=["Bash(git:*)"])
    result = run(
        ["perms", "--harness", "claude,opencode", "--target", str(tmp_path)]
    )
    assert result != 0
    err = capsys.readouterr().err
    assert "opencode" in err
    assert "claude, codex" in err
    # The loud error must abort before any render.
    assert not (tmp_path / ".claude").exists()
    assert not (tmp_path / ".codex").exists()


def test_cmd_perms_top_level_perms_key_errors_not_empty_overlay(
    tmp_path, env, capsys
):
    """WHY: a fragment that declares permissions_allow at the TOP level (instead
    of nested under settings:) hits a different launch-overlay field the
    renderers never read — it would silently write an EMPTY overlay. cmd_perms
    must fail loud, point at the settings: requirement, and write nothing."""
    frag_dir = tmp_path / ".agent-profiles" / "_permissions"
    frag_dir.mkdir(parents=True)
    (frag_dir / "profile.yaml").write_text(
        "name: _permissions\npermissions_allow:\n  - 'Bash(git:*)'\n"
    )
    result = run(["perms", "--target", str(tmp_path)])
    assert result != 0
    err = capsys.readouterr().err
    assert "settings" in err
    assert not (tmp_path / ".claude").exists()
    assert not (tmp_path / ".codex").exists()


def test_claude_project_perms_empty_lists_clear_stale_committed_perms(tmp_path):
    """WHY: emptying a previously-written overlay (keys present but empty lists)
    must rewrite settings.json to DROP the stale allow/deny — not early-return
    and leave the old entries in place. Idempotent overwrite must hold at the
    empty boundary, else a cleared overlay silently keeps old grants."""
    settings_path = tmp_path / ".claude" / "settings.json"
    settings_path.parent.mkdir(parents=True)
    settings_path.write_text(
        json.dumps({"permissions": {"allow": ["Bash(stale:*)"], "deny": ["Grep"]}})
        + "\n"
    )
    # Keys present but empty — an explicit clear, distinct from "keys absent".
    m = Manifest(
        name="_permissions",
        description="",
        mcps=[],
        agents=[],
        skills=[],
        commands=[],
        hooks=[],
        settings={"permissions_allow": [], "permissions_deny": []},
    )
    ClaudeRenderer().render_project_permissions(m, tmp_path)
    data = json.loads(settings_path.read_text())
    assert data["permissions"]["allow"] == []
    assert data["permissions"]["deny"] == []
