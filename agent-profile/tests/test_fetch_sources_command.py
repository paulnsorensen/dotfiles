"""test_fetch_sources_command.py — ``ap fetch-sources <profile>`` fetches external
``source:`` skills WITHOUT compiling or applying anything.

Spec acceptance: WHEN external ``source:`` skills are present in the profile
THE SYSTEM SHALL fetch them via ``ap fetch-sources <profile>`` before compile;
the command returns non-zero / raises on fetch failure and performs NO compile
or apply. ``npx`` is stubbed via the module-level ``_fetch_runner`` so no test
touches the network.
"""

from __future__ import annotations

import sys

import pytest

from agent_profile import fetch_sources_command as fsc
from agent_profile.fetch_sources_command import (
    FetchSourcesError,
    cmd_fetch_sources,
    fetch_sources,
)
from tests.compile_fixtures import write_live_profile, write_minimal_includes
from tests.conftest import write_profile


def _stub_runner(monkeypatch, rc: int = 0):
    """Replace the npx runner with a recorder; return the captured-call list."""
    calls: list[list[str]] = []
    monkeypatch.setattr(
        fsc, "_fetch_runner", lambda argv: calls.append(argv) or rc
    )
    return calls


# ─── fetches source: skills (acceptance happy path) ──────────────────────────


def test_fetch_sources_fetches_source_skill(env, monkeypatch):
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\n"
        "skills:\n"
        "  - name: mold\n    source: paulnsorensen/easy-cheese\n    pin: v1\n",
    )
    calls = _stub_runner(monkeypatch)

    assert fetch_sources("extprof") == 0

    fetches = [c for c in calls if "npx" in c and "skills" in c and "add" in c]
    assert len(fetches) == 1
    argv = fetches[0]
    assert argv[argv.index("add") + 1] == "paulnsorensen/easy-cheese@v1"
    assert "mold" in argv


def test_fetch_sources_targets_all_skill_supporting_harnesses(env, monkeypatch):
    """A bare ``ap fetch-sources <profile>`` installs into every skill-supporting
    harness (the canonical skill_agents.txt map) in one invocation."""
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\nskills:\n  - name: cook\n    source: o/r\n",
    )
    calls = _stub_runner(monkeypatch)

    assert fetch_sources("extprof") == 0
    assert len(calls) == 1
    argv = calls[0]
    agents = sorted(argv[i + 1] for i, t in enumerate(argv) if t == "--agent")
    assert agents == sorted(
        ["claude-code", "codex", "cursor", "github-copilot", "opencode"]
    )


def test_fetch_sources_repo_level_source_uses_skill_star(env, monkeypatch):
    """A bare ``source:`` (no name) installs every skill via ``--skill '*'``."""
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\nskills:\n  - source: paulnsorensen/easy-cheese\n",
    )
    calls = _stub_runner(monkeypatch)

    assert fetch_sources("extprof") == 0
    assert len(calls) == 1
    argv = calls[0]
    assert argv[argv.index("add") + 1] == "paulnsorensen/easy-cheese"
    assert argv[argv.index("--skill") + 1] == "*"


def test_fetch_sources_live_profile_fetches_before_compile(env, monkeypatch):
    """The acceptance shape: the live profile (with compile_targets) carrying a
    ``source:`` skill fetches it — and writes no compile manifest."""
    write_minimal_includes(env.profiles)
    write_live_profile(
        env.profiles,
        skills=[{"name": "mold", "source": "paulnsorensen/easy-cheese"}],
    )
    calls = _stub_runner(monkeypatch)

    assert fetch_sources("live") == 0
    assert len(calls) == 1
    assert "paulnsorensen/easy-cheese" in calls[0]
    # No compile/apply: nothing rendered into the cwd target tree.
    assert not (env.target / "manifest.json").exists()
    assert not any(env.target.rglob("manifest.json"))
    assert not (env.target / "fragments").exists()


# ─── no source: skills = no-op success ───────────────────────────────────────


def test_fetch_sources_no_source_skills_is_noop_success(env, monkeypatch):
    write_profile(env.profiles, "noext", "name: noext\n")
    calls = _stub_runner(monkeypatch)

    assert fetch_sources("noext") == 0
    assert calls == []


def test_fetch_sources_only_path_skills_is_noop_success(env, monkeypatch):
    """``path:`` skills are copied by renderers, not fetched — so a profile with
    only local skills triggers no fetch and exits zero."""
    write_profile(
        env.profiles,
        "localonly",
        "name: localonly\nskills:\n  - name: local-skill\n    path: skills/local-skill\n",
        {"skills/local-skill/SKILL.md": "# local\n"},
    )
    calls = _stub_runner(monkeypatch)

    assert fetch_sources("localonly") == 0
    assert calls == []


# ─── fetch failure -> raises, no compile/apply ───────────────────────────────


def test_fetch_sources_fetch_failure_raises(env, monkeypatch):
    """A non-zero npx exit surfaces as FetchSourcesError (the CLI maps it to a
    clean stderr line + exit 1), and no compile artifact is produced."""
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\nskills:\n  - name: mold\n    source: o/r\n",
    )
    _stub_runner(monkeypatch, rc=1)

    with pytest.raises(FetchSourcesError) as exc:
        fetch_sources("extprof")
    assert "npx skills add failed" in str(exc.value)
    assert not any(env.target.rglob("manifest.json"))


def test_fetch_sources_missing_npx_raises_clean(env, monkeypatch):
    """npx absent -> the runner raises FileNotFoundError (an OSError); the
    command reports it as a clean FetchSourcesError, not a traceback."""

    def boom(argv):
        raise FileNotFoundError(2, "No such file or directory", "npx")

    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\nskills:\n  - name: mold\n    source: o/r\n",
    )
    monkeypatch.setattr(fsc, "_fetch_runner", boom)

    with pytest.raises(FetchSourcesError) as exc:
        fetch_sources("extprof")
    assert "Node/npx" in str(exc.value)


def test_fetch_sources_unknown_profile_raises(env, monkeypatch):
    _stub_runner(monkeypatch)
    with pytest.raises(FetchSourcesError) as exc:
        fetch_sources("does-not-exist")
    assert "not found" in str(exc.value)


# ─── cmd_fetch_sources arg handling ──────────────────────────────────────────


def test_cmd_fetch_sources_parses_profile_and_returns_zero(env, monkeypatch):
    write_profile(
        env.profiles,
        "extprof",
        "name: extprof\nskills:\n  - name: mold\n    source: o/r\n",
    )
    calls = _stub_runner(monkeypatch)

    assert cmd_fetch_sources(["extprof"], sys.stdout) == 0
    assert len(calls) == 1


def test_cmd_fetch_sources_missing_profile_raises(env):
    with pytest.raises(FetchSourcesError) as exc:
        cmd_fetch_sources([], sys.stdout)
    assert "Usage:" in str(exc.value)


def test_cmd_fetch_sources_extra_argument_raises(env, monkeypatch):
    write_profile(env.profiles, "extprof", "name: extprof\n")
    _stub_runner(monkeypatch)

    with pytest.raises(FetchSourcesError) as exc:
        cmd_fetch_sources(["extprof", "bogus"], sys.stdout)
    assert "unexpected argument" in str(exc.value)


def test_cmd_fetch_sources_flag_as_profile_raises(env):
    with pytest.raises(FetchSourcesError) as exc:
        cmd_fetch_sources(["--harness"], sys.stdout)
    assert "Usage:" in str(exc.value)
