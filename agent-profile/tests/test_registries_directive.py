"""test_registries_directive.py — parse.py honors the `registries:` directive.

A profile.yaml may declare `registries:` instead of (or alongside) inline
mcps/skills/hooks. parse_one expands the directive via ingest.expand_registries
(reading DOTFILES_DIR-relative registry files + DOTFILES_DIR/.env) and folds
the results into the item lists. This is the seam that lets `base` be the
union of the three separate registries.
"""

from __future__ import annotations

import pytest

from agent_profile.parse import ParseError, parse_manifest, parse_one
from tests.conftest import write_profile


@pytest.fixture
def dotfiles(tmp_path, monkeypatch):
    """A DOTFILES_DIR holding the three registries + .env + a skills tree."""
    root = tmp_path / "dots"
    (root / "agents" / "mcp").mkdir(parents=True)
    (root / "agents" / "hooks").mkdir(parents=True)
    (root / "skills" / "de-slop").mkdir(parents=True)
    (root / "profiles").mkdir()

    (root / "agents" / "mcp" / "registry.yaml").write_text(
        "mcps:\n"
        "  tilth:\n    command: tilth\n    args: ['--mcp']\n    scope: user\n"
        "  todoist:\n    command: npx\n    env:\n"
        "      TODOIST_API_KEY: '${TODOIST_API_KEY}'\n    optional: true\n"
    )
    (root / "agents" / "hooks" / "registry.yaml").write_text(
        "hooks:\n"
        "  flair:\n    event: SessionStart\n"
        "    script: agents/hooks/flair.sh\n    harnesses: [claude, codex]\n"
    )
    (root / "agents" / "hooks" / "flair.sh").write_text("#!/bin/bash\n")
    (root / "agents" / "registry.yaml").write_text(
        "agents:\n"
        "  ghostbuster:\n    description: dead code\n"
        "    models:\n      claude: sonnet\n"
        "    disallowedTools: [Edit, Write]\n"
        "    body_path: claude/agents/ghostbuster.md\n"
    )
    (root / "skills" / "de-slop" / "SKILL.md").write_text("# de-slop\n")
    (root / ".env").write_text("TODOIST_API_KEY=secret\n")

    monkeypatch.setenv("DOTFILES_DIR", str(root))
    return root


def test_parse_one_expands_registries_directive(dotfiles):
    write_profile(
        dotfiles / "profiles",
        "base",
        "name: base\n"
        "registries:\n"
        "  mcps: agents/mcp/registry.yaml\n"
        "  skills: [skills/]\n"
        "  hooks: agents/hooks/registry.yaml\n",
    )
    out = parse_one(dotfiles / "profiles" / "base")
    mcp_names = [m["name"] for m in out["mcps"]]
    assert "tilth" in mcp_names
    assert "todoist" in mcp_names  # TODOIST_API_KEY set in .env
    assert [h["name"] for h in out["hooks"]] == ["flair"]
    assert [s["name"] for s in out["skills"]] == ["de-slop"]


def test_parse_one_expands_agents_registry(dotfiles):
    write_profile(
        dotfiles / "profiles",
        "base",
        "name: base\nregistries:\n  agents: agents/registry.yaml\n",
    )
    out = parse_one(dotfiles / "profiles" / "base")
    assert [a["name"] for a in out["agents"]] == ["ghostbuster"]
    gb = out["agents"][0]
    assert gb["models"] == {"claude": "sonnet"}
    assert gb["disallowedTools"] == ["Edit", "Write"]
    # body_path (claude/agents/...) resolves against DOTFILES_DIR, so the
    # registry item carries the repo root as its _source_dir.
    assert gb["_source_dir"] == str(dotfiles)


def test_registries_agents_union_with_inline_agents(dotfiles):
    # Registry agents come first; an inline agents: block appends.
    write_profile(
        dotfiles / "profiles",
        "mixed",
        "name: mixed\n"
        "registries:\n  agents: agents/registry.yaml\n"
        "agents:\n  - name: extra\n    description: inline\n",
    )
    out = parse_one(dotfiles / "profiles" / "mixed")
    names = [a["name"] for a in out["agents"]]
    assert names == ["ghostbuster", "extra"]


def test_registries_mcp_env_stays_literal_not_resolved(dotfiles):
    # MCP-secret-passthrough: even with TODOIST_API_KEY=secret in DOTFILES_DIR/.env,
    # the ingest validates-but-does-not-substitute — the env value rides through
    # as the literal ${VAR} so renderers emit a runtime placeholder, not the
    # secret. The presence check still keeps the (optional) entry because the
    # var IS set.
    write_profile(
        dotfiles / "profiles",
        "base",
        "name: base\nregistries:\n  mcps: agents/mcp/registry.yaml\n",
    )
    out = parse_one(dotfiles / "profiles" / "base")
    todoist = next(m for m in out["mcps"] if m["name"] == "todoist")
    assert todoist["env"]["TODOIST_API_KEY"] == "${TODOIST_API_KEY}"
    assert "secret" not in str(todoist["env"])


def test_registries_source_dir_points_at_dotfiles(dotfiles):
    write_profile(
        dotfiles / "profiles",
        "base",
        "name: base\nregistries:\n  hooks: agents/hooks/registry.yaml\n",
    )
    out = parse_one(dotfiles / "profiles" / "base")
    # The hook's payload (script) lives under DOTFILES_DIR, so _source_dir
    # must point there — not at the profile dir.
    assert out["hooks"][0]["_source_dir"] == str(dotfiles)


def test_registries_optional_mcp_skipped_when_var_unset(dotfiles, monkeypatch):
    (dotfiles / ".env").write_text("")  # TODOIST_API_KEY now unset
    write_profile(
        dotfiles / "profiles",
        "base",
        "name: base\nregistries:\n  mcps: agents/mcp/registry.yaml\n",
    )
    out = parse_one(dotfiles / "profiles" / "base")
    mcp_names = [m["name"] for m in out["mcps"]]
    assert "todoist" not in mcp_names
    assert "tilth" in mcp_names


def test_registries_union_with_inline_items(dotfiles):
    # A profile may carry both a directive and inline items; inline appends.
    write_profile(
        dotfiles / "profiles",
        "mixed",
        "name: mixed\n"
        "registries:\n  mcps: agents/mcp/registry.yaml\n"
        "mcps:\n  - name: extra\n    command: x\n",
    )
    out = parse_one(dotfiles / "profiles" / "mixed")
    names = [m["name"] for m in out["mcps"]]
    assert "tilth" in names
    assert "extra" in names


def test_registries_items_precede_inline_items(dotfiles):
    # The cook contract (parse.py comment): registry-derived items come FIRST,
    # inline items append. Downstream merge treats "outer last" as the winner,
    # so the inline override must trail the registry entry. A membership check
    # would pass even if the order flipped; lock the position explicitly.
    write_profile(
        dotfiles / "profiles",
        "mixed",
        "name: mixed\n"
        "registries:\n  mcps: agents/mcp/registry.yaml\n"
        "mcps:\n  - name: extra\n    command: x\n",
    )
    out = parse_one(dotfiles / "profiles" / "mixed")
    names = [m["name"] for m in out["mcps"]]
    # Both registry entries (tilth, todoist) precede the lone inline entry.
    assert names[-1] == "extra"
    assert names.index("tilth") < names.index("extra")
    assert names.index("todoist") < names.index("extra")


def test_registries_directive_must_be_mapping(dotfiles):
    # A non-mapping `registries:` (e.g. a bare string) is a profile bug; the
    # parser fails loud rather than silently ignoring it.
    write_profile(
        dotfiles / "profiles",
        "badreg",
        "name: badreg\nregistries: agents/mcp/registry.yaml\n",
    )
    with pytest.raises(ParseError, match="registries"):
        parse_one(dotfiles / "profiles" / "badreg")


def test_no_registries_directive_yields_empty_registry_items(dotfiles):
    # Absent directive: the profile's items are exactly its inline items, with
    # nothing injected from the registries.
    write_profile(
        dotfiles / "profiles",
        "plain",
        "name: plain\nmcps:\n  - name: only\n    command: x\n",
    )
    out = parse_one(dotfiles / "profiles" / "plain")
    assert [m["name"] for m in out["mcps"]] == ["only"]
    assert out["agents"] == []
    assert out["hooks"] == []
    assert out["skills"] == []


def test_base_describe_unions_registries(dotfiles):
    write_profile(
        dotfiles / "profiles",
        "base",
        "name: base\n"
        "registries:\n"
        "  mcps: agents/mcp/registry.yaml\n"
        "  skills: [skills/]\n"
        "  hooks: agents/hooks/registry.yaml\n",
    )
    m = parse_manifest(dotfiles / "profiles" / "base")
    assert {x["name"] for x in m.mcps} == {"tilth", "todoist"}
    assert {x["name"] for x in m.skills} == {"de-slop"}
    assert {x["name"] for x in m.hooks} == {"flair"}
