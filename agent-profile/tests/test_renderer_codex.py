# invoked-from: cheese-factory-curd
"""test_renderer_codex.py — CodexRenderer behavioral-parity + upgrade tests.

Ported from tests/agent-profile-renderers-codex.bats. The bash renderer
merged ``config.toml`` through ``yq -p=toml -o=toml``, which **shredded
user comments** — the captured golden in ``fixtures/golden/codex/`` proves
it (no ``#`` lines survive). The whole point of this curd is the tomlkit
upgrade: keys + values still match bash (data parity, asserted against the
golden), AND user comments now survive the surgical ``[mcp_servers]``
merge/clean (asserted directly — there is no bash golden for that, because
bash could not do it).

Agent TOML is asserted on round-trip semantics (tomllib *and* tomlkit
reparse to the exact source body), not byte-equality with the bash
hand-rolled escaping — tomlkit owns the escaping now.
"""

from __future__ import annotations

import json
import tomllib
from pathlib import Path

import pytest
import tomlkit

from agent_profile.parse import Manifest
from agent_profile.renderers.codex import CodexRenderer

GOLDEN = Path(__file__).parent / "fixtures" / "golden" / "codex"
RENDERER_SRC = Path(__file__).parent.parent / "agent_profile" / "renderers" / "codex.py"


def _manifest(src: Path, **sections) -> Manifest:
    """Build a Manifest with ``_source_dir`` stamped on every item — the
    Python analogue of the bats ``merged`` helper."""
    base = dict(
        name="p1",
        description="test",
        mcps=[],
        agents=[],
        skills=[],
        commands=[],
        hooks=[],
        settings={},
    )
    base.update(sections)
    for key in ("mcps", "agents", "skills", "commands", "hooks"):
        base[key] = [{**item, "_source_dir": str(src)} for item in base[key]]
    return Manifest(**base)


@pytest.fixture
def src(tmp_path):
    d = tmp_path / "src"
    d.mkdir()
    return d


@pytest.fixture
def target(tmp_path):
    d = tmp_path / "target"
    d.mkdir()
    return d


@pytest.fixture
def renderer():
    return CodexRenderer()


# ─── subagents ─────────────────────────────────────────────────────────


def test_writes_subagent_toml_with_fields(renderer, src, target):
    (src / "agents").mkdir()
    (src / "agents" / "reviewer.md").write_text("Review code for issues.\nBe terse.\n")
    m = _manifest(
        src,
        agents=[
            {
                "name": "reviewer",
                "description": "Reviews code.",
                "body_path": "agents/reviewer.md",
            }
        ],
    )
    renderer.render(m, target)

    toml_path = target / ".codex" / "agents" / "reviewer.toml"
    assert toml_path.is_file()
    doc = tomllib.loads(toml_path.read_text())
    assert doc["name"] == "reviewer"
    assert doc["description"] == "Reviews code."
    assert doc["developer_instructions"] == "Review code for issues.\nBe terse.\n"


def test_subagent_toml_round_trips_tomllib_and_tomlkit(renderer, src, target):
    """The tricky body (quotes, backslashes, embedded triple-quote, trailing
    newline) must survive a full round-trip through both parsers — proving
    tomlkit's native escaping is correct without any hand-rolled helper."""
    (src / "agents").mkdir()
    body = (
        'Line with "double" quotes\n'
        "Backslash \\ here and a path C:\\temp\n"
        'A triple """ inside\n'
        "Last line\n"
    )
    (src / "agents" / "r.md").write_text(body)
    m = _manifest(
        src,
        agents=[{"name": "r", "description": 'A "tricky" desc', "body_path": "agents/r.md"}],
    )
    renderer.render(m, target)

    raw = (target / ".codex" / "agents" / "r.toml").read_text()
    via_tomllib = tomllib.loads(raw)
    via_tomlkit = tomlkit.parse(raw)

    assert via_tomllib["developer_instructions"] == body
    assert str(via_tomlkit["developer_instructions"]) == body
    assert via_tomllib["description"] == 'A "tricky" desc'
    assert str(via_tomlkit["description"]) == 'A "tricky" desc'


def test_subagent_body_matches_bash_golden_on_roundtrip(renderer, src, target):
    """Data parity with the bash golden for name/description/model and the
    body — *modulo the bash trailing-newline artifact*.

    The bash ``_codex_escape_toml_triple`` ran the body through ``$(sed …)``,
    and command substitution strips trailing newlines, so bash emitted
    ``…Last line\"\"\"`` (no final ``\\n``). The tomlkit port has no such
    shell quirk and preserves the true body verbatim. We assert our body
    equals the source, and equals the bash body once the dropped newline is
    restored — proving the only divergence is the bash bug we left behind.
    """
    (src / "agents").mkdir()
    body = (
        'Line with "double" quotes\n'
        "Backslash \\ here and a path C:\\temp\n"
        'A triple """ inside\n'
        "Last line\n"
    )
    (src / "agents" / "tricky.md").write_text(body)
    m = _manifest(
        src,
        agents=[
            {
                "name": "tricky",
                "description": 'A "tricky" desc',
                "body_path": "agents/tricky.md",
                "models": {"codex": "gpt-5"},
            }
        ],
    )
    renderer.render(m, target)

    ours = tomllib.loads((target / ".codex" / "agents" / "tricky.toml").read_text())
    bash = tomllib.loads((GOLDEN / "bash_agent_tricky.toml").read_text())
    assert ours["name"] == bash["name"] == "tricky"
    assert ours["description"] == bash["description"]
    assert ours["model"] == bash["model"] == "gpt-5"
    # Ours preserves the true source body; bash dropped the trailing newline.
    assert ours["developer_instructions"] == body
    assert bash["developer_instructions"] == body.rstrip("\n")
    assert ours["developer_instructions"].rstrip("\n") == bash["developer_instructions"]


def test_subagent_gets_model_when_models_codex_set(renderer, src, target):
    (src / "agents").mkdir()
    (src / "agents" / "r.md").write_text("body\n")
    m = _manifest(
        src,
        agents=[
            {"name": "r", "description": "d", "body_path": "agents/r.md", "models": {"codex": "gpt-5"}}
        ],
    )
    renderer.render(m, target)
    doc = tomllib.loads((target / ".codex" / "agents" / "r.toml").read_text())
    assert doc["model"] == "gpt-5"


def test_no_model_field_when_models_codex_absent(renderer, src, target):
    (src / "agents").mkdir()
    (src / "agents" / "r.md").write_text("body\n")
    m = _manifest(
        src,
        agents=[
            {"name": "r", "description": "d", "body_path": "agents/r.md", "models": {"claude": "opus"}}
        ],
    )
    renderer.render(m, target)
    doc = tomllib.loads((target / ".codex" / "agents" / "r.toml").read_text())
    assert "model" not in doc


def test_agent_without_body_path_emits_empty_instructions(renderer, src, target):
    m = _manifest(src, agents=[{"name": "r", "description": "d"}])
    renderer.render(m, target)
    doc = tomllib.loads((target / ".codex" / "agents" / "r.toml").read_text())
    assert doc["developer_instructions"] == ""


# ─── skills ──────────────────────────────────────────────────────────────


def test_skill_copies_tree_to_shared_agents_skills(renderer, src, target):
    skill = src / "skills" / "k1"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("skill body\n")
    (skill / "reference.md").write_text("ref\n")
    m = _manifest(src, skills=[{"name": "k1", "path": "skills/k1"}])
    renderer.render(m, target)

    assert (target / ".agents" / "skills" / "k1" / "SKILL.md").is_file()
    assert (target / ".agents" / "skills" / "k1" / "reference.md").is_file()
    # Never written to a codex-only skills path.
    assert not (target / ".codex" / "skills").exists()


# ─── hooks ───────────────────────────────────────────────────────────────


def test_codex_hook_writes_hooks_json_and_script(renderer, src, target):
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\necho hi\n")
    m = _manifest(
        src,
        hooks=[
            {
                "event": "PreToolUse",
                "matcher": "Bash",
                "script": "hooks/h.sh",
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)

    hooks_json = target / ".codex" / "hooks.json"
    assert hooks_json.is_file()
    copied = target / ".codex" / "hooks" / "h.sh"
    assert copied.is_file()
    import os

    assert os.access(copied, os.X_OK)

    records = json.loads(hooks_json.read_text())
    assert records == [
        {"event": "PreToolUse", "command": "bash .codex/hooks/h.sh", "matcher": "Bash"}
    ]


def test_claude_only_hook_does_not_write_hooks_json(renderer, src, target):
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\n")
    m = _manifest(
        src,
        hooks=[
            {"event": "PreToolUse", "matcher": "Bash", "script": "hooks/h.sh", "harnesses": ["claude"]}
        ],
    )
    renderer.render(m, target)
    assert not (target / ".codex" / "hooks.json").exists()
    assert not (target / ".codex" / "hooks").exists()


def test_hook_default_membership_is_claude_only(renderer, src, target):
    """A hook with no ``harnesses`` defaults to claude — no codex output."""
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\n")
    m = _manifest(
        src, hooks=[{"event": "PreToolUse", "script": "hooks/h.sh"}]
    )
    renderer.render(m, target)
    assert not (target / ".codex" / "hooks.json").exists()


def test_hook_timeout_is_emitted_as_number(renderer, src, target):
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\n")
    m = _manifest(
        src,
        hooks=[
            {"event": "SessionStart", "script": "hooks/h.sh", "timeout": 5, "harnesses": ["codex"]}
        ],
    )
    renderer.render(m, target)
    records = json.loads((target / ".codex" / "hooks.json").read_text())
    assert records[0]["timeout"] == 5
    assert "matcher" not in records[0]


def test_hook_missing_script_file_raises(renderer, src, target):
    m = _manifest(
        src,
        hooks=[{"event": "PreToolUse", "script": "hooks/nope.sh", "harnesses": ["codex"]}],
    )
    with pytest.raises(FileNotFoundError):
        renderer.render(m, target)


# ─── MCPs: merge preserves user keys + comments (the upgrade) ─────────────


def _user_config() -> str:
    return (
        "# user top-level comment\n"
        'approval_policy = "untrusted"\n'
        'sandbox_mode = "workspace-write"\n'
        "\n"
        "# user's own MCP server\n"
        "[mcp_servers.user-tool]\n"
        'command = "user-cmd"\n'
        'args = ["--flag"]\n'
        "\n"
        "[other_table]\n"
        'key = "value"\n'
    )


def test_codex_mcp_merges_into_config_toml(renderer, src, target):
    m = _manifest(
        src,
        mcps=[{"name": "foo", "command": "npx", "args": ["-y", "foo-mcp"], "harnesses": ["codex"]}],
    )
    renderer.render(m, target)
    cfg = target / ".codex" / "config.toml"
    assert cfg.is_file()
    doc = tomllib.loads(cfg.read_text())
    assert doc["mcp_servers"]["foo"]["command"] == "npx"
    assert doc["mcp_servers"]["foo"]["args"] == ["-y", "foo-mcp"]


def test_claude_only_mcp_not_written_to_config_toml(renderer, src, target):
    m = _manifest(src, mcps=[{"name": "foo", "command": "x", "harnesses": ["claude"]}])
    renderer.render(m, target)
    assert not (target / ".codex" / "config.toml").exists()


def test_mcp_merge_preserves_user_keys_and_comments(renderer, src, target):
    """The bash golden proves yq dropped the user's comments; tomlkit keeps
    them. Assert both data parity (keys/values match the bash golden) AND
    comment survival (the behavior bash lacked)."""
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text(_user_config())

    m = _manifest(
        src,
        mcps=[
            {
                "name": "foo",
                "command": "npx",
                "args": ["-y", "foo-mcp"],
                "env": {"K": "V"},
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)
    text = cfg.read_text()
    doc = tomllib.loads(text)

    # Data parity with the bash golden: same keys + values.
    bash = tomllib.loads((GOLDEN / "bash_config_after_merge.toml").read_text())
    assert doc == bash
    assert doc["approval_policy"] == "untrusted"
    assert doc["mcp_servers"]["user-tool"]["command"] == "user-cmd"
    assert doc["mcp_servers"]["user-tool"]["args"] == ["--flag"]
    assert doc["mcp_servers"]["foo"]["command"] == "npx"
    assert doc["mcp_servers"]["foo"]["env"]["K"] == "V"
    assert doc["other_table"]["key"] == "value"

    # The upgrade bash could not do: user comments survive.
    assert "# user top-level comment" in text
    assert "# user's own MCP server" in text


def test_mcp_merge_into_empty_target_has_no_comments_to_lose(renderer, src, target):
    """Sanity: merging into a non-existent config produces a clean file with
    only our table."""
    m = _manifest(src, mcps=[{"name": "foo", "command": "npx", "harnesses": ["codex"]}])
    renderer.render(m, target)
    doc = tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert list(doc.keys()) == ["mcp_servers"]
    assert doc["mcp_servers"]["foo"]["command"] == "npx"


# ─── commands deprecated, AGENTS.md never touched ─────────────────────────


def test_commands_skipped_with_warning(renderer, src, target, capsys):
    (src / "commands").mkdir()
    (src / "commands" / "c.md").write_text("body\n")
    m = _manifest(
        src, commands=[{"name": "c", "description": "d", "body_path": "commands/c.md"}]
    )
    renderer.render(m, target)
    err = capsys.readouterr().err
    assert "skipping command 'c'" in err
    assert "deprecated" in err
    assert not (target / ".codex" / "commands").exists()


def test_never_writes_agents_md(renderer, src, target):
    (src / "agents").mkdir()
    (src / "agents" / "r.md").write_text("body\n")
    skill = src / "skills" / "k1"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("skill\n")
    m = _manifest(
        src,
        agents=[{"name": "r", "description": "d", "body_path": "agents/r.md"}],
        skills=[{"name": "k1", "path": "skills/k1"}],
    )
    renderer.render(m, target)
    assert not (target / "AGENTS.md").exists()


# ─── out_files tracking ───────────────────────────────────────────────────


def test_render_tracks_agent_toml_and_skill_dir(renderer, src, target):
    (src / "agents").mkdir()
    (src / "agents" / "r.md").write_text("body\n")
    skill = src / "skills" / "k1"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("skill\n")
    m = _manifest(
        src,
        agents=[{"name": "r", "description": "d", "body_path": "agents/r.md"}],
        skills=[{"name": "k1", "path": "skills/k1"}],
    )
    out = renderer.render(m, target)
    assert ".codex/agents/r.toml" in out
    assert ".agents/skills/k1" in out


def test_render_does_not_track_config_toml(renderer, src, target):
    """config.toml is a merged file, never a whole-file artefact."""
    m = _manifest(src, mcps=[{"name": "foo", "command": "npx", "harnesses": ["codex"]}])
    out = renderer.render(m, target)
    assert ".codex/config.toml" not in out


# ─── clean ─────────────────────────────────────────────────────────────────


def test_clean_removes_only_our_entries_keeps_user(renderer, src, target):
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text(_user_config())
    m = _manifest(
        src,
        mcps=[
            {"name": "foo", "command": "npx", "args": ["-y", "foo-mcp"], "env": {"K": "V"}, "harnesses": ["codex"]}
        ],
    )
    renderer.render(m, target)
    renderer.clean(m, target)

    text = cfg.read_text()
    doc = tomllib.loads(text)
    # Data parity with bash golden after clean.
    bash = tomllib.loads((GOLDEN / "bash_config_after_clean.toml").read_text())
    assert doc == bash
    assert doc["approval_policy"] == "untrusted"
    assert doc["mcp_servers"]["user-tool"]["command"] == "user-cmd"
    assert "foo" not in doc["mcp_servers"]
    assert doc["other_table"]["key"] == "value"
    # Comments still survive the clean round-trip.
    assert "# user top-level comment" in text
    assert "# user's own MCP server" in text


def test_clean_deletes_file_when_only_our_entries_existed(renderer, src, target):
    m = _manifest(src, mcps=[{"name": "foo", "command": "npx", "harnesses": ["codex"]}])
    renderer.render(m, target)
    cfg = target / ".codex" / "config.toml"
    assert cfg.is_file()
    renderer.clean(m, target)
    assert not cfg.exists()


def test_clean_missing_config_is_noop(renderer, src, target):
    m = _manifest(src, mcps=[{"name": "foo", "command": "x", "harnesses": ["codex"]}])
    renderer.clean(m, target)  # must not raise
    assert not (target / ".codex" / "config.toml").exists()


def test_clean_keeps_file_when_user_table_remains(renderer, src, target):
    """When our entry is the only [mcp_servers] member but a sibling user
    table exists, the file stays (only the empty mcp_servers table drops)."""
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text('approval_policy = "untrusted"\n\n[mcp_servers.foo]\ncommand = "npx"\n')
    m = _manifest(src, mcps=[{"name": "foo", "command": "npx", "harnesses": ["codex"]}])
    renderer.clean(m, target)
    assert cfg.is_file()
    doc = tomllib.loads(cfg.read_text())
    assert doc == {"approval_policy": "untrusted"}
    assert "mcp_servers" not in doc


# ─── no hand-rolled escaping remains ─────────────────────────────────────


def test_no_hand_rolled_escaping_in_source():
    """The bash hand-rolled ``_codex_toml_string`` /
    ``_codex_escape_toml_triple`` and shelled out to jq/yq. None of that
    machinery may survive the tomlkit port.

    We inspect *code only* — comments and string literals (incl. the module
    docstring, which legitimately names the removed bash helpers to explain
    the port) are stripped via the tokenizer first.
    """
    import io
    import tokenize

    src = RENDERER_SRC.read_text()
    code_tokens: list[str] = []
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type in (tokenize.COMMENT, tokenize.STRING):
            continue
        if tok.string:
            code_tokens.append(tok.string)
    code = " ".join(code_tokens)

    for forbidden in (
        "_codex_toml_string",
        "_codex_escape_toml_triple",
        "subprocess",
        "jq",
        "yq",
        "replace",  # no str.replace-based manual escaping
    ):
        assert forbidden not in code, f"hand-rolled/shell escaping leaked: {forbidden!r}"
    # tomlkit must be the TOML substrate (an import name token).
    assert "tomlkit" in code
