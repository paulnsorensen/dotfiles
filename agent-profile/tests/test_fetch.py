"""test_fetch.py — external skill fetch via `npx skills add` (spec curd 4).

`source:` skills shell out to `npx skills add <repo>[@<ref>] --skill <name|*>
[--skill <name>...] --agent <id> [--agent <id>...] -g --copy -y`, a single
shallow clone per repo that installs to every requested agent at once. `path:`
(local-tree) skills are unchanged — they are copied by the renderers, not
fetched here.

The runner is injected so tests assert the exact argv without spawning npx.
"""

from __future__ import annotations

import json
import subprocess
import types

import pytest

from agent_profile import fetch
from agent_profile.fetch import (
    SKILL_AGENT,
    SkillFetchError,
    _default_runner,
    external_skills,
    fetch_external_source,
    skill_agent_for,
)


# ─── harness -> skills-CLI agent mapping ──────────────────────────────


def test_skill_agent_maps_claude_to_claude_code():
    assert skill_agent_for("claude") == "claude-code"


def test_skill_agent_maps_copilot_to_github_copilot():
    assert skill_agent_for("copilot") == "github-copilot"


def test_skill_agent_passes_through_codex_cursor_opencode():
    assert skill_agent_for("codex") == "codex"
    assert skill_agent_for("cursor") == "cursor"
    assert skill_agent_for("opencode") == "opencode"


def test_skill_agent_table_covers_all_five():
    assert set(SKILL_AGENT) == {"claude", "codex", "cursor", "copilot", "opencode"}


def test_skill_agent_unknown_harness_raises():
    with pytest.raises(SkillFetchError, match="unknown harness"):
        skill_agent_for("frobnicator")


# ─── argv assembly ────────────────────────────────────────────────────


def test_fetch_named_skill_single_harness():
    calls = []

    def runner(argv):
        calls.append(argv)
        return 0

    fetch_external_source(
        "paulnsorensen/easy-cheese", ["mold"], None, ["claude"], runner
    )
    assert calls == [
        [
            "npx", "--yes", "skills", "add", "paulnsorensen/easy-cheese",
            "--skill", "mold", "--agent", "claude-code",
            "-g", "--copy", "-y",
        ]
    ]


def test_fetch_nameless_source_installs_all_skills():
    # A repo-level source (no explicit names) installs every skill via the
    # CLI's native `--skill '*'` auto-discovery — no GitHub-API listing.
    calls = []
    fetch_external_source("owner/repo", None, None, ["cursor"], lambda a: calls.append(a) or 0)
    assert "--skill" in calls[0]
    assert calls[0][calls[0].index("--skill") + 1] == "*"


def test_fetch_repeats_agent_flag_per_harness():
    # Multiple harnesses → one invocation, repeated --agent (the CLI rejects a
    # comma/space-joined value, silently no-op'ing at exit 0).
    calls = []
    fetch_external_source(
        "owner/repo", None, None, ["claude", "codex", "cursor"],
        lambda a: calls.append(a) or 0,
    )
    argv = calls[0]
    agents = [argv[i + 1] for i, t in enumerate(argv) if t == "--agent"]
    assert agents == ["claude-code", "codex", "cursor"]
    assert len(calls) == 1  # one clone, not one-per-harness


def test_fetch_repeats_skill_flag_for_explicit_names_sorted():
    calls = []
    fetch_external_source(
        "owner/repo", ["mold", "cook"], None, ["claude"],
        lambda a: calls.append(a) or 0,
    )
    argv = calls[0]
    skills = [argv[i + 1] for i, t in enumerate(argv) if t == "--skill"]
    assert skills == ["cook", "mold"]  # sorted, repeated flag


def test_fetch_pins_via_at_ref_in_repo_spec():
    calls = []
    fetch_external_source(
        "owner/repo", ["cook"], "v1.2.3", ["codex"], lambda a: calls.append(a) or 0
    )
    # The CLI pins via `<repo>@<ref>` (mapped to git clone --branch), not a flag.
    argv = calls[0]
    assert argv[argv.index("add") + 1] == "owner/repo@v1.2.3"


def test_fetch_no_harnesses_is_noop():
    calls = []
    fetch_external_source("owner/repo", None, None, [], lambda a: calls.append(a) or 0)
    assert calls == []


def test_fetch_unknown_harness_fails_before_running():
    # An unknown harness must raise during agent resolution, before npx is
    # invoked — a bad --agent value silently installs nothing at exit 0.
    calls = []
    with pytest.raises(SkillFetchError, match="unknown harness"):
        fetch_external_source("owner/repo", None, None, ["bogus"], lambda a: calls.append(a) or 0)
    assert calls == []


def test_fetch_nonzero_exit_raises():
    with pytest.raises(SkillFetchError, match="npx skills add failed"):
        fetch_external_source("owner/repo", ["x"], None, ["claude"], lambda a: 3)


# ─── external_skills selection ────────────────────────────────────────


def test_external_skills_filters_source_items_only():
    items = [
        {"name": "mold", "source": "o/r"},
        {"name": "de-slop", "path": "skills/de-slop"},  # local — excluded
        {"source": "o/r2"},  # repo-level — included
    ]
    out = external_skills(items)
    assert {tuple(sorted(s.items())) for s in out} == {
        tuple(sorted({"name": "mold", "source": "o/r"}.items())),
        tuple(sorted({"source": "o/r2"}.items())),
    }


# ─── group_external_sources (shared install/launch grouping rule) ─────


def test_group_external_sources_bare_source_means_all():
    groups = fetch.group_external_sources([
        {"name": "mold", "source": "o/r"},
        {"source": "o/r"},  # bare → all, wins over the explicit name
    ])
    assert groups == [("o/r", None, None)]


def test_group_external_sources_explicit_names_sorted_and_pin():
    groups = fetch.group_external_sources([
        {"name": "cook", "source": "o/r", "pin": "v2"},
        {"name": "age", "source": "o/r"},
        {"name": "x", "path": "skills/x"},  # local — ignored
    ])
    assert groups == [("o/r", ["age", "cook"], "v2")]


def test_group_external_sources_preserves_first_seen_order():
    groups = fetch.group_external_sources([
        {"source": "b/2"},
        {"source": "a/1"},
    ])
    assert [g[0] for g in groups] == ["b/2", "a/1"]


# ─── source_skill_names (lockfile provenance, zero-network) ────────────


def _write_lock(store, mapping):
    (store / "skills").mkdir(parents=True, exist_ok=True)
    skills = {n: {"source": src} for n, src in mapping.items()}
    (store / ".skill-lock.json").write_text(json.dumps({"skills": skills}))


def test_source_skill_names_all_for_a_source(tmp_path):
    _write_lock(tmp_path, {"mold": "o/cheese", "cook": "o/cheese", "search": "x/tav"})
    assert fetch.source_skill_names("o/cheese", None, store=tmp_path) == ["cook", "mold"]


def test_source_skill_names_restricts_to_explicit_subset(tmp_path):
    _write_lock(tmp_path, {"mold": "o/cheese", "cook": "o/cheese"})
    assert fetch.source_skill_names("o/cheese", ["mold"], store=tmp_path) == ["mold"]


def test_source_skill_names_missing_lock_degrades_to_empty(tmp_path):
    assert fetch.source_skill_names("o/cheese", None, store=tmp_path) == []


def test_source_skill_names_unknown_source_is_empty(tmp_path):
    _write_lock(tmp_path, {"mold": "o/cheese"})
    assert fetch.source_skill_names("x/none", None, store=tmp_path) == []


# ─── _default_runner output scanning (exit-0 false-success detection) ─


def _make_completed(returncode: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:  # type: ignore[type-arg]
    """Build a mock CompletedProcess without running anything."""
    cp: subprocess.CompletedProcess = types.SimpleNamespace(  # type: ignore[assignment]
        returncode=returncode, stdout=stdout, stderr=stderr
    )
    return cp  # type: ignore[return-value]


def test_default_runner_returns_zero_on_clean_output(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **kw: _make_completed(0, stdout="✓ Installed mold\n✓ done\n"),
    )
    assert _default_runner(["npx", "skills", "add", "o/r"]) == 0


def test_default_runner_propagates_nonzero_exit(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **kw: _make_completed(2, stdout="", stderr="fatal error\n"),
    )
    assert _default_runner(["npx", "skills", "add", "o/r"]) == 2


def test_default_runner_returns_one_when_output_contains_error_at_exit_zero(monkeypatch):
    # The skills CLI exits 0 even on per-skill EPERM failures; the output scan
    # catches this and returns non-zero so the caller's error guard fires.
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **kw: _make_completed(
            0, stdout="", stderr="Error: EPERM writing to ~/.claude/skills\n"
        ),
    )
    assert _default_runner(["npx", "skills", "add", "o/r"]) == 1


def test_default_runner_returns_one_when_output_contains_failed_at_exit_zero(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **kw: _make_completed(
            0, stdout="Skill 'mold' failed to install\n", stderr=""
        ),
    )
    assert _default_runner(["npx", "skills", "add", "o/r"]) == 1


def test_default_runner_clean_output_with_no_failure_words(monkeypatch):
    # "succeeded", "done", progress dots — none of these should trip the scan.
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **kw: _make_completed(
            0, stdout="Cloning... done\nInstalling mold... ✓\n", stderr=""
        ),
    )
    assert _default_runner(["npx", "skills", "add", "o/r"]) == 0
