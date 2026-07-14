"""test_renderer_agents.py — cross-harness agent rendering (Phase 1).

Covers the behaviour added when the cheese sub-agents began rendering through
``ap`` into every harness instead of reaching Claude via a legacy symlink:

  - a leading YAML frontmatter block is stripped from agent bodies, so no
    harness emits a double frontmatter block and codex does not leak
    frontmatter into ``developer_instructions``;
  - ``disallowedTools`` survives into the claude / cursor / copilot
    frontmatter (the read-only restriction the cheese agents depend on);
  - read-only intent maps to codex ``sandbox_mode`` and an opencode
    ``permission.edit: deny``;
  - opencode emits a real ``agents/<name>.md`` subagent file (root-relative
    to its target config dir → ``~/.config/opencode/agents/``).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from agent_profile.parse import Manifest, parse_one
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer
from agent_profile.renderers.copilot import CopilotRenderer
from agent_profile.renderers.cursor import CursorRenderer
from agent_profile.renderers.opencode import OpencodeRenderer
from agent_profile.shared import agent_is_read_only, strip_frontmatter

_PLAIN_BODY = "You are the ghostbuster.\n"
_FRONTMATTERED_BODY = (
    "---\n"
    "name: ghostbuster\n"
    "description: stale frontmatter metadata\n"
    "disallowedTools: [Edit, Write]\n"
    "---\n"
    "You are the ghostbuster.\n"
)


def _agent_manifest(
    tmp_path: Path, *, body: str = _PLAIN_BODY, **agent_over: Any
) -> Manifest:
    """A one-agent manifest whose body lives under ``tmp_path/src``."""
    src = tmp_path / "src"
    src.mkdir(exist_ok=True)
    (src / "ghostbuster.md").write_text(body)
    agent: dict[str, Any] = {
        "name": "ghostbuster",
        "description": "Finds dead code",
        "_source_dir": str(src),
        "body_path": "ghostbuster.md",
    }
    agent.update(agent_over)
    return Manifest(name="cheese", agents=[agent])


def _delims(content: str) -> int:
    return content.splitlines().count("---")


# ── strip_frontmatter unit ────────────────────────────────────────────


def test_strip_frontmatter_removes_leading_block() -> None:
    assert strip_frontmatter("---\na: 1\n---\nbody\n") == "body\n"


def test_strip_frontmatter_keeps_plain_body() -> None:
    text = "body\n---\nnot frontmatter\n"
    assert strip_frontmatter(text) == text


def test_strip_frontmatter_unterminated_is_noop() -> None:
    text = "---\nopened but never closed\n"
    assert strip_frontmatter(text) == text


# ── read-only intent ──────────────────────────────────────────────────


def test_agent_is_read_only_from_disallowed() -> None:
    assert agent_is_read_only({"disallowedTools": ["Edit", "Write"]})


def test_agent_is_read_only_from_whitelist() -> None:
    assert agent_is_read_only({"tools": ["Read", "Grep"]})


def test_agent_writable_when_tools_include_write() -> None:
    assert not agent_is_read_only({"tools": ["Read", "Edit"]})


def test_agent_writable_when_no_signal() -> None:
    assert not agent_is_read_only({})


def test_agent_writable_when_whitelist_grants_tilth_write() -> None:
    # tilth's writer is a write surface even though the built-in Write is absent.
    assert not agent_is_read_only(
        {"tools": ["Read", "Grep", "mcp__tilth__tilth_write"]}
    )


def test_agent_writable_when_whitelist_grants_serena_editor() -> None:
    assert not agent_is_read_only(
        {"tools": ["Read", "mcp__serena__replace_symbol_body"]}
    )


def test_agent_writable_when_whitelist_grants_serena_wildcard() -> None:
    # mcp__serena__* subsumes serena's editors — not read-only.
    assert not agent_is_read_only(
        {"tools": ["Read", "Grep", "Glob", "Bash", "mcp__serena__*"]}
    )


def test_agent_read_only_when_whitelist_is_pure_serena_readers() -> None:
    # A wildcard is required to grant writes; naming only read tools stays read-only.
    assert agent_is_read_only(
        {"tools": ["Read", "mcp__serena__find_symbol", "mcp__serena__get_symbols_overview"]}
    )


def test_agent_is_read_only_from_disallowed_mcp_write() -> None:
    assert agent_is_read_only({"disallowedTools": ["mcp__tilth__tilth_write"]})


# ── schema flow-through (parse keeps the field) ────────────────────────


def test_parse_carries_disallowed_tools(tmp_path: Path) -> None:
    (tmp_path / "profile.yaml").write_text(
        "name: p\nagents:\n  - name: ghostbuster\n"
        "    disallowedTools: [Edit, Write]\n"
    )
    parsed = parse_one(tmp_path)
    assert parsed["agents"][0]["disallowedTools"] == ["Edit", "Write"]


# ── claude ────────────────────────────────────────────────────────────


def test_claude_shared_agent_strips_frontmatter(tmp_path: Path) -> None:
    ClaudeRenderer().render(
        _agent_manifest(tmp_path, body=_FRONTMATTERED_BODY, tools=["Read"]),
        tmp_path,
    )
    content = (tmp_path / ".claude" / "agents" / "ghostbuster.md").read_text()
    assert _delims(content) == 2
    assert "stale frontmatter metadata" not in content
    assert content.rstrip().endswith("You are the ghostbuster.")


def test_claude_agent_disallowed_tools(tmp_path: Path) -> None:
    ClaudeRenderer().render(
        _agent_manifest(
            tmp_path, tools=["Read"], disallowedTools=["Edit", "Write"]
        ),
        tmp_path,
    )
    shared_file = (
        tmp_path / ".claude" / "agents" / "ghostbuster.md"
    ).read_text()
    assert "disallowedTools: [Edit, Write]" in shared_file

def test_claude_shared_agent_carries_model_color_effort_skills_max_turns(
    tmp_path: Path,
) -> None:
    # The user-scoped shared file wins over the plugin copy (priority 4 > 5),
    # so it must carry the full claude metadata — a model-neutral shared file
    # would silently drop the agent's pinned model and its color/effort/maxTurns/skills.
    ClaudeRenderer().render(
        _agent_manifest(
            tmp_path,
            tools=["Read"],
            models={"claude": "sonnet"},
            color="red",
            effort="high",
            skills=["scout", "gh"],
            maxTurns=20,
        ),
        tmp_path,
    )
    shared_file = (
        tmp_path / ".claude" / "agents" / "ghostbuster.md"
    ).read_text()
    assert "model: sonnet" in shared_file
    assert "color: red" in shared_file
    assert "effort: high" in shared_file
    assert "skills: [scout, gh]" in shared_file
    assert "maxTurns: 20" in shared_file


# ── cursor ────────────────────────────────────────────────────────────


def test_cursor_shared_agent_strips_frontmatter(tmp_path: Path) -> None:
    CursorRenderer().render(
        _agent_manifest(tmp_path, body=_FRONTMATTERED_BODY, tools=["Read"]),
        tmp_path,
    )
    content = (tmp_path / ".claude" / "agents" / "ghostbuster.md").read_text()
    assert _delims(content) == 2
    assert "stale frontmatter metadata" not in content


def test_cursor_agent_disallowed_tools(tmp_path: Path) -> None:
    CursorRenderer().render(
        _agent_manifest(
            tmp_path, tools=["Read"], disallowedTools=["Edit", "Write"]
        ),
        tmp_path,
    )
    content = (tmp_path / ".claude" / "agents" / "ghostbuster.md").read_text()
    assert "disallowedTools: [Edit, Write]" in content


# ── codex ─────────────────────────────────────────────────────────────


def test_codex_body_excludes_frontmatter(tmp_path: Path) -> None:
    CodexRenderer().render(
        _agent_manifest(tmp_path, body=_FRONTMATTERED_BODY), tmp_path
    )
    content = (tmp_path / ".codex" / "agents" / "ghostbuster.toml").read_text()
    assert "stale frontmatter metadata" not in content
    assert "You are the ghostbuster." in content


def test_codex_agent_renders_gpt_5_6_model_override(tmp_path: Path) -> None:
    CodexRenderer().render(
        _agent_manifest(tmp_path, models={"codex": "gpt-5.6-sol"}), tmp_path
    )
    content = (tmp_path / ".codex" / "agents" / "ghostbuster.toml").read_text()
    assert 'model = "gpt-5.6-sol"' in content


def test_codex_sandbox_read_only_from_whitelist(tmp_path: Path) -> None:
    CodexRenderer().render(
        _agent_manifest(tmp_path, tools=["Read", "Grep"]), tmp_path
    )
    content = (tmp_path / ".codex" / "agents" / "ghostbuster.toml").read_text()
    assert 'sandbox_mode = "read-only"' in content


def test_codex_sandbox_read_only_from_disallowed(tmp_path: Path) -> None:
    CodexRenderer().render(
        _agent_manifest(tmp_path, disallowedTools=["Edit", "Write"]), tmp_path
    )
    content = (tmp_path / ".codex" / "agents" / "ghostbuster.toml").read_text()
    assert 'sandbox_mode = "read-only"' in content


def test_codex_no_sandbox_when_writable(tmp_path: Path) -> None:
    CodexRenderer().render(
        _agent_manifest(tmp_path, tools=["Read", "Edit"]), tmp_path
    )
    content = (tmp_path / ".codex" / "agents" / "ghostbuster.toml").read_text()
    assert "sandbox_mode" not in content


# ── copilot ───────────────────────────────────────────────────────────


def test_copilot_agent_strips_frontmatter(tmp_path: Path) -> None:
    CopilotRenderer().render(
        _agent_manifest(tmp_path, body=_FRONTMATTERED_BODY, tools=["Read"]),
        tmp_path,
    )
    content = (
        tmp_path / ".github" / "agents" / "ghostbuster.agent.md"
    ).read_text()
    assert _delims(content) == 2
    assert "stale frontmatter metadata" not in content


def test_copilot_agent_disallowed_tools(tmp_path: Path) -> None:
    CopilotRenderer().render(
        _agent_manifest(
            tmp_path, tools=["Read"], disallowedTools=["Edit", "Write"]
        ),
        tmp_path,
    )
    content = (
        tmp_path / ".github" / "agents" / "ghostbuster.agent.md"
    ).read_text()
    assert "disallowedTools: [Edit, Write]" in content


# ── opencode ──────────────────────────────────────────────────────────


def test_opencode_renders_subagent(tmp_path: Path) -> None:
    written = OpencodeRenderer().render(
        _agent_manifest(
            tmp_path, tools=["Read", "Grep"], models={"opencode": "gpt-5.4"}
        ),
        tmp_path,
    )
    rel = "agents/ghostbuster.md"
    assert rel in written
    content = (tmp_path / "agents" / "ghostbuster.md").read_text()
    assert content.startswith("---\n")
    assert "mode: subagent" in content
    assert "description: Finds dead code" in content
    assert "model: gpt-5.4" in content
    assert content.rstrip().endswith("You are the ghostbuster.")


def test_opencode_subagent_read_only_permission(tmp_path: Path) -> None:
    OpencodeRenderer().render(
        _agent_manifest(tmp_path, tools=["Read", "Grep"]), tmp_path
    )
    content = (tmp_path / "agents" / "ghostbuster.md").read_text()
    assert "permission:" in content
    assert "edit: deny" in content


def test_opencode_subagent_writable_omits_permission(tmp_path: Path) -> None:
    OpencodeRenderer().render(
        _agent_manifest(tmp_path, tools=["Read", "Edit"]), tmp_path
    )
    content = (tmp_path / "agents" / "ghostbuster.md").read_text()
    assert "edit: deny" not in content


def test_opencode_subagent_strips_frontmatter(tmp_path: Path) -> None:
    OpencodeRenderer().render(
        _agent_manifest(tmp_path, body=_FRONTMATTERED_BODY), tmp_path
    )
    content = (tmp_path / "agents" / "ghostbuster.md").read_text()
    assert _delims(content) == 2
    assert "stale frontmatter metadata" not in content


def test_opencode_subagent_omits_inherit_model(tmp_path: Path) -> None:
    OpencodeRenderer().render(
        _agent_manifest(tmp_path, tools=["Read"], models={"opencode": "inherit"}),
        tmp_path,
    )
    content = (tmp_path / "agents" / "ghostbuster.md").read_text()
    assert "model:" not in content


# ── hardening (press) ─────────────────────────────────────────────────


def test_cursor_model_override_strips_frontmatter(tmp_path: Path) -> None:
    """A cursor model override writes ``.cursor/agents/<n>.md`` via
    render_model_override, which reads the body itself — its strip must also
    fire, or a frontmattered body double-frontmatters in that file."""
    CursorRenderer().render(
        _agent_manifest(
            tmp_path,
            body=_FRONTMATTERED_BODY,
            models={"cursor": "claude-sonnet"},
        ),
        tmp_path,
    )
    content = (tmp_path / ".cursor" / "agents" / "ghostbuster.md").read_text()
    assert _delims(content) == 2
    assert "stale frontmatter metadata" not in content
    assert content.rstrip().endswith("You are the ghostbuster.")


def test_agent_writable_when_disallowed_is_non_write_only() -> None:
    assert not agent_is_read_only({"disallowedTools": ["WebSearch", "WebFetch"]})


def test_agent_read_only_for_full_write_tool_set() -> None:
    assert agent_is_read_only({"disallowedTools": ["NotebookEdit"]})
    assert agent_is_read_only({"disallowedTools": ["MultiEdit"]})


def test_strip_frontmatter_preserves_later_horizontal_rule() -> None:
    text = "---\na: 1\n---\nbefore\n\n---\n\nafter\n"
    assert strip_frontmatter(text) == "before\n\n---\n\nafter\n"


def test_strip_frontmatter_empty_frontmatter_block() -> None:
    assert strip_frontmatter("---\n---\nbody\n") == "body\n"


def test_strip_frontmatter_crlf_block() -> None:
    assert strip_frontmatter("---\r\na: 1\r\n---\r\nbody\r\n") == "body\r\n"


def test_agent_harness_filtering_applies_to_all_agent_renderers(tmp_path: Path) -> None:
    agent = _agent_manifest(tmp_path, harnesses=["codex"])

    ClaudeRenderer().render(agent, tmp_path / "claude")
    CursorRenderer().render(agent, tmp_path / "cursor")
    OpencodeRenderer().render(agent, tmp_path / "opencode")
    CopilotRenderer().render(agent, tmp_path / "copilot")
    CodexRenderer().render(agent, tmp_path / "codex")

    assert not (tmp_path / "claude" / ".claude" / "agents" / "ghostbuster.md").exists()
    assert not (tmp_path / "cursor" / ".claude" / "agents" / "ghostbuster.md").exists()
    assert not (tmp_path / "opencode" / "agents" / "ghostbuster.md").exists()
    assert not (tmp_path / "copilot" / ".github" / "agents" / "ghostbuster.agent.md").exists()
    content = (tmp_path / "codex" / ".codex" / "agents" / "ghostbuster.toml").read_text()
    assert 'name = "ghostbuster"' in content
    assert 'description = "Finds dead code"' in content


def test_codex_renderer_skips_codex_native_plugin_agents(tmp_path: Path) -> None:
    CodexRenderer().render(
        _agent_manifest(tmp_path, _from_codex_native_plugin=True),
        tmp_path,
    )

    assert not (tmp_path / ".codex" / "agents" / "ghostbuster.toml").exists()


def test_copilot_agent_frontmatter_strips_plugin_internal_fields(tmp_path: Path) -> None:
    CopilotRenderer().render(
        _agent_manifest(
            tmp_path,
            harnesses=["copilot"],
            _from_native_plugin=True,
            _from_codex_native_plugin=True,
        ),
        tmp_path,
    )

    content = (tmp_path / ".github" / "agents" / "ghostbuster.agent.md").read_text()
    assert "name: ghostbuster" in content
    assert "description: Finds dead code" in content
    assert "harnesses:" not in content
    assert "_from_native_plugin:" not in content
    assert "_from_codex_native_plugin:" not in content


def _skill_manifest(tmp_path: Path, **skill_over: Any) -> Manifest:
    """A one-skill manifest whose tree lives under ``tmp_path/skillsrc/deslop``."""
    src = tmp_path / "skillsrc" / "deslop"
    src.mkdir(parents=True, exist_ok=True)
    (src / "SKILL.md").write_text("# deslop\n")
    skill: dict[str, Any] = {
        "name": "deslop",
        "path": "deslop",
        "_source_dir": str(tmp_path / "skillsrc"),
    }
    skill.update(skill_over)
    return Manifest(name="cheese", skills=[skill])


def test_skill_harness_filtering_applies_to_all_skill_renderers(tmp_path: Path) -> None:
    # Sibling of the agent test above: every skill renderer now projects through
    # skills_for(). A codex-only skill must reach codex and no other harness; a
    # renderer that reverted to manifest.skills would emit it everywhere.
    skill = _skill_manifest(tmp_path, harnesses=["codex"])

    ClaudeRenderer().render(skill, tmp_path / "claude")
    CursorRenderer().render(skill, tmp_path / "cursor")
    OpencodeRenderer().render(skill, tmp_path / "opencode")
    CopilotRenderer().render(skill, tmp_path / "copilot")
    CodexRenderer().render(skill, tmp_path / "codex")

    assert not (tmp_path / "claude" / ".claude" / "skills" / "deslop").exists()
    assert not (tmp_path / "cursor" / ".agents" / "skills" / "deslop").exists()
    assert not (tmp_path / "opencode" / "skills" / "deslop").exists()
    assert not (tmp_path / "copilot" / ".github" / "skills" / "deslop").exists()
    codex_skill = tmp_path / "codex" / ".agents" / "skills" / "deslop" / "SKILL.md"
    assert codex_skill.read_text() == "# deslop\n"
