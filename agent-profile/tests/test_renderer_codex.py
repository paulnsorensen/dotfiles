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


def test_mcp_env_keys_in_dotenv_are_scrubbed(renderer, src, target, monkeypatch, tmp_path):
    """Env entries whose key is exported by $DOTFILES_DIR/.env are dropped
    from the rendered TOML — zsh/core.zsh already exports them, so codex
    MCP children inherit at runtime. Non-.env keys still bake."""
    dotfiles = tmp_path / "df"
    dotfiles.mkdir()
    (dotfiles / ".env").write_text("CONTEXT7_API_KEY=ctx7sk-fake\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dotfiles))
    monkeypatch.delenv("AP_CODEX_INHERIT_ENV", raising=False)

    m = _manifest(
        src,
        mcps=[
            {
                "name": "context7",
                "command": "npx",
                "env": {
                    "CONTEXT7_API_KEY": "ctx7sk-fake",
                    "SERENA_MUX_HARNESS": "codex",
                },
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)
    doc = tomllib.loads((target / ".codex" / "config.toml").read_text())
    env = doc["mcp_servers"]["context7"].get("env", {})
    assert "CONTEXT7_API_KEY" not in env
    assert env.get("SERENA_MUX_HARNESS") == "codex"


def test_mcp_env_scrub_disabled_via_env(renderer, src, target, monkeypatch, tmp_path):
    """AP_CODEX_INHERIT_ENV=0 forces the pre-scrub behaviour (every env
    entry baked into the TOML, including .env-derived keys)."""
    dotfiles = tmp_path / "df"
    dotfiles.mkdir()
    (dotfiles / ".env").write_text("CONTEXT7_API_KEY=ctx7sk-fake\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dotfiles))
    monkeypatch.setenv("AP_CODEX_INHERIT_ENV", "0")

    m = _manifest(
        src,
        mcps=[
            {
                "name": "context7",
                "command": "npx",
                "env": {"CONTEXT7_API_KEY": "ctx7sk-fake"},
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)
    doc = tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["context7"]["env"]["CONTEXT7_API_KEY"] == "ctx7sk-fake"


def test_mcp_env_block_omitted_when_fully_scrubbed(renderer, src, target, monkeypatch, tmp_path):
    """If every env key is .env-derived, the env block is omitted entirely
    (no empty `[mcp_servers.foo.env]` table left dangling)."""
    dotfiles = tmp_path / "df"
    dotfiles.mkdir()
    (dotfiles / ".env").write_text("TODOIST_API_KEY=tok\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dotfiles))
    monkeypatch.delenv("AP_CODEX_INHERIT_ENV", raising=False)

    m = _manifest(
        src,
        mcps=[
            {
                "name": "todoist",
                "command": "npx",
                "env": {"TODOIST_API_KEY": "tok"},
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)
    doc = tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert "env" not in doc["mcp_servers"]["todoist"]


def test_mcp_literal_var_is_scrubbed_no_placeholder_or_secret(
    renderer, src, target, monkeypatch, tmp_path
):
    """Criterion 6: with the MCP-secret-passthrough flow the manifest now
    carries the literal ``${VAR}`` (not a resolved secret). Codex's
    scrub-by-keyname must still drop the `.env`-keyed entry, so neither the
    `${VAR}` placeholder NOR any secret lands in config.toml — codex inherits
    the value from the shell env at runtime."""
    dotfiles = tmp_path / "df"
    dotfiles.mkdir()
    (dotfiles / ".env").write_text("CONTEXT7_API_KEY=ctx7sk-real-secret\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dotfiles))
    monkeypatch.delenv("AP_CODEX_INHERIT_ENV", raising=False)

    m = _manifest(
        src,
        mcps=[
            {
                "name": "context7",
                "command": "npx",
                "env": {"CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"},
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)
    raw = (target / ".codex" / "config.toml").read_text()
    assert "${CONTEXT7_API_KEY}" not in raw
    assert "ctx7sk-real-secret" not in raw
    doc = tomllib.loads(raw)
    assert "env" not in doc["mcp_servers"]["context7"]


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


def test_scrubbed_credential_value_never_appears_in_rendered_file(
    renderer, src, target, monkeypatch, tmp_path
):
    """SECURITY: the scrub's whole purpose is keeping the credential VALUE off
    disk. Asserting the key is absent from the parsed env table is not enough —
    a regression that wrote the value to a comment, a differently-named key, or
    the args list would still pass that check. Assert the secret substring is
    absent from the entire raw config.toml text."""
    secret = "ctx7sk-dummy-never-leak-this"
    dotfiles = tmp_path / "df"
    dotfiles.mkdir()
    (dotfiles / ".env").write_text(f"CONTEXT7_API_KEY={secret}\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dotfiles))
    monkeypatch.delenv("AP_CODEX_INHERIT_ENV", raising=False)

    m = _manifest(
        src,
        mcps=[
            {
                "name": "context7",
                "command": "npx",
                "env": {"CONTEXT7_API_KEY": secret, "SERENA_MUX_HARNESS": "codex"},
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)
    text = (target / ".codex" / "config.toml").read_text()
    assert secret not in text
    # The non-credential key still bakes — proves we scrubbed the secret, not
    # the whole env block by accident.
    assert "SERENA_MUX_HARNESS" in text


def test_scrub_resolves_dotenv_via_home_fallback_when_dotfiles_dir_unset(
    renderer, src, target, monkeypatch, tmp_path
):
    """WHY: `_inherited_env_keys` falls back to `$HOME/Dev/dotfiles/.env` when
    DOTFILES_DIR is unset. The fallback must actually load that file — a broken
    fallback would silently bake every credential (scrub becomes a no-op)."""
    secret = "tok-dummy-fallback-value"
    home = tmp_path / "home"
    (home / "Dev" / "dotfiles").mkdir(parents=True)
    (home / "Dev" / "dotfiles" / ".env").write_text(f"TODOIST_API_KEY={secret}\n")
    monkeypatch.delenv("DOTFILES_DIR", raising=False)
    monkeypatch.delenv("AP_CODEX_INHERIT_ENV", raising=False)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))

    m = _manifest(
        src,
        mcps=[
            {
                "name": "todoist",
                "command": "npx",
                "env": {"TODOIST_API_KEY": secret},
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)
    text = (target / ".codex" / "config.toml").read_text()
    assert secret not in text


# ─── canonical permissions (curd 3) ─────────────────────────────────────
# Lever 1: the Bash(...) subset lowers to a .rules file of prefix_rule()s.
# Lever 3: mcp__server__tool allow/deny lowers to enabled/disabled_tools.

import tomllib as _tomllib  # noqa: E402

_RULES_REL = ".codex/rules/ap-canonical.rules"


def _parse_prefix_rules(text: str) -> list[tuple[list[str], str]]:
    """Extract (pattern, decision) pairs from a rendered .rules body without a
    Starlark interpreter — the file is deterministic line-structured output."""
    import re

    out = []
    for block in re.split(r"\)\n", text):
        pm = re.search(r"pattern = \[(.*?)\]", block, re.S)
        dm = re.search(r'decision = "(\w+)"', block)
        if pm and dm:
            pattern = [s.strip().strip('"') for s in pm.group(1).split(",") if s.strip()]
            out.append((pattern, dm.group(1)))
    return out


def test_allow_bash_rule_becomes_prefix_rule_allow(renderer, src, target):
    m = _manifest(src, settings={"permissions_allow": ["Bash(git:*)"]})
    renderer.render(m, target)
    rules = _parse_prefix_rules((target / _RULES_REL).read_text())
    assert (["git"], "allow") in rules


def test_allow_multiword_bash_rule_splits_argv(renderer, src, target):
    m = _manifest(src, settings={"permissions_allow": ["Bash(gh pr view:*)"]})
    renderer.render(m, target)
    rules = _parse_prefix_rules((target / _RULES_REL).read_text())
    assert (["gh", "pr", "view"], "allow") in rules


def test_deny_bash_rule_becomes_forbidden(renderer, src, target):
    m = _manifest(
        src,
        settings={"permissions_deny": ["Bash(rm -rf:*)", "Bash(sudo:*)"]},
    )
    renderer.render(m, target)
    rules = _parse_prefix_rules((target / _RULES_REL).read_text())
    assert (["rm", "-rf"], "forbidden") in rules
    assert (["sudo"], "forbidden") in rules


def test_non_bash_canonical_entries_skipped_in_rules(renderer, src, target):
    """Edit/Write/Read/Grep/Glob/Skill and mcp__* are not shell commands —
    they must not appear in the .rules file."""
    m = _manifest(
        src,
        settings={
            "permissions_allow": ["Edit", "Write", "Skill", "mcp__tilth__*"],
            "permissions_deny": ["Grep", "Glob"],
        },
    )
    renderer.render(m, target)
    # No Bash entries -> no rules file at all.
    assert not (target / _RULES_REL).is_file()


def test_no_rules_file_when_no_canonical_perms(renderer, src, target):
    m = _manifest(src, agents=[])
    renderer.render(m, target)
    assert not (target / _RULES_REL).is_file()


def test_clean_unlinks_rules_file(renderer, src, target):
    m = _manifest(src, settings={"permissions_allow": ["Bash(git:*)"]})
    renderer.render(m, target)
    assert (target / _RULES_REL).is_file()
    renderer.clean(m, target)
    assert not (target / _RULES_REL).is_file()


def test_mcp_named_tool_allow_writes_enabled_tools(renderer, src, target):
    m = _manifest(
        src, settings={"permissions_allow": ["mcp__tilth__tilth_read"]}
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["enabled_tools"] == ["tilth_read"]


def test_mcp_named_tool_deny_writes_disabled_tools(renderer, src, target):
    m = _manifest(
        src, settings={"permissions_deny": ["mcp__tilth__tilth_write"]}
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["disabled_tools"] == ["tilth_write"]


def test_mcp_whole_server_allow_adds_no_restriction(renderer, src, target):
    """`mcp__s__*` allow leaves the server unrestricted — it contributes no
    tool list, so with no other MCPs/rules the renderer writes no config.toml
    at all (no empty server table left behind)."""
    m = _manifest(src, settings={"permissions_allow": ["mcp__tilth__*"]})
    renderer.render(m, target)
    assert not (target / ".codex" / "config.toml").is_file()


def test_mcp_scope_merges_with_existing_server_entry(renderer, src, target):
    """A named-tool deny on a server that ALSO has a registered MCP command
    merges the disabled_tools key without clobbering command/args."""
    (target / ".codex").mkdir(parents=True)
    (target / ".codex" / "config.toml").write_text(
        '# user comment\n[mcp_servers.tilth]\ncommand = "tilth"\nargs = ["--mcp"]\n'
    )
    m = _manifest(
        src,
        mcps=[{"name": "tilth", "command": "tilth", "args": ["--mcp"], "harnesses": ["codex"]}],
        settings={"permissions_deny": ["mcp__tilth__tilth_write"]},
    )
    renderer.render(m, target)
    text = (target / ".codex" / "config.toml").read_text()
    assert "# user comment" in text  # tomlkit round-trip preserves comments
    doc = _tomllib.loads(text)
    assert doc["mcp_servers"]["tilth"]["command"] == "tilth"
    assert doc["mcp_servers"]["tilth"]["disabled_tools"] == ["tilth_write"]


def test_clean_unmerges_tool_scopes_preserving_user_command(renderer, src, target):
    """clean removes the ap-written disabled_tools but leaves a user-authored
    server command intact when the profile did NOT register that MCP (so the
    [mcp_servers] cleaner doesn't claim the whole server)."""
    (target / ".codex").mkdir(parents=True)
    (target / ".codex" / "config.toml").write_text(
        '[mcp_servers.tilth]\ncommand = "tilth"\n'
    )
    m = _manifest(
        src,
        settings={"permissions_deny": ["mcp__tilth__tilth_write"]},
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["disabled_tools"] == ["tilth_write"]

    renderer.clean(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    # disabled_tools gone, the user command survives.
    assert "disabled_tools" not in doc["mcp_servers"]["tilth"]
    assert doc["mcp_servers"]["tilth"]["command"] == "tilth"


def test_mixed_manifest_golden_rules(renderer, src, target):
    """A mixed manifest (allow+deny, Bash+mcp+non-bash) produces a stable,
    deterministic .rules body — the lever-1 golden."""
    m = _manifest(
        src,
        settings={
            "permissions_allow": ["Bash(git:*)", "Bash(gh pr view:*)", "Edit", "mcp__tilth__*"],
            "permissions_deny": ["Bash(rm -rf:*)", "Bash(sudo:*)", "Grep"],
        },
    )
    renderer.render(m, target)
    body = (target / _RULES_REL).read_text()
    expected = (
        "# Managed by ap (agent-profile) — canonical cross-harness permission rules.\n"
        "# Do not edit; regenerated on every `dots sync`. The TUI-owned default.rules is untouched.\n"
        "\n"
        'prefix_rule(\n    pattern = ["gh", "pr", "view"],\n    decision = "allow",\n)\n'
        'prefix_rule(\n    pattern = ["git"],\n    decision = "allow",\n)\n'
        'prefix_rule(\n    pattern = ["rm", "-rf"],\n    decision = "forbidden",\n)\n'
        'prefix_rule(\n    pattern = ["sudo"],\n    decision = "forbidden",\n)\n'
    )
    assert body == expected


def test_mcp_named_allow_and_deny_same_server_merge(renderer, src, target):
    """A server scoped by BOTH a named allow and a named deny gets both
    keys — enabled_tools and disabled_tools co-exist on one [mcp_servers.<s>]
    table (curd-3 lever-3). A regression that let one channel clobber the
    other (e.g. last-write-wins on the server entry) would drop a rule."""
    m = _manifest(
        src,
        settings={
            "permissions_allow": ["mcp__tilth__tilth_read"],
            "permissions_deny": ["mcp__tilth__tilth_write"],
        },
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["enabled_tools"] == ["tilth_read"]
    assert doc["mcp_servers"]["tilth"]["disabled_tools"] == ["tilth_write"]


def test_mcp_whole_server_deny_writes_nothing(renderer, src, target):
    """`mcp__s__*` DENY is a whole-server disable, which Codex expresses by
    omitting the server, not a tool list — so it must contribute no
    disabled_tools entry (and with no other rule, no config.toml at all). A
    regression that wrote `disabled_tools = ["*"]` or an empty table would
    misconfigure Codex; lock the documented skip."""
    m = _manifest(src, settings={"permissions_deny": ["mcp__tilth__*"]})
    renderer.render(m, target)
    assert not (target / ".codex" / "config.toml").is_file()


def test_sanctioned_bash_tools_render_allow_never_forbidden(renderer, src, target):
    """Negative (spec test plan): after the deny seed lands, rg/fd/sg stay
    ALLOWED — they must lower to decision="allow" prefix_rules and never to
    "forbidden". Read is not a shell command, so it must not appear at all.
    Drives the full canonical shape (allow seed + deny seed together) through
    the renderer, not just the parse layer."""
    m = _manifest(
        src,
        settings={
            "permissions_allow": ["Bash(rg:*)", "Bash(fd:*)", "Bash(sg:*)", "Read"],
            "permissions_deny": ["Bash(grep:*)", "Bash(ag:*)", "Grep", "Glob"],
        },
    )
    renderer.render(m, target)
    rules = _parse_prefix_rules((target / _RULES_REL).read_text())
    for tool in ("rg", "fd", "sg"):
        assert ([tool], "allow") in rules
        assert ([tool], "forbidden") not in rules
    # grep/ag deny lands as forbidden; Read (not a shell cmd) never appears.
    assert (["grep"], "forbidden") in rules
    assert (["ag"], "forbidden") in rules
    assert not any(pat == ["Read"] for pat, _ in rules)


def test_clean_leaves_sibling_default_rules_untouched(renderer, src, target):
    """clean unlinks ONLY ap-canonical.rules. A TUI-owned sibling
    default.rules under the same rules/ dir must survive — the spec's clean
    contract ("the TUI-owned default.rules is untouched")."""
    m = _manifest(src, settings={"permissions_allow": ["Bash(git:*)"]})
    renderer.render(m, target)
    rules_dir = (target / _RULES_REL).parent
    default_rules = rules_dir / "default.rules"
    default_rules.write_text("# TUI-owned, ap must not touch\n")

    renderer.clean(m, target)

    assert not (target / _RULES_REL).is_file()
    assert default_rules.is_file()
    assert default_rules.read_text() == "# TUI-owned, ap must not touch\n"
