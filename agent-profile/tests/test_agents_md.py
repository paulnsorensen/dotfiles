"""test_agents_md.py — shared agent-markdown writers (parity with the bash).

The bats ``agent-profile-agents-md.bats`` asserts on the AGENTS.md *doc*
section, which the wiring phase owns (the doc is not Python behavior).
The behavioral analogue in the Python port is the agent-markdown a
profile renders into the cross-harness ``.claude/agents/<n>.md`` shared
path and the per-harness model-override files — those byte shapes are
what every harness's agent surface consumes. Golden bytes captured from
running the bash shared_writer against the ``multi`` profile.
"""

from __future__ import annotations

import pytest

from agent_profile import shared


def test_shared_claude_agent_frontmatter_matches_golden(tmp_path, golden):
    body = tmp_path / "body.md"
    body.write_text("line one\nline two\n")
    out: list[str] = []
    # Frontmatter as the bash builds it for the multi profile shared agent
    # (name, description, joined tools) — insertion order preserved.
    shared.write_shared_claude_agent(
        tmp_path,
        "shared-agent",
        body,
        {
            "name": "shared-agent",
            "description": "cross-harness agent",
            "tools": "Read, Grep",
        },
        out,
    )
    written = (tmp_path / ".claude/agents/shared-agent.md").read_text()
    assert written == golden("trees/shared_agent_multi.md")
    assert out == [".claude/agents/shared-agent.md"]


def test_shared_claude_agent_no_frontmatter_when_empty(tmp_path):
    body = tmp_path / "b.md"
    body.write_text("Reviewer body for foo\n")
    out: list[str] = []
    # Empty frontmatter -> body written verbatim, no --- fence (matches the
    # bash, which emits the fence only for non-empty/non-{} frontmatter).
    shared.write_shared_claude_agent(tmp_path, "reviewer", body, None, out)
    written = (tmp_path / ".claude/agents/reviewer.md").read_text()
    assert written == "Reviewer body for foo\n"


def test_shared_claude_agent_missing_body_fails(tmp_path):
    out: list[str] = []
    with pytest.raises(FileNotFoundError, match="body not found"):
        shared.write_shared_claude_agent(
            tmp_path, "x", tmp_path / "nope.md", {"name": "x"}, out
        )


def test_track_file_dedups(tmp_path):
    body = tmp_path / "b.md"
    body.write_text("body\n")
    out: list[str] = []
    shared.write_shared_claude_agent(tmp_path, "x", body, None, out)
    shared.write_shared_claude_agent(tmp_path, "x", body, None, out)
    # Two writes of the same shared path -> one manifest entry.
    assert out == [".claude/agents/x.md"]


def test_model_override_writes_frontmatter(tmp_path):
    body = tmp_path / "b.md"
    body.write_text("agent body\n")
    out: list[str] = []
    shared.render_model_override(
        tmp_path, "opencode", "agent_singular", "a", body, "claude-opus", out
    )
    written = (tmp_path / ".opencode/agent/a.md").read_text()
    assert written == "---\nmodel: claude-opus\n---\nagent body\n"
    assert out == [".opencode/agent/a.md"]


def test_model_override_inherit_is_noop(tmp_path):
    body = tmp_path / "b.md"
    body.write_text("body\n")
    out: list[str] = []
    shared.render_model_override(tmp_path, "cursor", "agent", "a", body, "inherit", out)
    assert out == []
    assert not (tmp_path / ".cursor").exists()


def test_model_override_command_kind_uses_commands_dir(tmp_path):
    body = tmp_path / "b.md"
    body.write_text("cmd body\n")
    out: list[str] = []
    shared.render_model_override(tmp_path, "opencode", "command", "do-thing", body, "m", out)
    assert (tmp_path / ".opencode/commands/do-thing.md").is_file()
    assert out == [".opencode/commands/do-thing.md"]


def test_model_override_unknown_kind_raises(tmp_path):
    body = tmp_path / "b.md"
    body.write_text("body\n")
    with pytest.raises(ValueError, match="unknown kind"):
        shared.render_model_override(tmp_path, "x", "bogus", "a", body, "m", [])


def test_copy_shared_skill_copies_tree(tmp_path):
    src = tmp_path / "src"
    (src).mkdir()
    (src / "SKILL.md").write_text("skill body\n")
    (src / "extra.txt").write_text("more\n")
    out: list[str] = []
    shared.copy_shared_skill(tmp_path, "widget", src, out)
    dst = tmp_path / ".agents/skills/widget"
    assert (dst / "SKILL.md").read_text() == "skill body\n"
    assert (dst / "extra.txt").read_text() == "more\n"
    assert out == [".agents/skills/widget"]
