from __future__ import annotations

from agent_profile import cli

from .compile_fixtures import write_live_profile, write_minimal_includes


def test_compile_rejects_enabled_plugins_without_claude_target(env, capsys, monkeypatch):
    monkeypatch.setenv("HOME", str(env.tmp / "home"))
    write_minimal_includes(env.profiles)
    write_live_profile(
        env.profiles,
        compile_targets={
            "home": {"target_root": "$HOME", "harnesses": ["codex"]},
        },
    )

    assert cli.main(["compile", "live"]) == 1

    err = capsys.readouterr().err
    assert "enabled_plugins" in err
    assert "requires compile target harness 'claude'" in err
