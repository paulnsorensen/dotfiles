from __future__ import annotations

import json

from agent_profile import cli
from tests.compile_fixtures import (
    write_live_profile,
    write_minimal_includes,
    write_text,
)


def run(argv: list[str]) -> int:
    return cli.main(argv)


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
