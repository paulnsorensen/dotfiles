"""Compile must bake the *deploy* root into codex hooks.json, not the
ephemeral render dir.

``ap compile`` renders each target into a throwaway tempdir and captures the
changed files as fragments. The codex renderer writes ``.codex/hooks.json``
with an ABSOLUTE ``bash <root>/.codex/hooks/<hook>.sh`` command (Codex runs
hook commands from the session cwd, so the path must be absolute). If that
absolute path is rooted at the compile tempdir, the emitted fragment (a) points
at a directory that is deleted the moment compile finishes, and (b) changes
every run, so hooks.json is reported as drift on every recompile — defeating
the baseline/live/compiled comparison ADR-003 depends on.

These tests drive the REAL renderers (not the conftest stub, which writes only
relative content and so cannot see this bug).
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_profile import compile_command
from agent_profile.renderers.registry import build_registry
from tests.conftest import write_profile

_PROFILE_YAML = (
    "name: live\n"
    "description: live deployment\n"
    "compile_targets:\n"
    "  home:\n"
    '    target_root: "$HOME"\n'
    "    harnesses: [codex]\n"
    "hooks:\n"
    "  - name: guard\n"
    "    event: PreToolUse\n"
    "    matcher: Bash\n"
    "    script: hooks/guard.sh\n"
    "    harnesses: [codex]\n"
)


def _make_profile(root: Path) -> None:
    write_profile(
        root,
        "live",
        _PROFILE_YAML,
        {"hooks/guard.sh": "#!/bin/sh\necho guard\n"},
    )


def _hook_commands(hooks_json: Path) -> list[str]:
    data = json.loads(hooks_json.read_text())
    return [
        handler["command"]
        for groups in data["hooks"].values()
        for group in groups
        for handler in group["hooks"]
    ]


def test_compiled_codex_hook_command_rooted_at_deploy_root(env, monkeypatch, tmp_path):
    """The baked hook command must reference the target's deploy root (resolved
    $HOME), never the ``ap-compile-*`` render tempdir."""
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    _make_profile(env.profiles)
    baseline = tmp_path / "baseline"
    baseline.mkdir()
    out = tmp_path / "out"

    compile_command.compile_profile("live", baseline, out, build_registry())

    hooks_json = out / "fragments/home/codex/.codex/hooks.json"
    commands = _hook_commands(hooks_json)
    assert commands, "expected at least one codex hook command"
    expected = f"bash {home}/.codex/hooks/guard.sh"
    for command in commands:
        assert "ap-compile" not in command, (
            f"render tempdir leaked into compiled hooks.json: {command!r}"
        )
        assert command == expected, (
            f"hook command not rooted at deploy root: {command!r} != {expected!r}"
        )


def test_recompile_reports_no_codex_drift(env, monkeypatch, tmp_path):
    """Feeding a compile's own render back as the baseline must yield zero codex
    fragments — compile is deterministic w.r.t. the deploy root, so nothing
    changed."""
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    _make_profile(env.profiles)
    baseline = tmp_path / "baseline"
    baseline.mkdir()
    renderers = build_registry()

    first = tmp_path / "first"
    compile_command.compile_profile("live", baseline, first, renderers)

    second = tmp_path / "second"
    recompiled = compile_command.compile_profile(
        "live", first / "fragments/home/codex", second, renderers
    )

    codex_drift = [
        f.relative_path for f in recompiled.files if f.harness == "codex"
    ]
    assert codex_drift == [], f"recompile reported codex drift: {codex_drift}"
