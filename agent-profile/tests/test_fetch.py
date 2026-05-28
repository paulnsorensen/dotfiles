"""test_fetch.py — external skill fetch via `npx skills add` (spec curd 4).

`source:` skills shell out to `npx skills add <repo>[@<ref>] --skill <name|*>
[--skill <name>...] --agent <id> [--agent <id>...] -g --copy -y`, a single
shallow clone per repo that installs to every requested agent at once. `path:`
(local-tree) skills are unchanged — they are copied by the renderers, not
fetched here.

The runner is injected so tests assert the exact argv without spawning npx.
"""

from __future__ import annotations

import pytest

from agent_profile.fetch import (
    SKILL_AGENT,
    SkillFetchError,
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
