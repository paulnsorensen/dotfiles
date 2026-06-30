from __future__ import annotations

import json

import pytest

from agent_profile import cli, compile_command
from agent_profile.renderers.registry import build_registry
from tests.compile_fixtures import (
    write_live_profile,
    write_minimal_includes,
    write_text,
)


def run(argv: list[str]) -> int:
    return cli.main(argv)


@pytest.fixture
def prod_renderers():
    """Wire the production renderers for one test (compile uses cli.RENDERERS)."""
    saved = cli.RENDERERS
    cli.set_renderers(build_registry())
    yield
    cli.set_renderers(saved)


_USER_MCP = {
    "name": "context7",
    "command": "npx",
    "args": ["-y", "@upstash/context7-mcp"],
    "env": {"CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"},
    "harnesses": ["claude"],
}


def test_compile_live_writes_harness_fragments_and_target_manifest(
    env, monkeypatch, stub_renderers
):
    write_minimal_includes(env.profiles)
    profile_dir = write_live_profile(
        env.profiles,
        agents=[{"name": "reviewer", "body_path": "reviewer.md"}],
    )
    write_text(profile_dir / "reviewer.md", "review body\n")
    home = env.tmp / "home"
    baseline = env.tmp / "baseline"
    out = env.tmp / "compiled"
    baseline.mkdir()
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))

    assert run(["compile", "live", "--baseline", str(baseline), "--out", str(out)]) == 0

    claude_agent = out / "fragments/home/claude/.claude/agents/reviewer.md"
    codex_agent = out / "fragments/home/codex/.codex/agents/reviewer.md"
    opencode_agent = out / "fragments/opencode/opencode/.opencode/agents/reviewer.md"
    assert claude_agent.read_text() == "review body\n"
    assert codex_agent.read_text() == "review body\n"
    assert opencode_agent.read_text() == "review body\n"

    data = json.loads((out / "manifest.json").read_text())
    assert data["profile"] == "live"
    assert data["compile_targets"] == [
        {
            "name": "home",
            "symbolic_root": "$HOME",
            "resolved_root": str(home),
            "harnesses": ["claude", "codex", "cursor", "copilot"],
        },
        {
            "name": "opencode",
            "symbolic_root": "$HOME/.config/opencode",
            "resolved_root": str(home / ".config/opencode"),
            "harnesses": ["opencode"],
        },
    ]
    assert {
        (entry["target"], entry["harness"], entry["relative_path"])
        for entry in data["files"]
    } >= {
        ("home", "claude", ".claude/agents/reviewer.md"),
        ("home", "codex", ".codex/agents/reviewer.md"),
        ("opencode", "opencode", ".opencode/agents/reviewer.md"),
    }


def test_compile_user_scope_does_not_mutate_live_or_require_claude(
    env, monkeypatch, prod_renderers
):
    """Finding 1 regression: ``ap compile`` of a ``mcp_scope: user`` profile is
    side-effect-free — it neither shells out to ``claude`` nor touches the live
    ``~/.claude.json``. The user-scope registration is recorded in the manifest
    (literal ``${VAR}``, not the resolved secret) for ``apply`` to perform
    post-gate. Before the fix the claude renderer shelled ``claude mcp add``
    during compile, so a host without the CLI aborted the whole sync."""
    write_minimal_includes(env.profiles)
    write_live_profile(env.profiles, mcp_scope="user", mcps=[_USER_MCP])
    home = env.tmp / "home"
    baseline = env.tmp / "baseline"
    out = env.tmp / "compiled"
    home.mkdir()
    baseline.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("CONTEXT7_API_KEY", "sk-real-secret-do-not-leak")
    # No `claude` (or anything else) on PATH — compile must not need it.
    emptybin = env.tmp / "emptybin"
    emptybin.mkdir()
    monkeypatch.setenv("PATH", str(emptybin))

    assert run(["compile", "live", "--baseline", str(baseline), "--out", str(out)]) == 0

    # Compile touched no live state.
    assert not (home / ".claude.json").exists()

    data = json.loads((out / "manifest.json").read_text())
    assert data["user_mcps"] == [
        {
            "name": "context7",
            "command": "npx",
            "args": ["-y", "@upstash/context7-mcp"],
            "env": {"CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"},
        }
    ]
    assert "sk-real-secret-do-not-leak" not in (out / "manifest.json").read_text()


def test_compile_profile_requires_compile_targets(env):
    """``compile_profile`` called directly (bypassing the CLI presence gate)
    still fails loud when the profile declares no compile_targets — the
    targets-presence guard is not lost with ``_load_compile_targets`` deleted."""
    from tests.conftest import write_profile

    write_profile(env.profiles, "notargets", "name: notargets\n")
    with pytest.raises(compile_command.CompileError):
        compile_command.compile_profile(
            "notargets", env.tmp / "b", env.tmp / "o", build_registry()
        )


def test_compile_uses_strict_target_validation(env, monkeypatch):
    """Finding 2 / spec-verify: compile consumes the strictly-validated
    ``manifest.compile_targets``. A cross-target duplicate harness — which the
    deleted weak ``_load_compile_targets`` parser accepted but strict
    validation rejects — fails the compile."""
    monkeypatch.setenv("HOME", str(env.tmp / "home"))
    write_minimal_includes(env.profiles)
    write_live_profile(
        env.profiles,
        compile_targets={
            "a": {"target_root": "$HOME", "harnesses": ["claude"]},
            "b": {"target_root": "$HOME/b", "harnesses": ["claude"]},
        },
    )
    with pytest.raises(Exception, match="duplicates harness 'claude'"):
        compile_command.compile_profile(
            "live", env.tmp / "b", env.tmp / "o", build_registry()
        )


def test_profile_arg_extracts_positional_regardless_of_flag_order():
    """``profile_arg`` mirrors ``_parse_args`` positional handling: the profile
    is found whether it leads or trails the flags, and flag values are skipped."""
    assert compile_command.profile_arg(["live", "--baseline", "b", "--out", "o"]) == "live"
    assert compile_command.profile_arg(["--baseline", "b", "--out", "o", "live"]) == "live"
    assert compile_command.profile_arg(["--baseline=b", "--out=o", "live"]) == "live"
    assert compile_command.profile_arg(["--baseline", "b", "--out", "o"]) == ""


def test_compile_accepts_flags_before_profile(env, monkeypatch, stub_renderers):
    """The CLI compile pre-check must extract the profile positionally, not
    assume it is the first arg. ``--baseline X --out Y live`` previously errored
    with a misleading ``profile '--baseline' not found``."""
    write_minimal_includes(env.profiles)
    write_live_profile(env.profiles)
    home = env.tmp / "home"
    baseline = env.tmp / "baseline"
    out = env.tmp / "compiled"
    home.mkdir()
    baseline.mkdir()
    monkeypatch.setenv("HOME", str(home))

    assert run(["compile", "--baseline", str(baseline), "--out", str(out), "live"]) == 0
