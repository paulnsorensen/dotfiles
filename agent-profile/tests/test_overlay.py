"""test_overlay.py — launch-overlay / isolation (spec curd 6).

An ``isolated: true`` profile reproduces the retired ``ccp`` launch
semantics inside ``ap``: a closed-world ``claude`` invocation built from
ephemeral generated files (a strict ``.mcp.json`` from the profile's MCPs
only + a ``settings.json`` carrying ``permissions_deny``) plus the
``--setting-sources ""`` / ``--tools`` / ``--append-system-prompt-file``
flags, env injection and verbatim ``extra_args``.

These tests assert the assembled ``execvp`` argv + the generated file
contents, monkeypatching ``os.execvp`` so nothing actually launches.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_profile import cli, overlay
from agent_profile.discover import find_profile_dir
from agent_profile.parse import Manifest, parse_manifest
from tests.conftest import write_profile

# Repo root: agent-profile/tests/test_overlay.py → ../../ is the dotfiles clone.
REPO_ROOT = Path(__file__).resolve().parents[2]


def _capture_exec(monkeypatch):
    """Patch os.execvp + env injection so launch is observable. Returns a
    dict that fake_exec fills with file/args/env."""
    rec: dict = {}

    def fake_exec(file, args):
        rec["file"] = file
        rec["args"] = args
        raise SystemExit(0)

    monkeypatch.setattr(cli.os, "execvp", fake_exec)
    return rec


def write_isolated_todo(root):
    write_profile(
        root,
        "todo",
        "name: todo\n"
        "description: Closed-world Todoist\n"
        "isolated: true\n"
        "system_prompt: CLAUDE.md\n"
        "tools: [Skill, Read, AskUserQuestion, \"mcp__todoist__*\"]\n"
        "permissions_deny: [Edit, Write, NotebookEdit]\n"
        "env:\n"
        "  ENABLE_CLAUDEAI_MCP_SERVERS: \"true\"\n"
        "extra_args: [--dangerously-skip-permissions]\n"
        "mcps:\n"
        "  - name: todoist\n"
        "    command: npx\n"
        "    args: [-y, \"@doist/todoist-ai\"]\n",
        {"CLAUDE.md": "Todoist system prompt\n"},
    )


# ─── manifest threading ──────────────────────────────────────────────


def test_manifest_carries_isolation_fields(env):
    write_isolated_todo(env.profiles)
    from agent_profile.discover import find_profile_dir
    from agent_profile.parse import parse_manifest

    m = parse_manifest(find_profile_dir("todo"))
    assert m.isolated is True
    assert m.system_prompt == "CLAUDE.md"
    assert m.tools == ["Skill", "Read", "AskUserQuestion", "mcp__todoist__*"]
    assert m.permissions_deny == ["Edit", "Write", "NotebookEdit"]
    assert m.env == {"ENABLE_CLAUDEAI_MCP_SERVERS": "true"}
    assert m.extra_args == ["--dangerously-skip-permissions"]


def test_non_isolated_defaults(env):
    write_profile(
        env.profiles,
        "plain",
        "name: plain\ndescription: plain\n",
    )
    from agent_profile.discover import find_profile_dir
    from agent_profile.parse import parse_manifest

    m = parse_manifest(find_profile_dir("plain"))
    assert m.isolated is False
    assert m.system_prompt is None
    assert m.tools == []
    assert m.permissions_deny == []
    assert m.permissions_allow == []
    assert m.enabled_plugins == {}
    assert m.env == {}
    assert m.extra_args == []


# ─── flag assembly ───────────────────────────────────────────────────


def test_isolated_launch_assembles_ccp_flags(env, monkeypatch, tmp_path):
    write_isolated_todo(env.profiles)
    rec = _capture_exec(monkeypatch)

    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "todo", "--target", str(env.target)])

    args = rec["args"]
    assert rec["file"] == "claude"
    assert args[0] == "claude"
    # strict-mcp-config + a generated --mcp-config pointing at a real file
    assert "--strict-mcp-config" in args
    mc_idx = args.index("--mcp-config")
    mcp_path = args[mc_idx + 1]
    servers = json.loads(Path(mcp_path).read_text())["mcpServers"]
    assert set(servers) == {"todoist"}
    assert servers["todoist"]["command"] == "npx"
    # closed settings world
    ss_idx = args.index("--setting-sources")
    assert args[ss_idx + 1] == ""
    # tools whitelist (comma-joined)
    t_idx = args.index("--tools")
    assert args[t_idx + 1] == "Skill,Read,AskUserQuestion,mcp__todoist__*"
    # system prompt append points at the profile's CLAUDE.md
    sp_idx = args.index("--append-system-prompt-file")
    assert args[sp_idx + 1].endswith("/CLAUDE.md")
    assert Path(args[sp_idx + 1]).read_text() == "Todoist system prompt\n"
    # generated settings carry permissions.deny
    set_idx = args.index("--settings")
    settings = json.loads(Path(args[set_idx + 1]).read_text())
    assert settings["permissions"]["deny"] == ["Edit", "Write", "NotebookEdit"]
    # extra_args appended verbatim
    assert "--dangerously-skip-permissions" in args


def test_isolated_launch_injects_env(env, monkeypatch):
    write_isolated_todo(env.profiles)
    _capture_exec(monkeypatch)

    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "todo", "--target", str(env.target)])

    assert cli.os.environ.get("ENABLE_CLAUDEAI_MCP_SERVERS") == "true"


def test_isolated_launch_passthrough_appended_last(env, monkeypatch):
    write_isolated_todo(env.profiles)
    rec = _capture_exec(monkeypatch)

    with pytest.raises(SystemExit):
        cli.main(
            ["launch", "claude", "todo", "--target", str(env.target), "--", "--resume"]
        )
    args = rec["args"]
    assert args[-1] == "--resume"
    # passthrough lands after the verbatim extra_args
    assert args.index("--dangerously-skip-permissions") < args.index("--resume")


def test_isolated_launch_non_claude_harness_rejected(env, capsys):
    write_isolated_todo(env.profiles)
    rc = cli.main(["launch", "codex", "todo", "--target", str(env.target)])
    assert rc == 1
    assert "isolated" in capsys.readouterr().err.lower()


def test_isolated_without_system_prompt_omits_flag(env, monkeypatch):
    write_profile(
        env.profiles,
        "bare",
        "name: bare\nisolated: true\n"
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "bare", "--target", str(env.target)])
    assert "--append-system-prompt-file" not in rec["args"]


def test_isolated_without_tools_omits_flag(env, monkeypatch):
    write_profile(
        env.profiles,
        "bare",
        "name: bare\nisolated: true\n"
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "bare", "--target", str(env.target)])
    assert "--tools" not in rec["args"]


def test_isolated_without_deny_omits_settings(env, monkeypatch):
    write_profile(
        env.profiles,
        "bare",
        "name: bare\nisolated: true\n"
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "bare", "--target", str(env.target)])
    # no permissions_deny => no generated --settings
    assert "--settings" not in rec["args"]
    # but a closed MCP world still applies
    assert "--strict-mcp-config" in rec["args"]
    assert "--setting-sources" in rec["args"]


def test_isolated_permissions_allow_restored_in_settings(env, monkeypatch):
    """The migrated allow-list (ccp settings-merge parity) lands in the
    generated settings.json so the profile's own MCP auto-approves."""
    write_profile(
        env.profiles,
        "allowy",
        "name: allowy\nisolated: true\n"
        'permissions_allow:\n  - "mcp__notion__*"\n'
        "permissions_deny: [Edit, Write]\n"
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "allowy", "--target", str(env.target)])
    args = rec["args"]
    settings = json.loads(Path(args[args.index("--settings") + 1]).read_text())
    assert settings["permissions"]["allow"] == ["mcp__notion__*"]
    assert settings["permissions"]["deny"] == ["Edit", "Write"]


def test_isolated_only_allow_emits_settings(env, monkeypatch):
    """A profile with an allow-list but no deny-list still emits --settings
    (regression: the gate used to fire on permissions_deny only)."""
    write_profile(
        env.profiles,
        "allowonly",
        "name: allowonly\nisolated: true\n"
        'permissions_allow:\n  - "Bash(rtk:*)"\n'
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "allowonly", "--target", str(env.target)])
    args = rec["args"]
    assert "--settings" in args
    settings = json.loads(Path(args[args.index("--settings") + 1]).read_text())
    assert settings["permissions"]["allow"] == ["Bash(rtk:*)"]
    assert "deny" not in settings["permissions"]


def test_isolated_enabled_plugins_in_settings(env, monkeypatch):
    """A profile's enabled_plugins (ccp settings-merge parity) lands in the
    generated settings.json under enabledPlugins so the curated plugin set
    survives the closed-world launch."""
    write_profile(
        env.profiles,
        "plugy",
        "name: plugy\nisolated: true\n"
        "enabled_plugins:\n"
        '  "frontend-design@claude-plugins-official": true\n'
        '  "skill-creator@claude-plugins-official": false\n'
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "plugy", "--target", str(env.target)])
    args = rec["args"]
    assert "--settings" in args
    settings = json.loads(Path(args[args.index("--settings") + 1]).read_text())
    assert settings["enabledPlugins"] == {
        "frontend-design@claude-plugins-official": True,
        "skill-creator@claude-plugins-official": False,
    }
    assert "permissions" not in settings


# ─── overlay flag-builder unit (no exec) ─────────────────────────────


def test_isolated_mcp_env_resolved_from_dotenv(env, monkeypatch, tmp_path):
    """An inline profile MCP carrying ${VAR} resolves at launch from
    $DOTFILES_DIR/.env (spec D4), matching the retired gen-profile-mcp.sh."""
    dots = tmp_path / "dots"
    dots.mkdir()
    (dots / ".env").write_text("TODOIST_API_KEY=secret-token\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dots))

    write_profile(
        env.profiles,
        "td",
        "name: td\nisolated: true\n"
        "mcps:\n"
        "  - name: todoist\n"
        "    command: npx\n"
        "    args: [-y, \"@doist/todoist-ai\"]\n"
        "    env:\n"
        "      TODOIST_API_KEY: \"${TODOIST_API_KEY}\"\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "td", "--target", str(env.target)])
    args = rec["args"]
    mcp_path = args[args.index("--mcp-config") + 1]
    servers = json.loads(Path(mcp_path).read_text())["mcpServers"]
    assert servers["todoist"]["env"]["TODOIST_API_KEY"] == "secret-token"


def test_isolated_mcp_env_unset_fails_loud(env, monkeypatch, tmp_path, capsys):
    dots = tmp_path / "dots"
    dots.mkdir()  # no .env
    monkeypatch.setenv("DOTFILES_DIR", str(dots))
    write_profile(
        env.profiles,
        "td",
        "name: td\nisolated: true\n"
        "mcps:\n"
        "  - name: todoist\n"
        "    command: npx\n"
        "    env:\n"
        "      TODOIST_API_KEY: \"${TODOIST_API_KEY}\"\n",
    )
    rc = cli.main(["launch", "claude", "td", "--target", str(env.target)])
    assert rc == 1
    assert "TODOIST_API_KEY" in capsys.readouterr().err


def test_extra_args_expand_env(env, monkeypatch, tmp_path):
    """${VAR} in extra_args expands from the process env (e.g. DOTFILES_DIR),
    matching the retired launch.zsh which used $DOTFILES_DIR directly."""
    monkeypatch.setenv("DOTFILES_DIR", "/abs/dots")
    write_profile(
        env.profiles,
        "px",
        "name: px\nisolated: true\n"
        "extra_args:\n"
        "  - --plugin-dir\n"
        "  - ${DOTFILES_DIR}/claude/plugins/local/x\n"
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "px", "--target", str(env.target)])
    assert "/abs/dots/claude/plugins/local/x" in rec["args"]


def test_isolated_http_mcp_shape(env, monkeypatch):
    """An http-type MCP (notion) renders as {type, url}, not {command}."""
    write_profile(
        env.profiles,
        "nt",
        "name: nt\nisolated: true\n"
        "mcps:\n"
        "  - name: notion\n"
        "    type: http\n"
        "    url: https://mcp.notion.com/mcp\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "nt", "--target", str(env.target)])
    args = rec["args"]
    servers = json.loads(Path(args[args.index("--mcp-config") + 1]).read_text())[
        "mcpServers"
    ]
    assert servers["notion"] == {"type": "http", "url": "https://mcp.notion.com/mcp"}


def test_build_isolated_flags_unit(tmp_path):
    m = Manifest(
        name="todo",
        mcps=[{"name": "todoist", "command": "npx", "args": ["-y", "x"],
               "_source_dir": str(tmp_path)}],
        isolated=True,
        system_prompt="CLAUDE.md",
        tools=["Read", "Skill"],
        permissions_deny=["Edit"],
    )
    (tmp_path / "CLAUDE.md").write_text("sp\n")
    profile_dir = tmp_path
    flags, env = overlay.build_isolated_flags(m, profile_dir)
    assert "--strict-mcp-config" in flags
    assert "--setting-sources" in flags
    assert flags[flags.index("--tools") + 1] == "Read,Skill"
    assert env == {}


# ─── ccp-parity flag ORDERING (not just presence) ────────────────────


def test_flag_groups_emitted_in_spec_order(tmp_path):
    """The spec sketch pins the flag order; ccp consumed them positionally
    and a reorder is a silent regression. Presence-only assertions miss it,
    so lock the relative order of every major group when all are present:
    --strict-mcp-config/--mcp-config → --setting-sources → --tools →
    --append-system-prompt-file → --settings → extra_args."""
    m = Manifest(
        name="full",
        mcps=[{"name": "tilth", "command": "tilth",
               "_source_dir": str(tmp_path)}],
        isolated=True,
        system_prompt="CLAUDE.md",
        tools=["Read", "Skill"],
        permissions_deny=["Edit", "Write"],
        extra_args=["--dangerously-skip-permissions"],
    )
    (tmp_path / "CLAUDE.md").write_text("sp\n")
    flags, _ = overlay.build_isolated_flags(m, tmp_path)

    order = [
        flags.index("--strict-mcp-config"),
        flags.index("--mcp-config"),
        flags.index("--setting-sources"),
        flags.index("--tools"),
        flags.index("--append-system-prompt-file"),
        flags.index("--settings"),
        flags.index("--dangerously-skip-permissions"),
    ]
    assert order == sorted(order), f"flag groups out of spec order: {flags}"
    # --strict-mcp-config and its value are adjacent and lead the list.
    assert flags[0] == "--strict-mcp-config"
    assert flags[1] == "--mcp-config"
    # extra_args land after the generated --settings, never before it.
    assert flags.index("--dangerously-skip-permissions") > flags.index("--settings")


def test_extra_args_trail_all_generated_flags(tmp_path):
    """extra_args must come last so verbatim claude flags (and downstream
    passthrough) never get wedged between generated groups. Even with no
    tools/system_prompt/deny, extra_args sit after the closed-MCP +
    setting-sources block."""
    m = Manifest(
        name="px",
        mcps=[{"name": "tilth", "command": "tilth",
               "_source_dir": str(tmp_path)}],
        isolated=True,
        extra_args=["--verbose", "--foo"],
    )
    flags, _ = overlay.build_isolated_flags(m, tmp_path)
    assert flags[-2:] == ["--verbose", "--foo"]
    assert flags.index("--verbose") > flags.index("--setting-sources")


# ─── manifest threading: outermost-only, NOT merged from includes ────


def test_isolation_fields_not_inherited_from_include(env):
    """Isolation is a property of the profile you LAUNCH, not its includes.
    A child profile that include:s a base which itself declares isolation
    fields must NOT inherit them — the outer profile's own values (defaults
    when absent) win. parse.py threads these like name/description."""
    write_profile(
        env.profiles,
        "iso-base",
        "name: iso-base\n"
        "isolated: true\n"
        "system_prompt: BASE.md\n"
        "tools: [Read]\n"
        "permissions_deny: [Edit]\n"
        "env: { LEAK: \"1\" }\n"
        "extra_args: [--leaked]\n",
        {"BASE.md": "base prompt\n"},
    )
    write_profile(
        env.profiles,
        "child",
        "name: child\ndescription: includes iso-base\n"
        "include: [iso-base]\n",
    )
    from agent_profile.discover import find_profile_dir
    from agent_profile.parse import parse_manifest

    m = parse_manifest(find_profile_dir("child"))
    # The child declares none of the isolation fields → all defaults, despite
    # the included iso-base setting every one of them.
    assert m.isolated is False
    assert m.system_prompt is None
    assert m.tools == []
    assert m.permissions_deny == []
    assert m.env == {}
    assert m.extra_args == []


def test_outer_isolation_fields_win_over_include(env):
    """When BOTH outer and included profiles set isolation fields, the
    outermost wins outright (replace, not merge) — same rule as name."""
    write_profile(
        env.profiles,
        "inner",
        "name: inner\n"
        "isolated: true\n"
        "tools: [Bash, Grep]\n"
        "permissions_deny: [Write]\n"
        "env: { FROM_INNER: \"x\" }\n",
    )
    write_profile(
        env.profiles,
        "outer",
        "name: outer\n"
        "include: [inner]\n"
        "isolated: true\n"
        "tools: [Read]\n"
        "permissions_deny: [Edit]\n"
        "env: { FROM_OUTER: \"y\" }\n",
    )
    from agent_profile.discover import find_profile_dir
    from agent_profile.parse import parse_manifest

    m = parse_manifest(find_profile_dir("outer"))
    assert m.tools == ["Read"]
    assert m.permissions_deny == ["Edit"]
    assert m.env == {"FROM_OUTER": "y"}


# ─── http/sse MCP shape boundaries ───────────────────────────────────


def test_sse_mcp_shape(env, monkeypatch):
    """type: sse takes the http/sse code branch (not the command branch),
    preserving the declared type."""
    write_profile(
        env.profiles,
        "ev",
        "name: ev\nisolated: true\n"
        "mcps:\n"
        "  - name: events\n"
        "    type: sse\n"
        "    url: https://example.com/sse\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "ev", "--target", str(env.target)])
    servers = json.loads(
        Path(rec["args"][rec["args"].index("--mcp-config") + 1]).read_text()
    )["mcpServers"]
    assert servers["events"] == {"type": "sse", "url": "https://example.com/sse"}


def test_http_mcp_headers_passthrough(env, monkeypatch):
    """An http MCP carrying headers (e.g. an auth token) keeps them in the
    rendered record so the closed-world server can authenticate."""
    write_profile(
        env.profiles,
        "au",
        "name: au\nisolated: true\n"
        "mcps:\n"
        "  - name: authed\n"
        "    type: http\n"
        "    url: https://example.com/mcp\n"
        "    headers: { Authorization: \"Bearer xyz\" }\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "au", "--target", str(env.target)])
    servers = json.loads(
        Path(rec["args"][rec["args"].index("--mcp-config") + 1]).read_text()
    )["mcpServers"]
    assert servers["authed"] == {
        "type": "http",
        "url": "https://example.com/mcp",
        "headers": {"Authorization": "Bearer xyz"},
    }


def test_url_without_explicit_type_defaults_to_http(env, monkeypatch):
    """A bare url with no type still takes the http branch and defaults the
    type to http (the `mcp.get("url")` guard, not just the type guard)."""
    write_profile(
        env.profiles,
        "bu",
        "name: bu\nisolated: true\n"
        "mcps:\n"
        "  - name: bare\n"
        "    url: https://example.com/mcp\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "bu", "--target", str(env.target)])
    servers = json.loads(
        Path(rec["args"][rec["args"].index("--mcp-config") + 1]).read_text()
    )["mcpServers"]
    assert servers["bare"] == {"type": "http", "url": "https://example.com/mcp"}


# ─── env-resolution precedence in extra_args ─────────────────────────


def test_extra_args_process_env_overrides_dotenv(env, monkeypatch, tmp_path):
    """extra_args resolve from {**dotenv, **os.environ} — the process env
    wins over .env on a name collision, matching the retired launch.zsh
    which read live $DOTFILES_DIR from the shell, not the file."""
    dots = tmp_path / "dots"
    dots.mkdir()
    (dots / ".env").write_text("PLUGIN_ROOT=/from/dotenv\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dots))
    monkeypatch.setenv("PLUGIN_ROOT", "/from/process")
    write_profile(
        env.profiles,
        "ov",
        "name: ov\nisolated: true\n"
        "extra_args: [--plugin-dir, \"${PLUGIN_ROOT}/x\"]\n"
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "claude", "ov", "--target", str(env.target)])
    assert "/from/process/x" in rec["args"]
    assert "/from/dotenv/x" not in rec["args"]


def test_extra_args_unset_var_fails_loud(env, monkeypatch, tmp_path, capsys):
    """A ${VAR} in extra_args that resolves from neither .env nor the
    process env aborts the launch loudly instead of exec'ing a broken arg."""
    dots = tmp_path / "dots"
    dots.mkdir()
    monkeypatch.setenv("DOTFILES_DIR", str(dots))
    monkeypatch.delenv("WHO_KNOWS", raising=False)
    write_profile(
        env.profiles,
        "fl",
        "name: fl\nisolated: true\n"
        "extra_args: [--plugin-dir, \"${WHO_KNOWS}/x\"]\n"
        "mcps:\n  - name: tilth\n    command: tilth\n",
    )
    rc = cli.main(["launch", "claude", "fl", "--target", str(env.target)])
    assert rc == 1
    assert "WHO_KNOWS" in capsys.readouterr().err


# ─── migrated-profile fidelity (against the REAL shipped profiles) ───
#
# These lock the curd-8 migration of the retired ccp profiles. They build
# flags from the actual profiles/<name>/profile.yaml in the repo, so a future
# edit that weakens a security contract (review's deny list, todo's closed
# world) fails the suite. The CONTEXT7_API_KEY/etc. that review's context7 MCP
# references resolve from the repo .env at launch; we stub a .env so the build
# is hermetic and doesn't depend on the dev machine's real credentials.


def _hermetic_dotenv(monkeypatch, tmp_path):
    """Point DOTFILES_DIR at the real repo for discovery but override the
    dotenv loader to a stubbed mapping so MCP ${VAR} refs resolve without the
    machine's real .env. Returns nothing; mutates env + overlay._dotenv."""
    monkeypatch.setenv("DOTFILES_DIR", str(REPO_ROOT))
    # Discovery must resolve $DOTFILES_DIR/profiles, not a leaked sandbox root.
    monkeypatch.delenv("AP_EXTRA_SEARCH_PATHS", raising=False)
    stub = {
        "CONTEXT7_API_KEY": "stub-c7",
        "TAVILY_API_KEY": "stub-tv",
        "TODOIST_API_KEY": "stub-td",
    }
    monkeypatch.setattr(overlay, "_dotenv", lambda: stub)


def test_real_review_profile_locks_security_contract(monkeypatch, tmp_path):
    """The shipped review profile must keep: Edit/Write/NotebookEdit + every
    serena mutator + tilth_write denied; a read-only tool whitelist; a closed
    MCP world of exactly tilth + code-review-graph + context7."""
    _hermetic_dotenv(monkeypatch, tmp_path)
    pdir = find_profile_dir("review")
    assert pdir is not None, "real profiles/review not found"
    m = parse_manifest(pdir)
    assert m.isolated is True
    flags, _ = overlay.build_isolated_flags(m, pdir)

    settings_path = flags[flags.index("--settings") + 1]
    deny = set(json.loads(Path(settings_path).read_text())["permissions"]["deny"])
    for must_deny in (
        "Edit",
        "Write",
        "NotebookEdit",
        "mcp__tilth__tilth_write",
        "mcp__serena__replace_symbol_body",
        "mcp__serena__replace_content",
        "mcp__serena__insert_before_symbol",
        "mcp__serena__insert_after_symbol",
        "mcp__serena__rename_symbol",
        "mcp__serena__safe_delete_symbol",
    ):
        assert must_deny in deny, f"review profile dropped deny: {must_deny}"

    tools = set(flags[flags.index("--tools") + 1].split(","))
    assert "Edit" not in tools and "Write" not in tools
    assert {"Read", "Grep", "Glob", "Skill"} <= tools

    mcp_path = flags[flags.index("--mcp-config") + 1]
    servers = json.loads(Path(mcp_path).read_text())["mcpServers"]
    assert set(servers) == {"tilth", "code-review-graph", "context7"}


def test_real_todo_profile_is_closed_todoist_world(monkeypatch, tmp_path):
    """The shipped todo profile must be a closed world: the ONLY MCP is
    todoist, with its API key resolved, and skip-permissions in extra_args."""
    _hermetic_dotenv(monkeypatch, tmp_path)
    pdir = find_profile_dir("todo")
    assert pdir is not None, "real profiles/todo not found"
    m = parse_manifest(pdir)
    assert m.isolated is True
    flags, env = overlay.build_isolated_flags(m, pdir)

    mcp_path = flags[flags.index("--mcp-config") + 1]
    servers = json.loads(Path(mcp_path).read_text())["mcpServers"]
    assert set(servers) == {"todoist"}
    assert servers["todoist"]["env"]["TODOIST_API_KEY"] == "stub-td"
    assert "--dangerously-skip-permissions" in flags
    assert env.get("ENABLE_CLAUDEAI_MCP_SERVERS") == "true"


def test_real_notion_profile_is_http_shape(monkeypatch, tmp_path):
    """The shipped notion profile renders its single MCP as an http record."""
    _hermetic_dotenv(monkeypatch, tmp_path)
    pdir = find_profile_dir("notion")
    assert pdir is not None, "real profiles/notion not found"
    m = parse_manifest(pdir)
    flags, _ = overlay.build_isolated_flags(m, pdir)
    servers = json.loads(
        Path(flags[flags.index("--mcp-config") + 1]).read_text()
    )["mcpServers"]
    assert servers["notion"]["type"] == "http"
    assert "command" not in servers["notion"]


def test_isolated_missing_system_prompt_fails_loud(tmp_path):
    """A declared system_prompt that doesn't exist must fail loud at flag
    assembly, not silently append --append-system-prompt-file at a dead path."""
    m = Manifest(
        name="todo",
        mcps=[{"name": "todoist", "command": "npx", "args": ["-y", "x"],
               "_source_dir": str(tmp_path)}],
        isolated=True,
        system_prompt="MISSING.md",
    )
    with pytest.raises(overlay.IsolationError, match="system_prompt file not found"):
        overlay.build_isolated_flags(m, tmp_path)
