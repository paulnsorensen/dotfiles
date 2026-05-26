"""test_fetch.py — external skill fetch via `gh skill install` (spec curd 4).

`source:` skills shell out to `gh skill install <repo> [<name>] --agent
<gh-agent> --scope user --force [--pin <ref>]`, mirroring the existing
chezmoi install-external.sh invocation. `path:` (local-tree) skills are
unchanged — they are copied by the renderers, not fetched here.

The runner is injected so tests assert the exact argv without spawning gh.
"""

from __future__ import annotations

import pytest

from agent_profile.fetch import (
    GH_AGENT,
    SkillFetchError,
    external_skills,
    fetch_external_skill,
    gh_agent_for,
)


# ─── harness -> gh agent mapping ──────────────────────────────────────


def test_gh_agent_maps_claude_to_claude_code():
    assert gh_agent_for("claude") == "claude-code"


def test_gh_agent_maps_copilot_to_github_copilot():
    assert gh_agent_for("copilot") == "github-copilot"


def test_gh_agent_passes_through_codex_cursor_opencode():
    assert gh_agent_for("codex") == "codex"
    assert gh_agent_for("cursor") == "cursor"
    assert gh_agent_for("opencode") == "opencode"


def test_gh_agent_table_covers_all_five():
    assert set(GH_AGENT) == {"claude", "codex", "cursor", "copilot", "opencode"}


def test_gh_agent_unknown_harness_raises():
    with pytest.raises(SkillFetchError, match="unknown harness"):
        gh_agent_for("frobnicator")


# ─── argv assembly ────────────────────────────────────────────────────


def test_fetch_assembles_expected_argv():
    calls = []

    def runner(argv):
        calls.append(argv)
        return 0

    fetch_external_skill("paulnsorensen/easy-cheese", "mold", None, "claude", runner)
    assert calls == [
        [
            "gh", "skill", "install", "paulnsorensen/easy-cheese", "mold",
            "--agent", "claude-code", "--scope", "user", "--force",
        ]
    ]


def test_fetch_appends_pin_when_present():
    calls = []
    fetch_external_skill(
        "owner/repo", "cook", "v1.2.3", "codex", lambda a: calls.append(a) or 0
    )
    assert "--pin" in calls[0]
    assert calls[0][calls[0].index("--pin") + 1] == "v1.2.3"


def test_fetch_omits_skill_name_for_repo_level_install():
    calls = []
    # No explicit skill name -> install the whole repo (auto-discovery).
    fetch_external_skill("owner/repo", None, None, "cursor", lambda a: calls.append(a) or 0)
    argv = calls[0]
    # gh skill install <repo> --agent ... (no positional skill name)
    assert argv[:4] == ["gh", "skill", "install", "owner/repo"]
    assert argv[4] == "--agent"


def test_fetch_nonzero_exit_raises():
    with pytest.raises(SkillFetchError, match="gh skill install failed"):
        fetch_external_skill("owner/repo", "x", None, "claude", lambda a: 3)


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
