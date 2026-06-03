"""Parity tests for agent_profile.renderers.copilot.CopilotRenderer.

Each test drives ``CopilotRenderer.render`` / ``.clean`` against a
hand-built :class:`Manifest` (mirroring the bash bats ``merged()`` helper)
and asserts byte/string parity against golden captured from the bash
renderer (``tests/fixtures/golden/copilot/<case>/target/...``).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile.parse import Manifest
from agent_profile.renderers.copilot import CopilotRenderer

GOLDEN = Path(__file__).parent / "fixtures" / "golden" / "copilot"


def golden(rel: str) -> str:
    return (GOLDEN / rel).read_text()


def manifest(source_dir: Path, **sections) -> Manifest:
    """Build a resolved Manifest, decorating each item with _source_dir
    (the bash bats ``merged()`` helper does the same)."""
    sd = str(source_dir)

    def decorate(items):
        return [{**item, "_source_dir": sd} for item in items]

    return Manifest(
        name="p1",
        description="test",
        mcps=decorate(sections.get("mcps", [])),
        agents=decorate(sections.get("agents", [])),
        skills=decorate(sections.get("skills", [])),
        commands=decorate(sections.get("commands", [])),
        hooks=decorate(sections.get("hooks", [])),
        settings={},
    )


@pytest.fixture
def target(tmp_path):
    t = tmp_path / "target"
    t.mkdir()
    return t


@pytest.fixture
def src(tmp_path):
    s = tmp_path / "src"
    s.mkdir()
    return s


def renderer() -> CopilotRenderer:
    return CopilotRenderer()


def test_implements_renderer_protocol():
    from agent_profile.renderers.base import Renderer

    assert isinstance(renderer(), Renderer)
    assert renderer().name == "copilot"


# ─── rust profile (acceptance criterion) ───────────────────────────────


def _rust_manifest(src: Path) -> Manifest:
    """Reconstruct the rust profile's resolved item lists (matching the
    real profile.yaml the bash golden was captured from)."""
    (src / "agents").mkdir(parents=True, exist_ok=True)
    (src / "skills" / "cargo-workflow").mkdir(parents=True, exist_ok=True)
    (src / "commands").mkdir(parents=True, exist_ok=True)
    (src / "hooks").mkdir(parents=True, exist_ok=True)
    # Bodies are taken verbatim from the captured golden so the agent.md
    # body matches byte-for-byte.
    (src / "agents" / "rust-reviewer.md").write_text(_rust_reviewer_body())
    (src / "skills" / "cargo-workflow" / "SKILL.md").write_text(
        golden("rust/target/.github/skills/cargo-workflow/SKILL.md")
    )
    (src / "commands" / "clippy.md").write_text("clippy body\n")
    (src / "hooks" / "cargo-check.sh").write_text("#!/bin/bash\n")

    return manifest(
        src,
        agents=[
            {
                "name": "rust-reviewer",
                "description": "Reviews Rust code for idiomatic patterns, "
                "lifetimes, and clippy-clean style.",
                "tools": ["Read", "Grep", "Glob", "Bash"],
                "body_path": "agents/rust-reviewer.md",
            }
        ],
        skills=[{"name": "cargo-workflow", "path": "skills/cargo-workflow"}],
        commands=[
            {
                "name": "clippy",
                "description": "Run cargo clippy and propose fixes",
                "body_path": "commands/clippy.md",
            }
        ],
        hooks=[
            {
                "event": "PreToolUse",
                "matcher": "Bash",
                "script": "hooks/cargo-check.sh",
                "harnesses": ["claude"],
            }
        ],
    )


def _rust_reviewer_body() -> str:
    # The body is the golden agent.md minus its frontmatter block.
    g = golden("rust/target/.github/agents/rust-reviewer.agent.md")
    # Frontmatter is `---\n...\n---\n\n`; the body follows.
    _, _, after = g.partition("---\n\n")
    return after


def test_rust_profile_layout(target, src):
    m = _rust_manifest(src)
    out = renderer().render(m, target)

    assert (target / ".github/agents/rust-reviewer.agent.md").is_file()
    assert (target / ".github/skills/cargo-workflow/SKILL.md").is_file()
    # cargo-check hook is harnesses:[claude] only — copilot skips it.
    assert not (target / ".github/hooks/cargo-check.json").exists()
    # No copilot-harnessed MCPs -> no file.
    assert not (target / ".copilot/mcp-config.json").exists()
    # AGENTS.md never touched.
    assert not (target / "AGENTS.md").exists()
    # Commands are skipped — no file.
    assert not (target / ".github/commands/clippy.md").exists()
    # out_files tracks exactly the two whole-file artefacts, in order.
    assert out == [
        ".github/agents/rust-reviewer.agent.md",
        ".github/skills/cargo-workflow",
    ]


def test_rust_agent_file_byte_parity(target, src):
    m = _rust_manifest(src)
    renderer().render(m, target)
    produced = (target / ".github/agents/rust-reviewer.agent.md").read_text()
    assert produced == golden("rust/target/.github/agents/rust-reviewer.agent.md")


def test_rust_warns_on_skipped_command(target, src, capsys):
    m = _rust_manifest(src)
    renderer().render(m, target)
    assert "copilot: skipping command 'clippy'" in capsys.readouterr().err


# ─── MCP rendering with mandatory tools: ["*"] ─────────────────────────


def test_mcp_copilot_harnessed_byte_parity(target, src):
    m = manifest(
        src,
        mcps=[
            {
                "name": "foo",
                "command": "npx",
                "args": ["-y", "foo-mcp"],
                "harnesses": ["copilot"],
            }
        ],
    )
    renderer().render(m, target)
    produced = (target / ".copilot/mcp-config.json").read_text()
    assert produced == golden("mcp/target/.copilot/mcp-config.json")
    # The mandatory tools wildcard must be present.
    parsed = json.loads(produced)
    assert parsed["mcpServers"]["foo"]["tools"] == ["*"]
    assert parsed["mcpServers"]["foo"]["command"] == "npx"
    assert parsed["mcpServers"]["foo"]["args"] == ["-y", "foo-mcp"]


def test_mcp_claude_only_excluded(target, src):
    m = manifest(
        src,
        mcps=[{"name": "foo", "command": "x", "harnesses": ["claude"]}],
    )
    out = renderer().render(m, target)
    assert not (target / ".copilot/mcp-config.json").exists()
    assert out == []


def test_mcp_default_membership_excludes_copilot(target, src):
    # An MCP with no `harnesses` defaults to claude+codex (the bash
    # select() default for copilot). copilot is not in that default, so a
    # bare MCP is excluded — no file written.
    m = manifest(src, mcps=[{"name": "bar", "command": "x"}])
    renderer().render(m, target)
    assert not (target / ".copilot/mcp-config.json").exists()


def test_mcp_env_included_when_present(target, src):
    m = manifest(
        src,
        mcps=[
            {
                "name": "withenv",
                "command": "x",
                "env": {"K": "v"},
                "harnesses": ["copilot"],
            }
        ],
    )
    renderer().render(m, target)
    parsed = json.loads((target / ".copilot/mcp-config.json").read_text())
    entry = parsed["mcpServers"]["withenv"]
    assert entry["env"] == {"K": "v"}
    assert entry["args"] == []  # bash defaults absent args to []
    assert entry["tools"] == ["*"]


def test_mcp_merges_into_existing_user_file(target, src):
    cfg = target / ".copilot" / "mcp-config.json"
    cfg.parent.mkdir(parents=True)
    cfg.write_text(
        json.dumps({"mcpServers": {"user-mcp": {"command": "y"}}}) + "\n"
    )
    m = manifest(
        src,
        mcps=[{"name": "foo", "command": "x", "harnesses": ["copilot"]}],
    )
    renderer().render(m, target)
    parsed = json.loads(cfg.read_text())
    assert set(parsed["mcpServers"]) == {"user-mcp", "foo"}


# ─── hooks ─────────────────────────────────────────────────────────────


def test_hook_copilot_harnessed_byte_parity(target, src):
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\necho hi\n")
    m = manifest(
        src,
        hooks=[
            {
                "event": "PreToolUse",
                "matcher": "Bash",
                "script": "hooks/h.sh",
                "harnesses": ["copilot"],
            }
        ],
    )
    out = renderer().render(m, target)

    produced = (target / ".github/hooks/h.json").read_text()
    assert produced == golden("hook/target/.github/hooks/h.json")

    script = (target / ".github/hooks/h.sh").read_text()
    assert script == golden("hook/target/.github/hooks/h.sh")
    # Script copy is executable.
    assert (target / ".github/hooks/h.sh").stat().st_mode & 0o111

    # Script tracked before the json, matching the bash append order.
    assert out == [".github/hooks/h.sh", ".github/hooks/h.json"]


def test_hook_claude_only_skipped(target, src):
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\n")
    m = manifest(
        src,
        hooks=[
            {
                "event": "PreToolUse",
                "matcher": "Bash",
                "script": "hooks/h.sh",
                "harnesses": ["claude"],
            }
        ],
    )
    out = renderer().render(m, target)
    assert not (target / ".github/hooks/h.json").exists()
    assert out == []


def test_hook_missing_script_field_raises(target, src):
    m = manifest(
        src,
        hooks=[{"event": "PreToolUse", "harnesses": ["copilot"]}],
    )
    with pytest.raises(ValueError, match="missing 'script'"):
        renderer().render(m, target)


def test_hook_missing_script_file_raises(target, src):
    m = manifest(
        src,
        hooks=[
            {
                "event": "PreToolUse",
                "script": "hooks/nope.sh",
                "harnesses": ["copilot"],
            }
        ],
    )
    with pytest.raises(FileNotFoundError, match="hook script not found"):
        renderer().render(m, target)


# ─── models.copilot is ignored (model field stripped) ──────────────────


def test_model_copilot_stripped_byte_parity(target, src, capsys):
    (src / "agents").mkdir()
    (src / "agents" / "x.md").write_text("BODY\n")
    m = manifest(
        src,
        agents=[
            {
                "name": "x",
                "description": "d",
                "body_path": "agents/x.md",
                "models": {"copilot": "gpt-5"},
            }
        ],
    )
    renderer().render(m, target)

    produced = (target / ".github/agents/x.agent.md").read_text()
    assert produced == golden("model_strip/target/.github/agents/x.agent.md")
    # Neither the model value nor the models map leaks into frontmatter.
    assert "model: gpt-5" not in produced
    assert "models:" not in produced
    assert "copilot: model override on agent 'x' ignored" in capsys.readouterr().err


# ─── commands and permissions are skipped ──────────────────────────────


def test_commands_skipped_with_warning(target, src, capsys):
    (src / "commands").mkdir()
    (src / "commands" / "c.md").write_text("cmd body\n")
    m = manifest(
        src,
        commands=[
            {"name": "c", "description": "d", "body_path": "commands/c.md"}
        ],
    )
    renderer().render(m, target)
    assert "copilot: skipping command 'c'" in capsys.readouterr().err
    assert not (target / ".github/commands").exists()


# ─── out_files tracking ────────────────────────────────────────────────


def test_tracks_whole_file_artefacts(target, src):
    (src / "agents").mkdir()
    (src / "skills" / "k1").mkdir(parents=True)
    (src / "agents" / "a.md").write_text("BODY\n")
    (src / "skills" / "k1" / "SKILL.md").write_text("skill\n")
    m = manifest(
        src,
        agents=[{"name": "a", "body_path": "agents/a.md"}],
        skills=[{"name": "k1", "path": "skills/k1"}],
    )
    out = renderer().render(m, target)
    assert ".github/agents/a.agent.md" in out
    assert ".github/skills/k1" in out
    # Agent file body parity (no description, just name).
    assert (target / ".github/agents/a.agent.md").read_text() == golden(
        "track/target/.github/agents/a.agent.md"
    )


# ─── clean: surgical MCP entry removal ─────────────────────────────────


def test_clean_removes_our_entries_preserves_user(target, src):
    cfg = target / ".copilot" / "mcp-config.json"
    cfg.parent.mkdir(parents=True)
    cfg.write_text(
        '{"mcpServers": {"foo": {"command": "x", "tools": ["*"]}, '
        '"user-mcp": {"command": "y", "tools": ["*"]}}}\n'
    )
    m = manifest(
        src,
        mcps=[{"name": "foo", "command": "x", "harnesses": ["copilot"]}],
    )
    renderer().clean(m, target)
    produced = cfg.read_text()
    assert produced == golden("clean/target/.copilot/mcp-config.json")
    parsed = json.loads(produced)
    assert "foo" not in parsed["mcpServers"]
    assert "user-mcp" in parsed["mcpServers"]


def test_clean_removes_bootstrapped_empty_file(target, src):
    cfg = target / ".copilot" / "mcp-config.json"
    cfg.parent.mkdir(parents=True)
    cfg.write_text('{"mcpServers": {"foo": {"command": "x", "tools": ["*"]}}}\n')
    m = manifest(
        src,
        mcps=[{"name": "foo", "command": "x", "harnesses": ["copilot"]}],
    )
    renderer().clean(m, target)
    # We were the only writer -> empty {} -> file removed.
    assert not cfg.exists()


def test_clean_no_file_is_noop(target, src):
    m = manifest(
        src,
        mcps=[{"name": "foo", "command": "x", "harnesses": ["copilot"]}],
    )
    renderer().clean(m, target)  # must not raise
    assert not (target / ".copilot/mcp-config.json").exists()


# ─── round-trip: render then clean leaves bootstrapped file gone ───────


def test_render_then_clean_round_trip(target, src):
    m = manifest(
        src,
        mcps=[
            {
                "name": "foo",
                "command": "npx",
                "args": ["-y", "foo-mcp"],
                "harnesses": ["copilot"],
            }
        ],
    )
    renderer().render(m, target)
    assert (target / ".copilot/mcp-config.json").is_file()
    renderer().clean(m, target)
    assert not (target / ".copilot/mcp-config.json").exists()


# ─── canonical permissions (curd 4) ─────────────────────────────────────

from agent_profile.renderers.copilot import launch_flags as _launch_flags  # noqa: E402


def _perm_manifest(src: Path, settings: dict, **sections) -> Manifest:
    m = manifest(src, **sections)
    m.settings = settings
    return m


# Lever 1 — launch-flag emission.


def test_launch_flags_allow_bash_to_shell(src):
    m = _perm_manifest(src, {"permissions_allow": ["Bash(git:*)"]})
    assert _launch_flags(m) == ["--allow-tool=shell(git)"]


def test_launch_flags_multiword_bash_keeps_spaces(src):
    m = _perm_manifest(src, {"permissions_allow": ["Bash(gh pr view:*)"]})
    assert _launch_flags(m) == ["--allow-tool=shell(gh pr view)"]


def test_launch_flags_deny_bash(src):
    m = _perm_manifest(src, {"permissions_deny": ["Bash(rm -rf:*)"]})
    assert _launch_flags(m) == ["--deny-tool=shell(rm -rf)"]


def test_launch_flags_mcp_whole_server(src):
    m = _perm_manifest(src, {"permissions_allow": ["mcp__tilth__*"]})
    assert _launch_flags(m) == ["--allow-tool=tilth"]


def test_launch_flags_mcp_named_tool(src):
    m = _perm_manifest(src, {"permissions_allow": ["mcp__tilth__tilth_read"]})
    assert _launch_flags(m) == ["--allow-tool=tilth(tilth_read)"]


def test_launch_flags_skip_non_shell_non_mcp(src):
    m = _perm_manifest(
        src,
        {"permissions_allow": ["Edit", "Write", "Skill"], "permissions_deny": ["Grep", "Glob"]},
    )
    assert _launch_flags(m) == []


def test_launch_flags_mixed_allow_first_then_deny_sorted(src):
    m = _perm_manifest(
        src,
        {
            "permissions_allow": ["Bash(git:*)", "Bash(gh:*)", "mcp__tilth__*", "Edit"],
            "permissions_deny": ["Bash(sudo:*)", "Bash(rm -rf:*)", "Grep"],
        },
    )
    assert _launch_flags(m) == [
        "--allow-tool=shell(gh)",
        "--allow-tool=shell(git)",
        "--allow-tool=tilth",
        "--deny-tool=shell(rm -rf)",
        "--deny-tool=shell(sudo)",
    ]


def test_launch_flags_empty_when_no_canonical_rules(src):
    assert _launch_flags(manifest(src)) == []


# Lever 3 — mcp-config tools[] derivation.


def test_mcp_config_whole_server_gets_star(src, target):
    m = _perm_manifest(
        src,
        {"permissions_allow": ["mcp__tilth__*"]},
        mcps=[{"name": "tilth", "command": "tilth", "harnesses": ["copilot"]}],
    )
    CopilotRenderer().render(m, target)
    import json as _json

    data = _json.loads((target / ".copilot" / "mcp-config.json").read_text())
    assert data["mcpServers"]["tilth"]["tools"] == ["*"]


# Lever 1 — MCP DENY flags (documented in launch_flags but otherwise untested).


def test_launch_flags_mcp_named_tool_deny(src):
    """`mcp__<s>__<t>` deny lowers to `--deny-tool=<s>(<t>)`. The deny channel
    runs through the SAME classifier as allow; a regression that only parsed
    MCP rules on the allow side would silently drop this."""
    m = _perm_manifest(src, {"permissions_deny": ["mcp__tilth__tilth_write"]})
    assert _launch_flags(m) == ["--deny-tool=tilth(tilth_write)"]


def test_launch_flags_mcp_whole_server_deny(src):
    """`mcp__<s>__*` deny lowers to a whole-server `--deny-tool=<s>` flag."""
    m = _perm_manifest(src, {"permissions_deny": ["mcp__tilth__*"]})
    assert _launch_flags(m) == ["--deny-tool=tilth"]


def test_launch_flags_sanctioned_tools_only_in_allow_never_deny(src):
    """Negative (spec test plan): rg/fd/sg stay allowed after the deny seed.
    They must emit `--allow-tool=shell(...)` and never `--deny-tool`, and the
    deny channel only carries the genuinely-denied tools."""
    m = _perm_manifest(
        src,
        {
            "permissions_allow": ["Bash(rg:*)", "Bash(fd:*)", "Bash(sg:*)"],
            "permissions_deny": ["Bash(grep:*)", "Bash(sudo:*)"],
        },
    )
    flags = _launch_flags(m)
    for tool in ("rg", "fd", "sg"):
        assert f"--allow-tool=shell({tool})" in flags
        assert f"--deny-tool=shell({tool})" not in flags
    assert "--deny-tool=shell(grep)" in flags
    assert "--deny-tool=shell(sudo)" in flags


def test_mcp_config_named_tools_become_explicit_list(src, target):
    m = _perm_manifest(
        src,
        {"permissions_allow": ["mcp__tilth__tilth_read", "mcp__tilth__tilth_list"]},
        mcps=[{"name": "tilth", "command": "tilth", "harnesses": ["copilot"]}],
    )
    CopilotRenderer().render(m, target)
    import json as _json

    data = _json.loads((target / ".copilot" / "mcp-config.json").read_text())
    assert data["mcpServers"]["tilth"]["tools"] == ["tilth_list", "tilth_read"]


def test_mcp_config_defaults_to_star_with_no_canonical_rule(src, target):
    """A server with no canonical MCP rule keeps the prior default (["*"])."""
    m = manifest(
        src, mcps=[{"name": "tilth", "command": "tilth", "harnesses": ["copilot"]}]
    )
    CopilotRenderer().render(m, target)
    import json as _json

    data = _json.loads((target / ".copilot" / "mcp-config.json").read_text())
    assert data["mcpServers"]["tilth"]["tools"] == ["*"]
