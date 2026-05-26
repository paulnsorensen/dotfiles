"""test_ingest.py — registries: directive expansion (spec curd 1 + 2).

The `base` profile declares a `registries:` directive instead of inline
item lists. `expand_registries` reads the three separate registries (the
MCP mapping, the hook mapping, the skills _registry.yaml + local skills/
tree) and the env mapping, and returns normalized {mcps, skills, hooks}
item lists — each item carrying `_source_dir` so payload files resolve.

This is the ONLY place the registries are read; the registry files stay the
per-type edit surface.
"""

from __future__ import annotations

import pytest

from agent_profile.env import EnvResolutionError
from agent_profile.ingest import expand_registries


# ─── fixtures: a miniature dotfiles-shaped repo ───────────────────────


@pytest.fixture
def repo(tmp_path):
    """A miniature repo root holding the three registries + a skills tree."""
    (tmp_path / "agents" / "mcp").mkdir(parents=True)
    (tmp_path / "agents" / "hooks").mkdir(parents=True)
    (tmp_path / "agents" / "lib").mkdir(parents=True)
    (tmp_path / "skills").mkdir()

    (tmp_path / "agents" / "mcp" / "registry.yaml").write_text(
        "mcps:\n"
        "  tilth:\n"
        "    command: tilth\n"
        "    args: ['--mcp']\n"
        "    scope: user\n"
        "    gate_unless: CHEESE_FLOW\n"
        "    description: code search\n"
        "  todoist:\n"
        "    command: npx\n"
        "    args: ['-y', '@doist/todoist-ai']\n"
        "    env:\n"
        "      TODOIST_API_KEY: '${TODOIST_API_KEY}'\n"
        "    optional: true\n"
        "    description: todoist\n"
    )
    (tmp_path / "agents" / "hooks" / "registry.yaml").write_text(
        "hooks:\n"
        "  session-start-cheese-flair:\n"
        "    event: SessionStart\n"
        "    script: agents/hooks/session-start-cheese-flair.sh\n"
        "    shared_assets:\n"
        "      - agents/lib/cheese-flair.sh\n"
        "    harnesses: [claude, codex]\n"
        "    matcher: 'startup|resume'\n"
        "    timeout: 5\n"
        "    description: flair\n"
    )
    (tmp_path / "agents" / "hooks" / "session-start-cheese-flair.sh").write_text(
        "#!/bin/bash\necho flair\n"
    )
    (tmp_path / "agents" / "lib" / "cheese-flair.sh").write_text("# lib\n")

    (tmp_path / "skills" / "_registry.yaml").write_text(
        "sources:\n"
        "  paulnsorensen/easy-cheese:\n"
        "    description: cheese skills\n"
        "    pin: v1.2.3\n"
        "    skills: [mold, cook]\n"
        "  tavily-ai/skills:\n"
        "    description: tavily\n"
    )
    for skill in ("de-slop", "self-eval"):
        d = tmp_path / "skills" / skill
        d.mkdir()
        (d / "SKILL.md").write_text(f"# {skill}\n")

    directive = {
        "mcps": "agents/mcp/registry.yaml",
        "skills": ["skills/_registry.yaml", "skills/"],
        "hooks": "agents/hooks/registry.yaml",
    }
    return tmp_path, directive


def _dotenv():
    return {"TODOIST_API_KEY": "secret", "CHEESE_FLOW": "false"}


# ─── MCP ingestion (+ parity fields, curd 2) ──────────────────────────


def test_expand_mcps_become_named_list(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    names = [m["name"] for m in out["mcps"]]
    assert names == ["tilth", "todoist"]


def test_expand_mcps_carry_parity_fields(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    tilth = next(m for m in out["mcps"] if m["name"] == "tilth")
    assert tilth["command"] == "tilth"
    assert tilth["args"] == ["--mcp"]
    assert tilth["scope"] == "user"
    assert tilth["gate_unless"] == "CHEESE_FLOW"


def test_expand_mcps_source_dir_is_repo_root(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    assert out["mcps"][0]["_source_dir"] == str(root)


def test_expand_mcps_env_resolved_at_ingest(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    todoist = next(m for m in out["mcps"] if m["name"] == "todoist")
    assert todoist["env"]["TODOIST_API_KEY"] == "secret"


def test_expand_optional_mcp_skipped_when_var_unset(repo):
    root, directive = repo
    out = expand_registries(directive, root, {"CHEESE_FLOW": "false"})
    names = [m["name"] for m in out["mcps"]]
    assert "todoist" not in names  # optional + TODOIST_API_KEY unset -> skipped
    assert "tilth" in names


def test_expand_required_mcp_unset_var_fails_loud(repo):
    root, directive = repo
    # Make tilth (non-optional) reference an unset var.
    (root / "agents" / "mcp" / "registry.yaml").write_text(
        "mcps:\n"
        "  needvar:\n"
        "    command: x\n"
        "    env:\n      K: '${MUST_BE_SET}'\n"
    )
    with pytest.raises(EnvResolutionError) as exc:
        expand_registries(directive, root, {})
    assert "MUST_BE_SET" in str(exc.value)


# ─── hook ingestion ───────────────────────────────────────────────────


def test_expand_hooks_become_named_list(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    assert len(out["hooks"]) == 1
    hook = out["hooks"][0]
    assert hook["name"] == "session-start-cheese-flair"
    assert hook["event"] == "SessionStart"
    assert hook["script"] == "agents/hooks/session-start-cheese-flair.sh"
    assert hook["shared_assets"] == ["agents/lib/cheese-flair.sh"]
    assert hook["matcher"] == "startup|resume"
    assert hook["timeout"] == 5
    assert hook["harnesses"] == ["claude", "codex"]
    assert hook["_source_dir"] == str(root)


# ─── skill ingestion (external + local tree) ──────────────────────────


def test_expand_skills_includes_external_sources(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    ext = [s for s in out["skills"] if s.get("source")]
    by_source = {s["source"] for s in ext}
    assert "paulnsorensen/easy-cheese" in by_source
    assert "tavily-ai/skills" in by_source


def test_expand_external_skill_carries_pin_and_explicit_names(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    easy = [s for s in out["skills"] if s.get("source") == "paulnsorensen/easy-cheese"]
    # Explicit skills list -> one item per named skill, all carrying the pin.
    names = sorted(s["name"] for s in easy)
    assert names == ["cook", "mold"]
    assert all(s["pin"] == "v1.2.3" for s in easy)


def test_expand_skills_includes_local_tree(repo):
    root, directive = repo
    out = expand_registries(directive, root, _dotenv())
    local = {s["name"]: s for s in out["skills"] if s.get("path")}
    assert set(local) == {"de-slop", "self-eval"}
    assert local["de-slop"]["path"] == "skills/de-slop"
    assert local["de-slop"]["_source_dir"] == str(root)


def test_expand_local_skill_only_when_skill_md_present(repo):
    root, directive = repo
    # A dir without SKILL.md is not a skill.
    (root / "skills" / "not-a-skill").mkdir()
    out = expand_registries(directive, root, _dotenv())
    local = {s["name"] for s in out["skills"] if s.get("path")}
    assert "not-a-skill" not in local


def test_expand_local_skills_are_sorted_by_name(repo):
    root, directive = repo
    # Add a skill that sorts before the existing two; the local tree is
    # emitted in sorted name order (docstring contract), regardless of the
    # OS-dependent iterdir order. A set() comparison would not catch a
    # regression here.
    for skill in ("alpha", "zeta"):
        d = root / "skills" / skill
        d.mkdir()
        (d / "SKILL.md").write_text(f"# {skill}\n")
    out = expand_registries(directive, root, _dotenv())
    local_names = [s["name"] for s in out["skills"] if s.get("path")]
    assert local_names == sorted(local_names)
    assert local_names == ["alpha", "de-slop", "self-eval", "zeta"]


def test_expand_skills_dispatch_accepts_yml_suffix(repo):
    root, directive = repo
    # The external-registry dispatch keys on .yaml OR .yml; a .yml registry
    # must be read as external sources, not walked as a local tree.
    (root / "alt_registry.yml").write_text(
        "sources:\n  owner/alt:\n    skills: [solo]\n"
    )
    directive = {"skills": ["alt_registry.yml"]}
    out = expand_registries(directive, root, _dotenv())
    ext = [s for s in out["skills"] if s.get("source")]
    assert any(s["source"] == "owner/alt" and s["name"] == "solo" for s in ext)


def test_expand_repo_level_external_skill_has_no_name(repo):
    root, directive = repo
    # tavily-ai/skills declares no explicit `skills:` list -> a single
    # repo-level item with a source but NO name (gh auto-discovers at fetch).
    out = expand_registries(directive, root, _dotenv())
    repo_level = [
        s for s in out["skills"] if s.get("source") == "tavily-ai/skills"
    ]
    assert len(repo_level) == 1
    assert "name" not in repo_level[0]


def test_expand_registries_absent_sections_yield_empty_lists(repo):
    root, _ = repo
    # An empty directive returns the three keys, each an empty list — not a
    # KeyError downstream, not a missing section.
    out = expand_registries({}, root, _dotenv())
    assert out == {"mcps": [], "skills": [], "hooks": []}


def test_expand_mcps_skip_non_mapping_entries(repo):
    root, directive = repo
    # A malformed registry entry whose body is not a mapping is skipped, not
    # crashed on (input validation — trust nothing from the registry file).
    (root / "agents" / "mcp" / "registry.yaml").write_text(
        "mcps:\n"
        "  good:\n    command: x\n"
        "  bogus: just-a-string\n"
    )
    out = expand_registries(directive, root, _dotenv())
    names = [m["name"] for m in out["mcps"]]
    assert names == ["good"]


def test_expand_external_skills_skip_non_mapping_source(repo):
    root, directive = repo
    # A malformed `sources:` body that is not a mapping (registry typo) is
    # skipped, not crashed on — parity with the MCP/hook non-mapping skip. A
    # bare `owner/repo:` (None body) stays a valid repo-level auto-discovery.
    (root / "skills" / "_registry.yaml").write_text(
        "sources:\n"
        "  good/repo:\n    skills: [mold]\n"
        "  bare/repo:\n"
        "  bogus/repo: just-a-string\n"
    )
    out = expand_registries(directive, root, _dotenv())
    sources = sorted({s["source"] for s in out["skills"] if "source" in s})
    assert sources == ["bare/repo", "good/repo"]
