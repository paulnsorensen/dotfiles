"""test_skill_fetch_wiring.py — install fetches source: skills, copies path:.

cmd_install must fetch every `source:` skill for each in-scope harness via
the injected fetch runner, while `path:` (local-tree) skills are still copied
by the renderers. A `source:`-only skill item (no `path`) must NOT be copied
by any renderer (that would copy the repo root by accident).
"""

from __future__ import annotations

import pytest

from agent_profile import cli
from agent_profile.parse import parse_manifest
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer
from agent_profile.renderers.copilot import CopilotRenderer
from tests.conftest import write_profile


# ─── renderers skip source-only skills ────────────────────────────────


@pytest.fixture
def source_only_profile(env):
    return write_profile(
        env.profiles,
        "extprof",
        "name: extprof\n"
        "skills:\n"
        "  - name: mold\n    source: paulnsorensen/easy-cheese\n"
        "  - name: local-skill\n    path: skills/local-skill\n",
        {"skills/local-skill/SKILL.md": "# local\n"},
    )


def test_claude_skips_source_only_skill(env, source_only_profile):
    manifest = parse_manifest(source_only_profile)
    ClaudeRenderer().render(manifest, env.target)
    plugin_skills = env.target / ".claude/plugins/local/extprof/skills"
    # local path: skill is copied; source: skill is not (no 'mold' dir).
    assert (plugin_skills / "local-skill").is_dir()
    assert not (plugin_skills / "mold").exists()


def test_codex_skips_source_only_skill(env, source_only_profile):
    manifest = parse_manifest(source_only_profile)
    CodexRenderer().render(manifest, env.target)
    shared_skills = env.target / ".agents/skills"
    assert (shared_skills / "local-skill").is_dir()
    assert not (shared_skills / "mold").exists()


def test_copilot_skips_source_only_skill(env, source_only_profile):
    manifest = parse_manifest(source_only_profile)
    CopilotRenderer().render(manifest, env.target)
    gh_skills = env.target / ".github/skills"
    assert (gh_skills / "local-skill").is_dir()
    assert not (gh_skills / "mold").exists()


# ─── cmd_install fetches source: skills ───────────────────────────────


def test_install_fetches_source_skills_per_harness(env, stub_renderers, monkeypatch, capsys):
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\n"
        "skills:\n"
        "  - name: mold\n    source: paulnsorensen/easy-cheese\n    pin: v1\n",
    )
    calls = []
    monkeypatch.setattr(cli, "_skill_fetch_runner", lambda argv: calls.append(argv) or 0)

    assert cli.main(["install", "extprof", "--harness", "claude"]) == 0
    # One fetch for the single source skill, targeting claude.
    fetches = [c for c in calls if c[:3] == ["gh", "skill", "install"]]
    assert len(fetches) == 1
    argv = fetches[0]
    assert "paulnsorensen/easy-cheese" in argv
    assert "mold" in argv
    assert argv[argv.index("--agent") + 1] == "claude-code"
    assert argv[argv.index("--pin") + 1] == "v1"


def test_install_fetches_for_each_in_scope_harness(env, stub_renderers, monkeypatch):
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\nskills:\n  - name: cook\n    source: o/r\n",
    )
    calls = []
    monkeypatch.setattr(cli, "_skill_fetch_runner", lambda argv: calls.append(argv) or 0)

    assert cli.main(["install", "extprof", "--harness", "claude,codex"]) == 0
    agents = sorted(c[c.index("--agent") + 1] for c in calls if "gh" == c[0])
    assert agents == ["claude-code", "codex"]


def test_install_skips_fetch_when_no_source_skills(env, stub_renderers, monkeypatch):
    write_profile(env.profiles, "noext", "name: noext\n")
    calls = []
    monkeypatch.setattr(cli, "_skill_fetch_runner", lambda argv: calls.append(argv) or 0)
    assert cli.main(["install", "noext", "--harness", "claude"]) == 0
    assert calls == []
