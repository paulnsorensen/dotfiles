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


def test_isolated_launch_unsupported_harness_rejected(env, capsys):
    """cursor/copilot/crush have no runtime-isolation lever: an isolated
    launch against one fails loud (IsolationError -> CliError). codex and
    opencode are now SUPPORTED — see their own tests."""
    write_isolated_todo(env.profiles)
    rc = cli.main(["launch", "cursor", "todo", "--target", str(env.target)])
    assert rc == 1
    assert "unsupported" in capsys.readouterr().err.lower()


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
    flags, env = overlay.build_isolated_launch(m, profile_dir, "claude")
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
    flags, _ = overlay.build_isolated_launch(m, tmp_path, "claude")

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
    flags, _ = overlay.build_isolated_launch(m, tmp_path, "claude")
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
    flags, _ = overlay.build_isolated_launch(m, pdir, "claude")

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
    flags, env = overlay.build_isolated_launch(m, pdir, "claude")

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
    flags, _ = overlay.build_isolated_launch(m, pdir, "claude")
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
        overlay.build_isolated_launch(m, tmp_path, "claude")


# ─── dispatch table (D1) ────────────────────────────────────────


def _claude_manifest(tmp_path, **over):
    """A minimal isolated manifest with one stdio MCP, overridable per test."""
    base = dict(
        name="p",
        mcps=[{"name": "tilth", "command": "tilth", "args": ["--mcp"],
               "_source_dir": str(tmp_path)}],
        isolated=True,
    )
    base.update(over)
    return Manifest(**base)


@pytest.mark.parametrize("harness", ["cursor", "copilot", "crush", "bogus"])
def test_dispatch_unsupported_harness_raises(tmp_path, harness):
    """Every harness without an isolation builder fails loud on dispatch."""
    m = _claude_manifest(tmp_path)
    with pytest.raises(overlay.IsolationError, match="isolation unsupported"):
        overlay.build_isolated_launch(m, tmp_path, harness)


def test_dispatch_table_keys_are_the_three_isolating_harnesses(tmp_path):
    """The closed-world contract is claude/codex/opencode only; cursor/
    copilot/crush are deliberately absent (no runtime-isolation lever)."""
    assert set(overlay._ISOLATION_BUILDERS) == {"claude", "codex", "opencode"}


# ─── codex builder (#221) ────────────────────────────────────────


def _codex_config(env: dict) -> dict:
    """Parse the generated ``<CODEX_HOME>/config.toml`` via a real TOML parser.

    Asserts the builder set CODEX_HOME and that the file parses (the B1
    lesson: a config the codex Rust `toml` crate would reject is a broken
    launch, not a passing test). tomllib stands in for codex's parser — both
    implement TOML 1.0."""
    import tomllib

    home = env["CODEX_HOME"]
    cfg = Path(home) / "config.toml"
    assert cfg.is_file(), "isolated codex launch wrote no config.toml"
    return tomllib.loads(cfg.read_text())


def test_codex_redirects_home_with_empty_flags(tmp_path, monkeypatch):
    """Isolation rides in a redirected CODEX_HOME, not flags. The launch argv
    is bare interactive codex — NO exec-only --ephemeral/--ignore-user-config
    (rejected by codex 0.135.0's top-level parser)."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))  # no .env
    m = _claude_manifest(tmp_path, system_prompt="CLAUDE.md")
    (tmp_path / "CLAUDE.md").write_text("codex sp\n")
    flags, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    assert flags == []
    assert "--ephemeral" not in flags
    assert "--ignore-user-config" not in flags
    assert env["CODEX_HOME"]
    assert Path(env["CODEX_HOME"]).is_dir()


def test_codex_auth_json_symlinked_into_home(tmp_path, monkeypatch):
    """Login is preserved by symlinking <CODEX_HOME>/auth.json -> the real
    ~/.codex/auth.json (File auth-storage mode)."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    fake_home = tmp_path / "home"
    (fake_home / ".codex").mkdir(parents=True)
    (fake_home / ".codex" / "auth.json").write_text('{"tokens": "x"}\n')
    monkeypatch.setattr(overlay.Path, "home", classmethod(lambda cls: fake_home))
    m = _claude_manifest(tmp_path)
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    link = Path(env["CODEX_HOME"]) / "auth.json"
    assert link.is_symlink()
    assert link.resolve() == (fake_home / ".codex" / "auth.json").resolve()


def test_codex_auth_symlink_skipped_when_no_auth(tmp_path, monkeypatch):
    """Keyring users have no ~/.codex/auth.json; the builder must not create a
    dangling symlink (it would orphan auth either way — documented limitation)."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    fake_home = tmp_path / "home"
    (fake_home / ".codex").mkdir(parents=True)  # no auth.json
    monkeypatch.setattr(overlay.Path, "home", classmethod(lambda cls: fake_home))
    m = _claude_manifest(tmp_path)
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    assert not (Path(env["CODEX_HOME"]) / "auth.json").exists()


def test_codex_mcp_servers_are_toml_tables(tmp_path, monkeypatch):
    """Each profile MCP lands as an [mcp_servers.<n>] table in the generated
    config.toml with command + args (codex loads MCPs from config.toml, not a
    --mcp-config flag). Asserted by parsing the file, not substring-matching."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path)
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    cfg = _codex_config(env)
    assert cfg["mcp_servers"]["tilth"] == {
        "command": "tilth",
        "args": ["--mcp"],
    }


def test_codex_isolated_config_defaults_to_auto_permissions(tmp_path, monkeypatch):
    """Isolated Codex launches bypass ~/.codex/config.toml, so the generated
    config must carry the same Auto permissions defaults as the live seed."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path)
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    cfg = _codex_config(env)
    assert cfg["approval_policy"] == "on-request"
    assert cfg["approvals_reviewer"] == "auto_review"
    assert cfg["sandbox_mode"] == "workspace-write"


def test_codex_system_prompt_is_model_instructions_file(tmp_path, monkeypatch):
    """The system prompt is injected via model_instructions_file (an absolute
    path), NOT the reserved/noop `instructions` key."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path, system_prompt="CLAUDE.md")
    (tmp_path / "CLAUDE.md").write_text("be a good codex\n")
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    cfg = _codex_config(env)
    mif = cfg["model_instructions_file"]
    assert Path(mif).is_absolute()
    assert mif == str(tmp_path / "CLAUDE.md")
    assert "instructions" not in cfg  # the noop key is never emitted


def test_codex_config_is_valid_toml_with_adversarial_mcp_values(tmp_path, monkeypatch):
    """The generated config.toml must parse as TOML 1.0 AND round-trip its
    mcp_servers string values when an MCP arg/env carries TOML-special chars
    (`=`, `[ ]`, quotes, backslashes, `#`) and non-BMP unicode. This locks the
    `_codex_toml_value` ensure_ascii=False fix: a surrogate-pair \\u escape
    (json.dumps' default for non-BMP) is rejected by TOML 1.0 at parse time,
    so the whole config would fail to load."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    nasty_arg = '= [section] "q" \\ # café 🧀'
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "weird", "command": "npx",
               "args": ["-y", nasty_arg],
               "env": {"NOTE": "em — dash 🧀 lord, regex \\d+, key = val"},
               "_source_dir": str(tmp_path)}],
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    cfg = _codex_config(env)  # raises if the TOML is invalid
    server = cfg["mcp_servers"]["weird"]
    assert server["args"] == ["-y", nasty_arg], "mcp arg did not round-trip"
    assert server["env"]["NOTE"] == "em — dash 🧀 lord, regex \\d+, key = val"


def test_codex_home_is_not_under_tmp(tmp_path, monkeypatch):
    """CODEX_HOME must be rooted under the user cache, not the system temp dir:
    codex 0.135.0 refuses to install its PATH-helper binaries when CODEX_HOME
    is under a temp dir (a "could not update PATH" warning every isolated
    launch). The builder bases the per-launch home under $XDG_CACHE_HOME (or
    ~/.cache), NOT tempfile.mkdtemp's gettempdir() default.

    The cache base is asserted directly rather than via 'not under
    gettempdir()' because pytest's own tmp_path lives under /tmp, so a cache
    redirected into tmp_path would be a /tmp descendant by test scaffolding,
    not by the builder. Two cases pin the real invariant: an explicit
    XDG_CACHE_HOME is honoured, and the unset default is ~/.cache (a fake
    home), proving the base is never gettempdir()."""
    import tempfile

    # Sanity: the builder's default base is the cache dir, never the temp dir.
    assert Path(tempfile.gettempdir()).resolve() != (Path.home() / ".cache").resolve()

    # Case 1: explicit XDG_CACHE_HOME is honoured.
    cache = tmp_path / "cache"
    monkeypatch.setenv("XDG_CACHE_HOME", str(cache))
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path)
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    assert cache / "ap-codex" in Path(env["CODEX_HOME"]).parents

    # Case 2: unset XDG_CACHE_HOME falls back to ~/.cache, not gettempdir().
    monkeypatch.delenv("XDG_CACHE_HOME", raising=False)
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(overlay.Path, "home", classmethod(lambda cls: fake_home))
    _, env2 = overlay.build_isolated_launch(m, tmp_path, "codex")
    assert fake_home / ".cache" / "ap-codex" in Path(env2["CODEX_HOME"]).parents


def test_codex_quotes_non_bare_safe_keys(tmp_path, monkeypatch):
    """An MCP name or env key with a space or dot is not a valid TOML bare key
    (a space fails to parse, a dot silently nests). The builder quotes such
    keys so the generated config.toml still parses with the intended structure
    instead of corrupting the table layout."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "my.dotted server", "command": "npx",
               "env": {"has space": "v1", "a.b.c": "v2"},
               "_source_dir": str(tmp_path)}],
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    cfg = _codex_config(env)  # raises if the TOML is invalid
    # The dotted/space name is one server key, NOT a nested table.
    assert set(cfg["mcp_servers"]) == {"my.dotted server"}
    server = cfg["mcp_servers"]["my.dotted server"]
    assert server["command"] == "npx"
    assert server["env"] == {"has space": "v1", "a.b.c": "v2"}


def test_codex_no_system_prompt_omits_model_instructions_file(tmp_path, monkeypatch):
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path)  # no system_prompt
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    cfg = _codex_config(env)
    assert "model_instructions_file" not in cfg


def test_codex_drops_tools_plugins_extra_args_with_warning(tmp_path, monkeypatch, capsys):
    """D2/D3: codex can't restrict built-in tools — tools/enabled_plugins/
    extra_args are ignored-with-warning, never silently dropped, never fatal,
    never leaked into flags."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(
        tmp_path,
        tools=["Read", "Bash"],
        enabled_plugins={"x@y": True},
        extra_args=["--foo"],
    )
    flags, _ = overlay.build_isolated_launch(m, tmp_path, "codex")
    err = capsys.readouterr().err
    for field in ("tools", "enabled_plugins", "extra_args"):
        assert f"field {field} ignored for harness codex" in err
    assert flags == []  # nothing leaks into the launch argv


def test_codex_mcp_env_resolved_from_dotenv(tmp_path, monkeypatch):
    """${VAR} in a codex MCP env block resolves from .env at launch (D4),
    matching the claude path, and lands in the config.toml env sub-table."""
    dots = tmp_path / "dots"
    dots.mkdir()
    (dots / ".env").write_text("CTX=ctx-secret\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dots))
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "context7", "command": "npx", "args": ["-y", "c7"],
               "env": {"CONTEXT7_API_KEY": "${CTX}"},
               "_source_dir": str(tmp_path)}],
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    cfg = _codex_config(env)
    assert cfg["mcp_servers"]["context7"]["env"]["CONTEXT7_API_KEY"] == "ctx-secret"


def test_codex_mcp_env_unset_fails_loud(tmp_path, monkeypatch):
    dots = tmp_path / "dots"
    dots.mkdir()  # no .env
    monkeypatch.setenv("DOTFILES_DIR", str(dots))
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "context7", "command": "npx",
               "env": {"CONTEXT7_API_KEY": "${MISSING_C7}"},
               "_source_dir": str(tmp_path)}],
    )
    from agent_profile.env import EnvResolutionError

    with pytest.raises(EnvResolutionError, match="MISSING_C7"):
        overlay.build_isolated_launch(m, tmp_path, "codex")


def test_codex_http_mcp_uses_url_table(tmp_path, monkeypatch):
    """HTTP MCPs land as a url/type table, no command key."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "notion", "type": "http",
               "url": "https://mcp.notion.com/mcp",
               "_source_dir": str(tmp_path)}],
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    server = _codex_config(env)["mcp_servers"]["notion"]
    assert server["url"] == "https://mcp.notion.com/mcp"
    assert server["type"] == "http"
    assert "command" not in server


def test_codex_http_mcp_carries_headers(tmp_path, monkeypatch):
    """L2: an HTTP MCP's headers lower to an http_headers sub-table (verified
    against codex 0.135.0). The claude path carried headers; codex now does too."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "authed", "type": "http",
               "url": "https://example.com/mcp",
               "headers": {"X-Api-Key": "secret", "Authorization": "Bearer t"},
               "_source_dir": str(tmp_path)}],
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    server = _codex_config(env)["mcp_servers"]["authed"]
    assert server["http_headers"] == {
        "X-Api-Key": "secret",
        "Authorization": "Bearer t",
    }


def test_codex_http_mcp_missing_url_raises_isolation_error(tmp_path, monkeypatch):
    """A type:http MCP with no url raises IsolationError, not KeyError."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "broken", "type": "http",
               "_source_dir": str(tmp_path)}],
    )
    with pytest.raises(overlay.IsolationError, match="http MCP 'broken' missing url"):
        overlay.build_isolated_launch(m, tmp_path, "codex")


def test_codex_launch_does_not_hard_fail(env, monkeypatch):
    """`dots profile launch codex <iso>` builds + execs bare interactive codex
    (no exec-only flags), with CODEX_HOME injected into the process env."""
    write_isolated_todo(env.profiles)
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "codex", "todo", "--target", str(env.target)])
    assert rec["file"] == "codex"
    assert rec["args"] == ["codex"]  # bare interactive, no flags before passthrough
    assert "--ephemeral" not in rec["args"]
    assert "--ignore-user-config" not in rec["args"]
    assert cli.os.environ.get("CODEX_HOME")
    assert (Path(cli.os.environ["CODEX_HOME"]) / "config.toml").is_file()


# ─── opencode builder (#222) ─────────────────────────────────────


def test_opencode_emits_config_content_env(tmp_path, monkeypatch):
    """opencode isolates via env vars, not flags: flags is empty and the MCP
    world rides in OPENCODE_CONFIG_CONTENT."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))  # no registry -> no inherited
    m = _claude_manifest(tmp_path)
    flags, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    assert flags == []
    config = json.loads(env["OPENCODE_CONFIG_CONTENT"])
    assert config["mcp"]["tilth"] == {
        "type": "local",
        "enabled": True,
        "command": ["tilth", "--mcp"],
    }


def test_opencode_disables_project_config(tmp_path, monkeypatch):
    """L1: OPENCODE_DISABLE_PROJECT_CONFIG=true so a project-level opencode.json
    in the working tree can't leak its MCPs into the closed world (the
    inherited-disable list only covers the global registry)."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path)
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    assert env["OPENCODE_DISABLE_PROJECT_CONFIG"] == "true"


def test_opencode_disables_inherited_registry_servers(tmp_path, monkeypatch):
    """Inherited servers (registry membership includes opencode) are pinned
    enabled:false so the global config doesn't leak into the closed world;
    a server the profile ALSO declares stays enabled (profile wins)."""
    dots = tmp_path / "dots"
    (dots / "agents" / "mcp").mkdir(parents=True)
    (dots / "agents" / "mcp" / "registry.yaml").write_text(
        "mcps:\n"
        "  hallouminate:\n    command: hallouminate\n    args: [serve]\n"
        "  serena:\n    command: serena\n    args: [start]\n"
        "  todoist:\n    command: npx\n    harnesses: []\n"  # scoped out everywhere
        "  tilth:\n    command: tilth\n"  # profile also declares this
    )
    monkeypatch.setenv("DOTFILES_DIR", str(dots))
    m = _claude_manifest(tmp_path)  # declares tilth (enabled)
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    mcp = json.loads(env["OPENCODE_CONFIG_CONTENT"])["mcp"]
    assert mcp["hallouminate"] == {"enabled": False}
    assert mcp["serena"] == {"enabled": False}
    assert "todoist" not in mcp  # harnesses: [] -> not an opencode-inherited server
    assert mcp["tilth"]["enabled"] is True  # profile's own record wins


def test_opencode_missing_registry_warns_on_stderr(tmp_path, monkeypatch, capsys):
    """When the opencode registry is absent, a warning fires on stderr."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))  # no registry.yaml here
    m = _claude_manifest(tmp_path)
    overlay.build_isolated_launch(m, tmp_path, "opencode")
    err = capsys.readouterr().err
    assert "could not read opencode registry" in err
    assert "inherited global MCPs may not be sealed" in err


def test_opencode_unparseable_registry_warns_on_stderr(tmp_path, monkeypatch, capsys):
    """When the opencode registry contains invalid YAML, a warning fires on stderr."""
    dots = tmp_path / "dots"
    (dots / "agents" / "mcp").mkdir(parents=True)
    (dots / "agents" / "mcp" / "registry.yaml").write_text(": {bad: [yaml\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dots))
    m = _claude_manifest(tmp_path)
    overlay.build_isolated_launch(m, tmp_path, "opencode")
    err = capsys.readouterr().err
    assert "could not read opencode registry" in err
    assert "inherited global MCPs may not be sealed" in err


def test_opencode_system_prompt_additive_instructions(tmp_path, monkeypatch):
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path, system_prompt="CLAUDE.md")
    (tmp_path / "CLAUDE.md").write_text("oc sp\n")
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    config = json.loads(env["OPENCODE_CONFIG_CONTENT"])
    assert config["instructions"] == [str(tmp_path / "CLAUDE.md")]


def test_opencode_permission_maps_deny(tmp_path, monkeypatch):
    """D2: permissions_deny -> OPENCODE_PERMISSION. Edit/Write -> edit:deny;
    mcp__* passes through verbatim; NotebookEdit (no opencode key) is
    dropped+logged."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(
        tmp_path,
        permissions_deny=["Edit", "Write", "NotebookEdit",
                          "mcp__tilth__tilth_write"],
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    perm = json.loads(env["OPENCODE_PERMISSION"])
    assert perm["edit"] == "deny"
    assert perm["mcp__tilth__tilth_write"] == "deny"
    assert "NotebookEdit" not in perm  # no opencode equivalent


def test_opencode_permission_map_covers_each_claude_key(tmp_path, monkeypatch):
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(
        tmp_path, permissions_deny=["Read", "Grep", "Glob", "Bash"]
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    perm = json.loads(env["OPENCODE_PERMISSION"])
    assert perm == {"read": "deny", "grep": "deny",
                    "glob": "deny", "bash": "deny"}


def test_opencode_no_deny_omits_permission_env(tmp_path, monkeypatch):
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path)  # no permissions_deny
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    assert "OPENCODE_PERMISSION" not in env


def test_opencode_notebookedit_only_logs_and_omits_env(tmp_path, monkeypatch, capsys):
    """A deny list of only-unmappable keys logs the drop and emits no
    OPENCODE_PERMISSION (nothing mapped)."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path, permissions_deny=["NotebookEdit"])
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    assert "OPENCODE_PERMISSION" not in env
    assert "permissions_deny[NotebookEdit] ignored for harness opencode" \
        in capsys.readouterr().err


def test_opencode_mcp_env_rewritten_to_placeholder(tmp_path, monkeypatch):
    """opencode doesn't grok ${VAR}; the renderer rewrites it to {env:VAR} so
    opencode expands at launch and no secret is baked into the env JSON."""
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = Manifest(
        name="p",
        isolated=True,
        mcps=[{"name": "context7", "command": "npx", "args": ["-y", "c7"],
               "env": {"CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"},
               "_source_dir": str(tmp_path)}],
    )
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    mcp = json.loads(env["OPENCODE_CONFIG_CONTENT"])["mcp"]
    assert mcp["context7"]["environment"]["CONTEXT7_API_KEY"] == "{env:CONTEXT7_API_KEY}"


def test_opencode_profile_env_injected_alongside(tmp_path, monkeypatch):
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(tmp_path, env={"MY_FLAG": "on"})
    _, env = overlay.build_isolated_launch(m, tmp_path, "opencode")
    assert env["MY_FLAG"] == "on"
    assert "OPENCODE_CONFIG_CONTENT" in env


def test_opencode_drops_plugins_and_extra_args_with_warning(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    m = _claude_manifest(
        tmp_path, enabled_plugins={"x@y": True}, extra_args=["--foo"]
    )
    overlay.build_isolated_launch(m, tmp_path, "opencode")
    err = capsys.readouterr().err
    assert "field enabled_plugins ignored for harness opencode" in err
    assert "field extra_args ignored for harness opencode" in err


def test_opencode_launch_injects_config_env(env, monkeypatch):
    """`dots profile launch opencode <iso>` injects OPENCODE_CONFIG_CONTENT
    and execs opencode with empty isolation flags."""
    write_isolated_todo(env.profiles)
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "opencode", "todo", "--target", str(env.target)])
    assert rec["file"] == "opencode"
    assert cli.os.environ.get("OPENCODE_CONFIG_CONTENT")
    config = json.loads(cli.os.environ["OPENCODE_CONFIG_CONTENT"])
    assert "todoist" in config["mcp"]


def test_opencode_launch_profile_wins_name_collision(env, monkeypatch):
    """Full launch path: when a profile MCP name collides with an inherited
    registry server, the profile's enabled record wins end-to-end (not just in
    the _opencode_mcp_block unit). Drive `launch opencode todo` with a registry
    that declares todoist (the profile's own server) AND hallouminate
    (inherited-only); the injected OPENCODE_CONFIG_CONTENT must keep todoist
    enabled with the profile command and pin hallouminate enabled:false."""
    write_isolated_todo(env.profiles)
    dots = env.tmp / "empty-dots"  # the env fixture's DOTFILES_DIR
    (dots / "agents" / "mcp").mkdir(parents=True)
    (dots / "agents" / "mcp" / "registry.yaml").write_text(
        "mcps:\n"
        "  todoist:\n    command: should-be-overridden\n"  # collides with profile
        "  hallouminate:\n    command: hallouminate\n    args: [serve]\n"
    )
    rec = _capture_exec(monkeypatch)
    with pytest.raises(SystemExit):
        cli.main(["launch", "opencode", "todo", "--target", str(env.target)])
    assert rec["file"] == "opencode"
    mcp = json.loads(cli.os.environ["OPENCODE_CONFIG_CONTENT"])["mcp"]
    assert mcp["todoist"]["enabled"] is True, "profile server lost to inherited disable"
    assert mcp["todoist"]["command"] == ["npx", "-y", "@doist/todoist-ai"]
    assert mcp["hallouminate"] == {"enabled": False}


# ─── migrated-profile fidelity on non-claude harnesses ────────────────


def test_real_review_profile_read_only_on_opencode(monkeypatch, tmp_path):
    """The shipped review profile launched on opencode must stay read-only:
    OPENCODE_PERMISSION denies edit (from Edit/Write) and every serena
    mutator + tilth_write appears as an mcp__* deny key. Closed MCP world is
    exactly tilth + code-review-graph + context7 (own, enabled)."""
    _hermetic_dotenv(monkeypatch, tmp_path)
    pdir = find_profile_dir("review")
    assert pdir is not None, "real profiles/review not found"
    m = parse_manifest(pdir)
    _, env = overlay.build_isolated_launch(m, pdir, "opencode")

    perm = json.loads(env["OPENCODE_PERMISSION"])
    assert perm["edit"] == "deny"
    for mutator in (
        "mcp__tilth__tilth_write",
        "mcp__serena__replace_symbol_body",
        "mcp__serena__rename_symbol",
        "mcp__serena__safe_delete_symbol",
    ):
        assert perm[mutator] == "deny", f"review lost opencode deny: {mutator}"

    config = json.loads(env["OPENCODE_CONFIG_CONTENT"])
    own = {n for n, rec in config["mcp"].items() if rec.get("enabled") is not False}
    assert own == {"tilth", "code-review-graph", "context7"}


def test_real_review_profile_on_codex_projects_permission_rules(monkeypatch, tmp_path, capsys):
    """The shipped review profile on codex builds the MCP world and projects
    Codex-native permission surfaces into the redirected home."""
    _hermetic_dotenv(monkeypatch, tmp_path)
    pdir = find_profile_dir("review")
    assert pdir is not None
    m = parse_manifest(pdir)
    _, env = overlay.build_isolated_launch(m, pdir, "codex")
    err = capsys.readouterr().err
    assert "field permissions_deny ignored for harness codex" not in err
    servers = _codex_config(env)["mcp_servers"]
    for server in ("tilth", "code-review-graph", "context7"):
        assert server in servers, server
    assert "tilth_write" in servers["tilth"]["disabled_tools"]


def test_codex_isolated_home_projects_hooks_agents_rules_and_skills(tmp_path, monkeypatch):
    monkeypatch.setenv("DOTFILES_DIR", str(tmp_path))
    (tmp_path / "hooks").mkdir()
    (tmp_path / "hooks" / "h.sh").write_text("#!/bin/bash\nexit 0\n")
    assets = tmp_path / "agents"
    (assets / "lib").mkdir(parents=True)
    (assets / "lib" / "cheese-flair.sh").write_text("# assets\n")
    (assets / "reference").mkdir()
    (assets / "reference" / "cheese-flair.md").write_text("# bank\n")
    (tmp_path / "agents" / "reviewer.md").write_text("Review code.\n")
    skill = tmp_path / "skills" / "probe"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("# Probe\n")
    m = _claude_manifest(
        tmp_path,
        agents=[{"name": "reviewer", "description": "Reviews", "body_path": "agents/reviewer.md", "_source_dir": str(tmp_path)}],
        hooks=[
            {
                "event": "PreToolUse",
                "matcher": "Bash",
                "script": "hooks/h.sh",
                "harnesses": ["codex"],
                "shared_assets": ["agents/lib/cheese-flair.sh", "agents/reference/cheese-flair.md"],
                "_source_dir": str(tmp_path),
            }
        ],
        skills=[{"name": "probe", "path": "skills/probe", "_source_dir": str(tmp_path)}],
        settings={
            "permissions_allow": ["Bash(git status:*)", "mcp__tilth__read"],
        },
    )

    _, env = overlay.build_isolated_launch(m, tmp_path, "codex")
    home = Path(env["CODEX_HOME"])

    assert (home / "agents/reviewer.toml").is_file()
    assert (home / ".agents/skills/probe/SKILL.md").is_file()
    assert (home / "rules/ap-canonical.rules").is_file()
    hooks = json.loads((home / "hooks.json").read_text())
    command = hooks["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
    assert command == f"bash {home / 'hooks/h.sh'}"
    assert (home / "lib/cheese-flair.sh").read_text() == "# assets\n"
    assert (home / "reference/cheese-flair.md").read_text() == "# bank\n"
    cfg = _codex_config(env)
    assert cfg["mcp_servers"]["tilth"]["enabled_tools"] == ["read"]
