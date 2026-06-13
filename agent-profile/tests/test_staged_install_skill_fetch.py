"""test_staged_install_skill_fetch.py — staged installs must not invoke global skill fetch.

A staged install (explicit --target <dir>) renders artifacts into the tmp target
but must never run `npx skills add -g` which installs globally into ~/.claude/skills etc.
A live install (no --target, target resolved from profile default or cwd) keeps the
existing fetch behavior.
"""

from __future__ import annotations

from agent_profile import cli
from tests.conftest import write_profile


# ─── staged install skips the global skill fetch ──────────────────────────────


def test_staged_install_does_not_invoke_skill_fetch(
    env, stub_renderers, monkeypatch, capsys
):
    """Explicit --target makes the install staged; fetch must be suppressed."""
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\n"
        "skills:\n"
        "  - name: mold\n    source: paulnsorensen/easy-cheese\n",
    )
    calls = []
    monkeypatch.setattr(cli, "_skill_fetch_runner", lambda argv: calls.append(argv) or 0)

    assert cli.main(["install", "extprof", "--harness", "claude", "--target", str(env.target)]) == 0
    # No npx skills add should have been invoked
    assert calls == []


def test_staged_install_prints_skip_message(env, stub_renderers, monkeypatch, capsys):
    """Staged install prints a one-line message explaining why fetch is skipped."""
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\n"
        "skills:\n"
        "  - name: mold\n    source: paulnsorensen/easy-cheese\n",
    )
    monkeypatch.setattr(cli, "_skill_fetch_runner", lambda argv: 0)

    assert cli.main(["install", "extprof", "--harness", "claude", "--target", str(env.target)]) == 0
    out = capsys.readouterr().out
    # A message about skipping external skills for staged/non-live target
    assert "external skills skipped" in out


# ─── live install still runs the global skill fetch ───────────────────────────


def test_live_install_invokes_skill_fetch(env, stub_renderers, monkeypatch):
    """No explicit --target means a live install; fetch must still run."""
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\n"
        "target_default: " + str(env.target) + "\n"
        "skills:\n"
        "  - name: mold\n    source: paulnsorensen/easy-cheese\n",
    )
    calls = []
    monkeypatch.setattr(cli, "_skill_fetch_runner", lambda argv: calls.append(argv) or 0)

    # No --target flag: target comes from profile's target_default
    assert cli.main(["install", "extprof", "--harness", "claude"]) == 0
    fetches = [c for c in calls if "npx" in c and "add" in c]
    assert len(fetches) == 1


def test_staged_no_source_skills_still_exits_zero(env, stub_renderers, monkeypatch):
    """Staged install with no source: skills exits zero and emits no fetch call."""
    write_profile(env.profiles, "noext", "name: noext\n")
    calls = []
    monkeypatch.setattr(cli, "_skill_fetch_runner", lambda argv: calls.append(argv) or 0)
    assert cli.main(["install", "noext", "--harness", "claude", "--target", str(env.target)]) == 0
    assert calls == []
