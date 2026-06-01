"""test_renderer_cursor.py — parity tests for the Cursor renderer.

Ports tests/agent-profile-renderers-cursor.bats and adds a multi-hook
fixture that pins the ``_source_dir`` projection fix: two cursor hooks
from *different* source dirs must each copy the right script. Under the
old bash positional re-query the script→source mapping was re-derived
from a duplicated filter; this port threads ``_source_dir`` through the
projection, and the multi-hook test asserts each landed script's bytes
come from its own source.

Golden bytes (``fixtures/golden/cursor/multi_hook/``) were captured by
running the bash ``cursor_render`` against the same multi-hook manifest.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from agent_profile.parse import Manifest
from agent_profile.renderers.cursor import CursorRenderer

GOLD = Path(__file__).parent / "fixtures" / "golden" / "cursor" / "multi_hook"


def _src(tmp_path: Path, name: str) -> Path:
    d = tmp_path / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def _stamp(items: list[dict], source_dir: Path) -> list[dict]:
    """Attach ``_source_dir`` to each item (parity with the bats `merged`
    helper, which stamps every section item with the profile dir)."""
    return [{**it, "_source_dir": str(source_dir)} for it in items]


# ─── multi-hook: the _source_dir projection fix ──────────────────────


@pytest.fixture
def multi_hook(tmp_path):
    """Build the multi-hook manifest used to capture the golden: two cursor
    hooks from different source dirs, plus agent/command/skill/mcp surfaces.
    Returns (manifest, target)."""
    src_a = _src(tmp_path, "srcA")
    src_b = _src(tmp_path, "srcB")
    target = _src(tmp_path, "target")

    (src_a / "hooks").mkdir()
    (src_b / "hooks").mkdir()
    (src_a / "agents").mkdir()
    (src_a / "commands").mkdir()
    (src_a / "skills" / "sk").mkdir(parents=True)

    (src_a / "hooks" / "a.sh").write_text('#!/bin/bash\necho "hook from A"\n')
    (src_b / "hooks" / "b.sh").write_text('#!/bin/bash\necho "hook from B"\n')
    (src_a / "agents" / "a.md").write_text("agent body content\n")
    (src_a / "commands" / "c.md").write_text("command body content\n")
    (src_a / "skills" / "sk" / "SKILL.md").write_text("skill content\n")

    manifest = Manifest(
        name="p1",
        description="multi-hook cursor fixture",
        mcps=_stamp(
            [
                {"name": "foo", "command": "npx", "args": ["-y", "foo-mcp"], "harnesses": ["cursor"]},
                {"name": "bar", "command": "uvx", "harnesses": ["cursor"], "env": {"KEY": "v"}},
            ],
            src_a,
        ),
        agents=_stamp(
            [
                {
                    "name": "a",
                    "description": "agent desc",
                    "body_path": "agents/a.md",
                    "tools": ["read", "write"],
                    "models": {"cursor": "sonnet-4-5"},
                }
            ],
            src_a,
        ),
        skills=_stamp([{"name": "sk", "path": "skills/sk"}], src_a),
        commands=_stamp(
            [
                {
                    "name": "c",
                    "description": "cmd desc",
                    "body_path": "commands/c.md",
                    "models": {"cursor": "haiku"},
                }
            ],
            src_a,
        ),
        hooks=[
            {"event": "beforeShellExecution", "matcher": "", "script": "hooks/a.sh", "harnesses": ["cursor"], "_source_dir": str(src_a)},
            {"event": "afterFileEdit", "matcher": "*.rs", "script": "hooks/b.sh", "harnesses": ["cursor"], "_source_dir": str(src_b)},
        ],
        settings={},
    )
    return manifest, target


def test_multi_hook_each_script_maps_to_its_own_source_dir(multi_hook):
    """THE FIX: two cursor hooks from different source dirs each copy the
    RIGHT script. A positional re-query that mismapped index→source would
    land B's bytes under a.sh (or fail to find the file). Asserting the
    landed bytes per script proves source-dir is threaded correctly."""
    manifest, target = multi_hook
    CursorRenderer().render(manifest, target)

    a = (target / ".cursor" / "hooks" / "a.sh").read_text()
    b = (target / ".cursor" / "hooks" / "b.sh").read_text()
    assert a == GOLD.joinpath("hook_a.sh").read_text()
    assert b == GOLD.joinpath("hook_b.sh").read_text()
    # Cross-check the bytes are not swapped: each carries its own marker.
    assert "hook from A" in a and "hook from B" not in a
    assert "hook from B" in b and "hook from A" not in b


def test_multi_hook_hooks_json_matches_golden(multi_hook):
    manifest, target = multi_hook
    CursorRenderer().render(manifest, target)
    written = (target / ".cursor" / "hooks.json").read_text()
    assert written == GOLD.joinpath("hooks.json").read_text()


def test_multi_hook_mcp_json_matches_golden(multi_hook):
    manifest, target = multi_hook
    CursorRenderer().render(manifest, target)
    written = (target / ".cursor" / "mcp.json").read_text()
    assert written == GOLD.joinpath("mcp.json").read_text()


def test_multi_hook_command_matches_golden(multi_hook):
    manifest, target = multi_hook
    CursorRenderer().render(manifest, target)
    written = (target / ".cursor" / "commands" / "c.md").read_text()
    assert written == GOLD.joinpath("command_c.md").read_text()


def test_multi_hook_cursor_agent_override_matches_golden(multi_hook):
    manifest, target = multi_hook
    CursorRenderer().render(manifest, target)
    written = (target / ".cursor" / "agents" / "a.md").read_text()
    assert written == GOLD.joinpath("cursor_agent_a.md").read_text()


def test_multi_hook_shared_claude_agent_matches_golden(multi_hook):
    manifest, target = multi_hook
    CursorRenderer().render(manifest, target)
    written = (target / ".claude" / "agents" / "a.md").read_text()
    assert written == GOLD.joinpath("claude_agent_a.md").read_text()


def test_multi_hook_skill_tree_copied_to_shared(multi_hook):
    manifest, target = multi_hook
    CursorRenderer().render(manifest, target)
    assert (target / ".agents" / "skills" / "sk" / "SKILL.md").is_file()
    assert (target / ".agents" / "skills" / "sk" / "SKILL.md").read_text() == "skill content\n"


# ─── hand-crafted manifest cases (ported from the bats) ──────────────


def _manifest(tmp_path, **sections) -> tuple[Manifest, Path, Path]:
    src = _src(tmp_path, "src")
    target = _src(tmp_path, "target")
    stamped = {}
    for key in ("mcps", "agents", "skills", "commands"):
        stamped[key] = _stamp(sections.get(key, []), src)
    # hooks may carry their own _source_dir; default to src when absent.
    stamped["hooks"] = [
        h if "_source_dir" in h else {**h, "_source_dir": str(src)}
        for h in sections.get("hooks", [])
    ]
    m = Manifest(
        name="p1",
        description="test",
        settings=sections.get("settings", {}),
        **stamped,
    )
    return m, target, src


def test_hook_with_cursor_harness_lands_in_hooks_json(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        hooks=[{"event": "beforeShellExecution", "matcher": "", "script": "hooks/h.sh", "harnesses": ["cursor"]}],
    )
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\necho hi\n")
    CursorRenderer().render(m, target)
    assert (target / ".cursor" / "hooks.json").is_file()
    landed = target / ".cursor" / "hooks" / "h.sh"
    assert landed.is_file()
    assert landed.stat().st_mode & 0o111  # executable
    content = (target / ".cursor" / "hooks.json").read_text()
    assert "beforeShellExecution" in content
    assert ".cursor/hooks/h.sh" in content


def test_claude_only_hook_produces_no_hooks_json(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        hooks=[{"event": "PreToolUse", "script": "hooks/h.sh", "harnesses": ["claude"]}],
    )
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\n")
    CursorRenderer().render(m, target)
    assert not (target / ".cursor" / "hooks.json").exists()


def test_hook_with_default_membership_is_claude_only(tmp_path):
    """A hook with no `harnesses` defaults to [claude] — cursor excluded,
    so no hooks.json (parity with bash `.harnesses // ["claude"]`)."""
    m, target, src = _manifest(
        tmp_path,
        hooks=[{"event": "PreToolUse", "script": "hooks/h.sh"}],
    )
    (src / "hooks").mkdir()
    (src / "hooks" / "h.sh").write_text("#!/bin/bash\n")
    CursorRenderer().render(m, target)
    assert not (target / ".cursor" / "hooks.json").exists()


def test_missing_hook_script_raises(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        hooks=[{"event": "PreToolUse", "script": "hooks/nope.sh", "harnesses": ["cursor"]}],
    )
    with pytest.raises(FileNotFoundError):
        CursorRenderer().render(m, target)


def test_mcp_entries_land_as_mcp_servers(tmp_path):
    m, target, _ = _manifest(
        tmp_path,
        mcps=[{"name": "foo", "command": "npx", "args": ["-y", "foo-mcp"], "harnesses": ["cursor"]}],
    )
    CursorRenderer().render(m, target)
    content = (target / ".cursor" / "mcp.json").read_text()
    assert "mcpServers" in content
    assert '"foo"' in content
    assert "foo-mcp" in content


def test_mcp_default_membership_includes_cursor(tmp_path):
    """An MCP with no `harnesses` defaults to [claude,codex,opencode,cursor]
    — cursor IS in the default set, so it lands."""
    m, target, _ = _manifest(
        tmp_path,
        mcps=[{"name": "foo", "command": "npx"}],
    )
    CursorRenderer().render(m, target)
    assert (target / ".cursor" / "mcp.json").is_file()
    assert '"foo"' in (target / ".cursor" / "mcp.json").read_text()


def test_mcp_entry_args_default_empty_and_env_preserved(tmp_path):
    """Cursor's bash always emits `args` (default []) and appends `env`
    only when present."""
    m, target, _ = _manifest(
        tmp_path,
        mcps=[
            {"name": "noargs", "command": "uvx", "env": {"K": "v"}, "harnesses": ["cursor"]},
        ],
    )
    CursorRenderer().render(m, target)
    import json

    data = json.loads((target / ".cursor" / "mcp.json").read_text())
    entry = data["mcpServers"]["noargs"]
    assert entry == {"command": "uvx", "args": [], "env": {"K": "v"}}


def test_mcp_secret_var_dropped_and_envfile_added(tmp_path, monkeypatch):
    """Criterion 8: Cursor is GUI-launched, so a ``${VAR}`` in ``env`` does not
    resolve against the shell. A secret-bearing (``${VAR}``-referencing) server
    drops the ``${VAR}`` env entry and gains ``envFile`` = abs ``.env``; plain
    literals remain in ``env``. No secret on disk."""
    monkeypatch.setenv("DOTFILES_DIR", "/abs/dots")
    m, target, _ = _manifest(
        tmp_path,
        mcps=[
            {
                "name": "context7",
                "command": "npx",
                "args": ["-y", "@upstash/context7-mcp"],
                "env": {
                    "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}",
                    "SERENA_MUX_HARNESS": "cursor",
                },
                "harnesses": ["cursor"],
            }
        ],
    )
    CursorRenderer().render(m, target)
    import json

    raw = (target / ".cursor" / "mcp.json").read_text()
    entry = json.loads(raw)["mcpServers"]["context7"]
    # The ${VAR} entry is gone; the plain literal stays.
    assert entry["env"] == {"SERENA_MUX_HARNESS": "cursor"}
    assert entry["envFile"] == "/abs/dots/.env"
    assert "${CONTEXT7_API_KEY}" not in raw


def test_mcp_no_var_ref_keeps_env_no_envfile(tmp_path, monkeypatch):
    """A server whose env has NO ``${VAR}`` reference keeps its plain ``env``
    and gains no ``envFile`` — envFile is added only when a ${VAR} entry was
    dropped."""
    monkeypatch.setenv("DOTFILES_DIR", "/abs/dots")
    m, target, _ = _manifest(
        tmp_path,
        mcps=[
            {
                "name": "plain",
                "command": "uvx",
                "env": {"SERENA_MUX_HARNESS": "cursor"},
                "harnesses": ["cursor"],
            }
        ],
    )
    CursorRenderer().render(m, target)
    import json

    entry = json.loads((target / ".cursor" / "mcp.json").read_text())[
        "mcpServers"
    ]["plain"]
    assert entry["env"] == {"SERENA_MUX_HARNESS": "cursor"}
    assert "envFile" not in entry


def test_mcp_all_env_vars_dropped_omits_env_key(tmp_path, monkeypatch):
    """When every env entry is a ${VAR} ref, ``env`` is omitted entirely (no
    empty ``env: {}`` left dangling) and ``envFile`` carries the lookup."""
    monkeypatch.setenv("DOTFILES_DIR", "/abs/dots")
    m, target, _ = _manifest(
        tmp_path,
        mcps=[
            {
                "name": "tavily",
                "command": "npx",
                "env": {"TAVILY_API_KEY": "${TAVILY_API_KEY}"},
                "harnesses": ["cursor"],
            }
        ],
    )
    CursorRenderer().render(m, target)
    import json

    entry = json.loads((target / ".cursor" / "mcp.json").read_text())[
        "mcpServers"
    ]["tavily"]
    assert "env" not in entry
    assert entry["envFile"] == "/abs/dots/.env"


def test_mcp_envfile_falls_back_to_home_dotfiles_when_dotfiles_dir_unset(
    tmp_path, monkeypatch
):
    """Boundary: with ``DOTFILES_DIR`` UNSET, ``envFile`` resolves to the
    ``~/Dev/dotfiles/.env`` fallback (the discover.py pattern) — never an
    empty or ``/.env`` path. A broken ``or`` fallback would silently point
    Cursor at the wrong .env and the secret would never load."""
    monkeypatch.delenv("DOTFILES_DIR", raising=False)
    monkeypatch.setenv("HOME", "/home/user")
    m, target, _ = _manifest(
        tmp_path,
        mcps=[
            {
                "name": "tavily",
                "command": "npx",
                "env": {"TAVILY_API_KEY": "${TAVILY_API_KEY}"},
                "harnesses": ["cursor"],
            }
        ],
    )
    CursorRenderer().render(m, target)
    import json

    entry = json.loads((target / ".cursor" / "mcp.json").read_text())[
        "mcpServers"
    ]["tavily"]
    assert entry["envFile"] == "/home/user/Dev/dotfiles/.env"


def test_mcp_renamed_var_ref_fails_loud(tmp_path, monkeypatch):
    """A ``${VAR}`` env value that is NOT an exact self-reference — a renamed
    key (``API_KEY: "${TOKEN}"``) — cannot be represented by Cursor's
    ``envFile`` (which loads vars by their own names), so the renderer fails
    loud rather than silently dropping the key and emitting a broken server
    entry."""
    monkeypatch.setenv("DOTFILES_DIR", "/abs/dots")
    m, target, _ = _manifest(
        tmp_path,
        mcps=[
            {
                "name": "renamed",
                "command": "npx",
                "env": {"API_KEY": "${TODOIST_API_KEY}"},
                "harnesses": ["cursor"],
            }
        ],
    )
    with pytest.raises(ValueError, match="not an exact self-reference"):
        CursorRenderer().render(m, target)


def test_mcp_embedded_var_ref_fails_loud(tmp_path, monkeypatch):
    """An embedded ``${VAR}`` (surrounded by other text) is likewise
    unrepresentable by ``envFile`` and fails loud rather than silently
    dropping the key."""
    monkeypatch.setenv("DOTFILES_DIR", "/abs/dots")
    m, target, _ = _manifest(
        tmp_path,
        mcps=[
            {
                "name": "embedded",
                "command": "npx",
                "env": {"URL": "https://x/${TOKEN}/y"},
                "harnesses": ["cursor"],
            }
        ],
    )
    with pytest.raises(ValueError, match="not an exact self-reference"):
        CursorRenderer().render(m, target)


def test_mcp_merge_preserves_user_entries(tmp_path):
    m, target, _ = _manifest(
        tmp_path,
        mcps=[{"name": "foo", "command": "npx", "args": ["-y", "foo-mcp"], "harnesses": ["cursor"]}],
    )
    cursor_dir = target / ".cursor"
    cursor_dir.mkdir(parents=True)
    (cursor_dir / "mcp.json").write_text(
        '{"mcpServers": {"user-mcp": {"command": "uvx", "args": ["user-thing"]}}, "extraKey": "preserved"}'
    )
    CursorRenderer().render(m, target)
    content = (cursor_dir / "mcp.json").read_text()
    assert "user-mcp" in content
    assert '"foo"' in content
    assert "extraKey" in content


def test_cursor_clean_removes_only_profile_entries(tmp_path):
    m, target, _ = _manifest(
        tmp_path,
        mcps=[{"name": "foo", "command": "x", "harnesses": ["cursor"]}],
    )
    cursor_dir = target / ".cursor"
    cursor_dir.mkdir(parents=True)
    (cursor_dir / "mcp.json").write_text(
        '{"mcpServers": {"foo": {"command": "x"}, "user-mcp": {"command": "y"}}, "extraKey": "preserved"}'
    )
    CursorRenderer().clean(m, target)
    content = (cursor_dir / "mcp.json").read_text()
    assert '"foo"' not in content
    assert "user-mcp" in content
    assert "extraKey" in content


def test_cursor_clean_removes_bootstrapped_empty_file(tmp_path):
    """If the profile was the sole writer and removal collapses the file to
    `{}`, clean deletes it (parity with bash rm)."""
    m, target, _ = _manifest(
        tmp_path,
        mcps=[{"name": "foo", "command": "x", "harnesses": ["cursor"]}],
    )
    cursor_dir = target / ".cursor"
    cursor_dir.mkdir(parents=True)
    (cursor_dir / "mcp.json").write_text('{"mcpServers": {"foo": {"command": "x"}}}')
    CursorRenderer().clean(m, target)
    assert not (cursor_dir / "mcp.json").exists()


def test_models_cursor_inherit_emits_no_override_file(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        agents=[{"name": "a", "description": "d", "body_path": "agents/a.md", "models": {"cursor": "inherit"}}],
    )
    (src / "agents").mkdir()
    (src / "agents" / "a.md").write_text("agent body\n")
    CursorRenderer().render(m, target)
    assert (target / ".claude" / "agents" / "a.md").is_file()
    assert not (target / ".cursor" / "agents" / "a.md").exists()


def test_models_cursor_value_emits_override_with_model_frontmatter(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        agents=[{"name": "a", "description": "d", "body_path": "agents/a.md", "models": {"cursor": "sonnet-4-5"}}],
    )
    (src / "agents").mkdir()
    (src / "agents" / "a.md").write_text("agent body\n")
    CursorRenderer().render(m, target)
    override = target / ".cursor" / "agents" / "a.md"
    assert override.is_file()
    text = override.read_text()
    assert "model: sonnet-4-5" in text
    assert "agent body" in text


def test_command_with_model_includes_model_frontmatter(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        commands=[{"name": "c", "description": "runs", "body_path": "commands/c.md", "models": {"cursor": "haiku"}}],
    )
    (src / "commands").mkdir()
    (src / "commands" / "c.md").write_text("command body\n")
    CursorRenderer().render(m, target)
    text = (target / ".cursor" / "commands" / "c.md").read_text()
    assert "description: runs" in text
    assert "model: haiku" in text
    assert "command body" in text


def test_command_with_inherit_omits_model_line(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        commands=[{"name": "c", "description": "runs", "body_path": "commands/c.md", "models": {"cursor": "inherit"}}],
    )
    (src / "commands").mkdir()
    (src / "commands" / "c.md").write_text("command body\n")
    CursorRenderer().render(m, target)
    text = (target / ".cursor" / "commands" / "c.md").read_text()
    assert "model:" not in text
    assert "description: runs" in text


def test_permissions_skipped_with_warning(tmp_path, capsys):
    m, target, _ = _manifest(
        tmp_path,
        settings={"permissions_allow": ["Bash(cargo:*)"]},
    )
    CursorRenderer().render(m, target)
    err = capsys.readouterr().err
    assert "permissions are UI-only" in err
    assert not (target / ".cursor" / "permissions.json").exists()
    assert not (target / ".cursor" / "settings.json").exists()


def test_render_tracks_all_written_files(tmp_path):
    m, target, src = _manifest(
        tmp_path,
        agents=[{"name": "a", "description": "", "body_path": "agents/a.md"}],
        commands=[{"name": "c", "description": "", "body_path": "commands/c.md"}],
        skills=[{"name": "sk", "path": "skills/sk"}],
    )
    (src / "agents").mkdir()
    (src / "commands").mkdir()
    (src / "skills" / "sk").mkdir(parents=True)
    (src / "agents" / "a.md").write_text("agent\n")
    (src / "commands" / "c.md").write_text("cmd\n")
    (src / "skills" / "sk" / "SKILL.md").write_text("skill\n")
    tracked = CursorRenderer().render(m, target)
    assert ".claude/agents/a.md" in tracked
    assert ".cursor/commands/c.md" in tracked
    assert ".agents/skills/sk" in tracked
