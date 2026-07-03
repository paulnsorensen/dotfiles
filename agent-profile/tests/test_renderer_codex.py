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
import shutil
import shlex
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
        isolated=True,
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
    assert records == {
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {"type": "command", "command": f"bash {copied}"}
                    ],
                }
            ]
        }
    }


def test_codex_hook_command_resolves_from_unrelated_cwd(renderer, src, target, tmp_path):
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

    unrelated_cwd = tmp_path / "session"
    unrelated_cwd.mkdir()
    command = json.loads((target / ".codex" / "hooks.json").read_text())["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
    argv = shlex.split(command)
    assert argv[0] == "bash"
    script = Path(argv[1])
    assert script.is_absolute()
    assert script.is_file()
    assert not (unrelated_cwd / ".codex" / "hooks" / "h.sh").exists()


def test_codex_literal_command_hook_writes_hooks_json_without_script_deploy(renderer, src, target):
    m = _manifest(
        src,
        hooks=[
            {
                "event": "PostToolUse",
                "matcher": "Bash",
                "command": "echo literal",
                "harnesses": ["codex"],
            }
        ],
    )
    renderer.render(m, target)

    records = json.loads((target / ".codex" / "hooks.json").read_text())
    assert records == {
        "hooks": {
            "PostToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {"type": "command", "command": "echo literal"}
                    ],
                }
            ]
        }
    }
    assert not (target / ".codex" / "hooks").exists()


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
    handler = records["hooks"]["SessionStart"][0]["hooks"][0]
    group = records["hooks"]["SessionStart"][0]
    assert handler["timeout"] == 5
    assert "matcher" not in group


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

def test_nonisolated_manifest_skips_config_toml_writes(renderer, src, target):
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True)
    seeded = _user_config()
    cfg.write_text(seeded)
    manifest = Manifest(
        name="live",
        mcps=[{"name": "foo", "command": "npx", "harnesses": ["codex"], "_source_dir": str(src)}],
        settings={"permissions_deny": ["mcp__tilth__tilth_write"]},
    )
    renderer.render(manifest, target)
    assert cfg.read_text() == seeded
    renderer.clean(manifest, target)
    assert cfg.read_text() == seeded


def test_nonisolated_render_preserves_legacy_config_toml_hooks(renderer, src, target):
    """A non-isolated (live) render with a codex hook still writes hooks.json,
    but must NOT sweep legacy [[hooks.*]] blocks from the shared config.toml —
    that file is user/chezmoi territory now. The seeded legacy block points at
    a managed basename (exactly what the migration sweep strips in an isolated
    launch), so its byte-identical survival proves the sweep is gated off for
    live installs. Mirrors the _write_mcps/_write_mcp_tool_scopes gating."""
    hooks_dir = src / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    (hooks_dir / "session-start-cheese-flair.sh").write_text("#!/bin/bash\n: flair\n")

    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True)
    seeded = (
        "[[hooks.SessionStart]]\n"
        'matcher = "startup|resume"\n'
        "\n"
        "[[hooks.SessionStart.hooks]]\n"
        'type = "command"\n'
        'command = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"\n'
        "timeout = 5\n"
    )
    cfg.write_text(seeded)

    manifest = Manifest(
        name="live",
        hooks=[
            {
                "name": "session-start-cheese-flair",
                "event": "SessionStart",
                "script": "hooks/session-start-cheese-flair.sh",
                "matcher": "startup|resume",
                "timeout": 5,
                "harnesses": ["claude", "codex"],
                "_source_dir": str(src),
            }
        ],
    )
    renderer.render(manifest, target)

    assert cfg.read_text() == seeded, (
        "non-isolated render swept a legacy config.toml hook block; the live "
        "config.toml must stay untouched"
    )
    # hooks.json is a managed output file, written regardless of isolation.
    assert (target / ".codex" / "hooks.json").is_file()

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
    ``_codex_escape_toml_triple`` and shelled out to jq/yq for config writes.
    None of that TOML-escaping machinery may survive the tomlkit port.

    (``subprocess`` is intentionally NOT forbidden: the codex_native plugin
    pass shells out to the ``codex`` CLI, mirroring the claude renderer's
    native install — that is config delegation, not hand-rolled escaping.)

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


def test_write_rules_unlinks_stale_file_when_rules_go_empty(renderer, src, target):
    """SSOT: a prior render wrote a .rules file; the canonical list is then
    edited so NO Bash rule remains. The next render must unlink the stale
    ap-canonical.rules — leaving it would keep a dead execpolicy floor in
    force. A regression that returned early without unlinking would strand
    the old allow/forbidden prefix rules."""
    m1 = _manifest(src, settings={"permissions_allow": ["Bash(git:*)"]})
    renderer.render(m1, target)
    assert (target / _RULES_REL).is_file()

    # Same renderer, now no Bash-prefix rules at all (only non-shell entries).
    m2 = _manifest(
        src,
        settings={"permissions_allow": ["Edit", "mcp__tilth__*"]},
    )
    renderer.render(m2, target)
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


def test_mcp_whole_server_allow_wins_over_named_omits_enabled_tools(
    renderer, src, target
):
    """When the canonical allow carries BOTH `mcp__<s>__*` and a named-tool
    rule for the same server, the whole-server allow wins -> NO enabled_tools
    key (the server stays unrestricted). With no other MCP/rule that means no
    config.toml at all. A regression that read only named_mcp_tools would
    wrongly write enabled_tools = [<named>] (findings 4/5)."""
    m = _manifest(
        src,
        settings={
            "permissions_allow": ["mcp__tilth__*", "mcp__tilth__tilth_read"],
        },
    )
    renderer.render(m, target)
    assert not (target / ".codex" / "config.toml").is_file()


def test_mcp_whole_server_allow_keeps_disabled_tools(renderer, src, target):
    """A whole-server allow nullifies the server's enabled_tools but must NOT
    touch disabled_tools (deny channel is independent of the whole-server
    allow). enabled is dropped, disabled survives."""
    m = _manifest(
        src,
        settings={
            "permissions_allow": ["mcp__tilth__*", "mcp__tilth__tilth_read"],
            "permissions_deny": ["mcp__tilth__tilth_write"],
        },
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert "enabled_tools" not in doc["mcp_servers"]["tilth"]
    assert doc["mcp_servers"]["tilth"]["disabled_tools"] == ["tilth_write"]


def test_mcp_scope_clears_stale_enabled_tools_on_removal(renderer, src, target):
    """SSOT: a tool dropped from the canonical allow list must clear the
    PRIOR enabled_tools key, not leave it behind. Here a prior render wrote
    enabled_tools = ['tilth_read', 'tilth_list']; the canonical list now
    names only one of them, so the render must rewrite the key to just the
    surviving tool — never union the stale entry back in."""
    (target / ".codex").mkdir(parents=True)
    (target / ".codex" / "config.toml").write_text(
        '[mcp_servers.tilth]\ncommand = "tilth"\n'
        'enabled_tools = ["tilth_list", "tilth_read"]\n'
    )
    m = _manifest(
        src,
        settings={"permissions_allow": ["mcp__tilth__tilth_read"]},
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert doc["mcp_servers"]["tilth"]["enabled_tools"] == ["tilth_read"]


def test_mcp_scope_whole_server_clears_prior_enabled_tools(renderer, src, target):
    """SSOT + findings 4/5: when the last NAMED allow for a server is dropped
    and only a whole-server `mcp__<s>__*` allow remains, the prior
    enabled_tools key must be cleared (server back to unrestricted), not left
    stale. The server is still 'managed' (named by the whole-server rule), so
    the stale key is removed even though the new enabled set is empty. The
    user command survives; the now-empty table is not orphaned with a stale
    restriction."""
    (target / ".codex").mkdir(parents=True)
    (target / ".codex" / "config.toml").write_text(
        '[mcp_servers.tilth]\ncommand = "tilth"\n'
        'enabled_tools = ["tilth_read"]\n'
    )
    m = _manifest(
        src,
        settings={"permissions_allow": ["mcp__tilth__*"]},
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert "enabled_tools" not in doc["mcp_servers"]["tilth"]
    assert doc["mcp_servers"]["tilth"]["command"] == "tilth"


def test_mcp_scope_clears_stale_disabled_tools_on_removal(renderer, src, target):
    """SSOT mirror for the deny channel: a named-tool deny dropped from the
    canonical list clears the prior disabled_tools key. A whole-server deny
    keeps the server 'managed', so the stale key is removed."""
    (target / ".codex").mkdir(parents=True)
    (target / ".codex" / "config.toml").write_text(
        '[mcp_servers.tilth]\ncommand = "tilth"\n'
        'disabled_tools = ["tilth_write"]\n'
    )
    m = _manifest(
        src,
        settings={"permissions_deny": ["mcp__tilth__*"]},
    )
    renderer.render(m, target)
    doc = _tomllib.loads((target / ".codex" / "config.toml").read_text())
    assert "disabled_tools" not in doc["mcp_servers"]["tilth"]
    assert doc["mcp_servers"]["tilth"]["command"] == "tilth"


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


# ─── codex_native plugin pass ───────────────────────────────────────────────
# Mirrors test_claude_native_plugins.py's renderer section: a codex_native plugin
# installs via the codex CLI (mocked), its decomposed MCP/skills are not written
# into config.toml / .agents/skills, and clean() un-registers via the CLI.

from unittest.mock import MagicMock, patch  # noqa: E402


def _make_codex_native_marketplace(tmp_path, market_name="milknado"):
    """Build a marketplace root carrying both manifests — .claude-plugin/
    marketplace.json (read by claude et al.) and .agents/plugins/marketplace.json
    (the manifest codex's `plugin marketplace add` actually parses) — and a
    Manifest whose native_plugins entry flags codex_native. Returns
    (manifest, market_root)."""
    market_root = tmp_path / "mktplace" / market_name
    market_root.mkdir(parents=True, exist_ok=True)
    (market_root / ".claude-plugin").mkdir()
    (market_root / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps({
            "name": market_name,
            "owner": {"name": "test"},
            "plugins": [{"name": market_name, "source": f"./plugins/{market_name}"}],
        })
    )
    (market_root / ".agents" / "plugins").mkdir(parents=True)
    (market_root / ".agents" / "plugins" / "marketplace.json").write_text(
        json.dumps({
            "name": market_name,
            "interface": {"displayName": market_name},
            "plugins": [{
                "source": {"source": "local", "path": f"./plugins/{market_name}"},
            }],
        })
    )
    manifest = Manifest(
        name="base",
        native_plugins=[{
            "name": market_name,
            "claude_native": False,
            "codex_native": True,
            "marketplace_root": str(market_root),
            "marketplace_name": market_name,
            "description": "Test plugin",
        }],
    )
    return manifest, market_root


def test_codex_native_install_shells_marketplace_and_plugin_add(tmp_path):
    """render() runs `codex plugin marketplace add <root>` + `codex plugin add
    <name>@<marketplace>` for a codex_native plugin."""
    manifest, market_root = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    calls = [c.args[0] for c in mock_run.call_args_list if c.args]
    assert ["codex", "plugin", "marketplace", "add", str(market_root)] in calls, (
        f"expected marketplace add with marketplace root, got: {calls}"
    )
    assert ["codex", "plugin", "add", "milknado@milknado"] in calls, (
        f"expected plugin add <name>@<marketplace>, got: {calls}"
    )


def test_codex_native_marketplace_add_uses_root_with_manifest(tmp_path):
    """The path passed to marketplace add holds the manifest codex actually
    parses: .agents/plugins/marketplace.json (not .claude-plugin/...)."""
    manifest, market_root = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    market_calls = [
        c.args[0] for c in mock_run.call_args_list
        if c.args and c.args[0][:4] == ["codex", "plugin", "marketplace", "add"]
    ]
    assert market_calls
    passed = market_calls[0][-1]
    assert (Path(passed) / ".agents" / "plugins" / "marketplace.json").is_file(), (
        f"marketplace add path {passed} has no .agents/plugins/marketplace.json"
    )


def test_codex_native_skills_skipped(tmp_path):
    """_write_skills skips items carrying _from_codex_native_plugin."""
    payload = tmp_path / "payload"
    skill_src = payload / "skills" / "my-skill"
    skill_src.mkdir(parents=True)
    (skill_src / "SKILL.md").write_text("skill content")

    manifest = Manifest(
        name="base",
        skills=[{
            "name": "my-skill",
            "path": "skills/my-skill",
            "_source_dir": str(payload),
            "_from_codex_native_plugin": True,
        }],
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    # codex copies skills into the shared .agents/skills/<name>/ tree.
    skill_out = target / ".agents" / "skills" / "my-skill"
    assert not skill_out.exists(), (
        f"codex_native skill must not be copied (delivered via codex plugin): {skill_out}"
    )


def test_codex_native_plugin_mcp_absent_from_config(tmp_path):
    """After DEDUP, an MCP with harnesses=[opencode] (codex removed) is not
    written into config.toml's [mcp_servers] for codex.

    Not vacuous: the item originally carried codex in harnesses; DEDUP removed
    it. If DEDUP were dropped, mcps_for(..., 'codex') would include it and the
    server would land in config.toml.
    """
    manifest, market_root = _make_codex_native_marketplace(tmp_path)
    manifest.mcps = [{
        "name": "milknado",
        "command": "uvx",
        "args": ["milknado-mcp"],
        "harnesses": ["opencode"],  # codex removed by DEDUP
        "_source_dir": str(market_root),
    }]
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    cfg = target / ".codex" / "config.toml"
    if cfg.is_file():
        doc = tomllib.loads(cfg.read_text())
        servers = doc.get("mcp_servers", {})
        assert "milknado" not in servers, (
            f"codex_native plugin MCP must not be in config.toml: {servers}"
        )


def test_codex_native_clean_unregisters(tmp_path):
    """clean() runs `codex plugin remove` + `codex plugin marketplace remove`."""
    manifest, market_root = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().clean(manifest, target)

    calls = [c.args[0] for c in mock_run.call_args_list if c.args]
    assert ["codex", "plugin", "remove", "milknado@milknado"] in calls, (
        f"expected plugin remove, got: {calls}"
    )
    assert ["codex", "plugin", "marketplace", "remove", "milknado"] in calls, (
        f"expected marketplace remove, got: {calls}"
    )


def test_codex_native_install_tolerates_missing_cli(tmp_path):
    """A missing codex binary (FileNotFoundError) is a no-op, not a hard fail."""
    manifest, _ = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run", side_effect=FileNotFoundError):
        CodexRenderer().render(manifest, target)  # must not raise


@pytest.mark.skipif(
    shutil.which("codex") is None, reason="codex CLI not installed"
)
def test_real_codex_rejects_manifest_missing_name(tmp_path):
    """Non-mocked: the real `codex plugin marketplace add` must reject a
    .agents/plugins/marketplace.json with no top-level `name`. This is the exact
    shape that silently stripped milknado from codex; the strict marketplace-add
    path must turn that into a loud render failure (RuntimeError), not a no-op.
    """
    market_root = tmp_path / "mkt"
    (market_root / ".agents" / "plugins").mkdir(parents=True)
    (market_root / ".agents" / "plugins" / "marketplace.json").write_text(
        json.dumps({
            "interface": {"displayName": "badmkt"},  # no top-level "name"
            "plugins": [{
                "source": {"source": "local", "path": "./plugins/badmkt"},
            }],
        })
    )
    entry = {
        "name": "badmkt",
        "marketplace_name": "badmkt-unregistered-xyz",
        "marketplace_root": str(market_root),
        "codex_native": True,
    }
    with pytest.raises(RuntimeError, match="marketplace add"):
        CodexRenderer()._install_codex_native_plugin(entry)


def test_codex_native_marketplace_add_failure_raises(tmp_path):
    """A nonzero `marketplace add` is fatal: it raises instead of silently
    stripping the plugin from codex (DEDUP already dropped its decomposed MCP).
    """
    manifest, _ = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    def fake_run(argv, **kwargs):
        if argv[:4] == ["codex", "plugin", "marketplace", "add"]:
            return MagicMock(returncode=1, stderr="invalid marketplace file", stdout="")
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        with pytest.raises(RuntimeError, match="marketplace add"):
            CodexRenderer().render(manifest, target)


def test_codex_native_plugin_add_warns_on_nonzero(tmp_path, capsys):
    """A nonzero `plugin add` warns loud (does not raise) — "already installed"
    on re-sync is benign, unlike a failed marketplace add.
    """
    manifest, _ = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    def fake_run(argv, **kwargs):
        if argv[:3] == ["codex", "plugin", "add"]:
            return MagicMock(returncode=1, stderr="boom", stdout="")
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        CodexRenderer().render(manifest, target)  # must not raise

    err = capsys.readouterr().err
    assert "boom" in err and "codex" in err


def test_non_codex_native_descriptor_is_ignored(tmp_path):
    """A native descriptor with codex_native=False triggers no codex CLI calls."""
    manifest, _ = _make_codex_native_marketplace(tmp_path)
    manifest.native_plugins[0]["codex_native"] = False
    manifest.native_plugins[0]["claude_native"] = True
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    assert mock_run.call_count == 0, (
        "claude_native-only descriptor must not drive codex CLI installs"
    )


# ─── codex_native hardening: name/marketplace divergence, expansion, order ──
# marketplace_name comes from marketplace.json's `name`, which can diverge from
# the registry key (`name`) — exactly as test_claude_native_plugins covers for
# the claude path. The codex CLI args mix the two (`{name}@{marketplace_name}`,
# `marketplace remove {marketplace_name}`); these tests pin which value lands in
# which argument so a name<->marketplace_name swap can't pass silently.


def _codex_native_manifest(name, marketplace_name, market_root):
    return Manifest(
        name="base",
        native_plugins=[{
            "name": name,
            "claude_native": False,
            "codex_native": True,
            "marketplace_root": str(market_root),
            "marketplace_name": marketplace_name,
            "description": "Test plugin",
        }],
    )


def test_codex_native_install_distinguishes_name_from_marketplace(tmp_path):
    """plugin add uses `<name>@<marketplace_name>` with the two values kept
    distinct — guards against swapping registry key and marketplace name."""
    market_root = tmp_path / "mkt"
    market_root.mkdir()
    manifest = _codex_native_manifest("milknado", "acme-market", market_root)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    calls = [c.args[0] for c in mock_run.call_args_list if c.args]
    assert ["codex", "plugin", "add", "milknado@acme-market"] in calls, (
        f"plugin add must be <name>@<marketplace_name>, got: {calls}"
    )
    # The wrong-way-round form must NOT appear.
    assert ["codex", "plugin", "add", "acme-market@milknado"] not in calls


def test_codex_native_clean_removes_by_marketplace_name(tmp_path):
    """clean() removes the plugin by `<name>@<marketplace_name>` and the
    marketplace by `<marketplace_name>` (not the registry key)."""
    market_root = tmp_path / "mkt"
    market_root.mkdir()
    manifest = _codex_native_manifest("milknado", "acme-market", market_root)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().clean(manifest, target)

    calls = [c.args[0] for c in mock_run.call_args_list if c.args]
    assert ["codex", "plugin", "remove", "milknado@acme-market"] in calls, (
        f"plugin remove must be <name>@<marketplace_name>, got: {calls}"
    )
    assert ["codex", "plugin", "marketplace", "remove", "acme-market"] in calls, (
        f"marketplace remove must use marketplace_name, got: {calls}"
    )
    assert ["codex", "plugin", "marketplace", "remove", "milknado"] not in calls


def test_codex_native_marketplace_root_is_expanded(tmp_path, monkeypatch):
    """`~` / `$VAR` in marketplace_root are expanded before reaching the CLI.

    Every other test uses an already-absolute tmp_path, so the
    expandvars/expanduser call is a silent no-op there. This drives a real
    unexpanded root and asserts the literal `~`/`$VAR` never reaches codex.
    """
    real_root = tmp_path / "caveroot" / "mkt"
    real_root.mkdir(parents=True)
    monkeypatch.setenv("AP_TEST_CAVE", str(tmp_path / "caveroot"))
    manifest = _codex_native_manifest(
        "milknado", "milknado", "$AP_TEST_CAVE/mkt"
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    market_calls = [
        c.args[0] for c in mock_run.call_args_list
        if c.args and c.args[0][:4] == ["codex", "plugin", "marketplace", "add"]
    ]
    assert market_calls, "no marketplace add call"
    passed = market_calls[0][-1]
    assert "$AP_TEST_CAVE" not in passed, f"$VAR not expanded: {passed}"
    assert passed == str(real_root), f"expected expanded root, got: {passed}"


def test_codex_native_marketplace_add_precedes_plugin_add(tmp_path):
    """marketplace add must run before plugin add — codex can't install a
    plugin from a marketplace it hasn't registered yet."""
    manifest, _ = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    calls = [c.args[0] for c in mock_run.call_args_list if c.args]
    market_idx = next(
        i for i, a in enumerate(calls)
        if a[:4] == ["codex", "plugin", "marketplace", "add"]
    )
    add_idx = next(
        i for i, a in enumerate(calls)
        if a[:3] == ["codex", "plugin", "add"]
    )
    assert market_idx < add_idx, (
        f"marketplace add must precede plugin add, got order: {calls}"
    )


def test_codex_native_clean_remove_order(tmp_path):
    """clean() removes the plugin before removing its marketplace."""
    manifest, _ = _make_codex_native_marketplace(tmp_path)
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().clean(manifest, target)

    calls = [c.args[0] for c in mock_run.call_args_list if c.args]
    remove_idx = next(
        i for i, a in enumerate(calls)
        if a[:3] == ["codex", "plugin", "remove"]
    )
    mkt_remove_idx = next(
        i for i, a in enumerate(calls)
        if a[:4] == ["codex", "plugin", "marketplace", "remove"]
    )
    assert remove_idx < mkt_remove_idx, (
        f"plugin remove must precede marketplace remove, got order: {calls}"
    )


def test_codex_native_installs_only_codex_native_in_mixed_manifest(tmp_path):
    """With a codex_native entry next to a claude_native-only entry, only the
    codex_native plugin drives codex CLI installs."""
    market_root = tmp_path / "mkt"
    market_root.mkdir()
    manifest = Manifest(
        name="base",
        native_plugins=[
            {
                "name": "claude-only",
                "claude_native": True,
                "codex_native": False,
                "marketplace_root": str(market_root),
                "marketplace_name": "claude-only",
                "description": "",
            },
            {
                "name": "milknado",
                "claude_native": False,
                "codex_native": True,
                "marketplace_root": str(market_root),
                "marketplace_name": "milknado",
                "description": "",
            },
        ],
    )
    target = tmp_path / "home"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0)
        CodexRenderer().render(manifest, target)

    added = [
        c.args[0][-1] for c in mock_run.call_args_list
        if c.args and c.args[0][:3] == ["codex", "plugin", "add"]
    ]
    assert added == ["milknado@milknado"], (
        f"only the codex_native plugin must be installed, got: {added}"
    )
    assert not any(
        "claude-only" in arg
        for c in mock_run.call_args_list if c.args
        for arg in c.args[0]
    ), "claude_native-only plugin must not touch the codex CLI"
