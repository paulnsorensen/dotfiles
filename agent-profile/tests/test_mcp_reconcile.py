"""test_mcp_reconcile.py — install-time reconcile of MCP servers dropped
from the registry.

Renderers MERGE MCP entries into persistent/user-owned files (codex
config.toml, opencode/cursor/copilot JSON, claude user-scope
~/.claude.json). A server removed from the registry would otherwise
linger, since render only writes the current set. cmd_install now diffs
the prior resolved manifest (cached in manifest.json) against the current
one and has each in-scope renderer prune the dropped servers.

Tests assert: a dropped MCP is evicted from every merge-target harness on
re-install, the surviving MCP and unrelated user entries are preserved, a
fresh install (no prior) prunes nothing, and the claude user-scope path
unregisters exactly the dropped server via the CLI.
"""

from __future__ import annotations

import json

import pytest
import tomlkit

import agent_profile.renderers.claude as cl
from agent_profile import cli
from agent_profile.parse import Manifest
from agent_profile.renderers.registry import build_registry
from tests.conftest import install_profile, write_profile


@pytest.fixture
def prod_renderers():
    saved = cli.RENDERERS
    cli.set_renderers(build_registry())
    yield
    cli.set_renderers(saved)


def _yaml(name: str, mcp_names: list[str]) -> str:
    lines = [f"name: {name}", "description: reconcile probe", "mcps:"]
    for n in mcp_names:
        lines += [
            f"  - name: {n}",
            "    command: /bin/true",
            "    args: [--flag]",
            "    harnesses: [codex, opencode, cursor, copilot]",
        ]
    return "\n".join(lines) + "\n"


def _install(env, name: str) -> int:
    return install_profile(["install", name, "--target", str(env.target)])


# ─── integration: drop one MCP, re-install ───────────────────────────────────


def test_dropped_mcp_evicted_from_every_harness(env, capsys, prod_renderers):
    # Install srv1 + srv2 across the four merge-target harnesses.
    write_profile(env.profiles, "p", _yaml("p", ["srv1", "srv2"]))
    assert _install(env, "p") == 0
    capsys.readouterr()
    t = env.target

    # A user-authored MCP lands in codex config.toml out of band — it must
    # survive the reconcile (we only evict servers WE previously wrote).
    cfg = t / ".codex" / "config.toml"
    doc = tomlkit.parse(cfg.read_text())
    doc["mcp_servers"]["user-srv"] = {"command": "/usr/bin/env"}
    cfg.write_text(tomlkit.dumps(doc))

    # Re-install with srv2 removed from the registry.
    write_profile(env.profiles, "p", _yaml("p", ["srv1"]))
    assert _install(env, "p") == 0
    capsys.readouterr()

    codex = tomlkit.parse((t / ".codex/config.toml").read_text())["mcp_servers"]
    assert "srv2" not in codex
    assert "srv1" in codex
    assert "user-srv" in codex  # user entry preserved

    oc = json.loads((t / "opencode.json").read_text())["mcp"]
    assert "srv2" not in oc and "srv1" in oc

    cur = json.loads((t / ".cursor/mcp.json").read_text())["mcpServers"]
    assert "srv2" not in cur and "srv1" in cur

    cop = json.loads((t / ".copilot/mcp-config.json").read_text())["mcpServers"]
    assert "srv2" not in cop and "srv1" in cop


def test_fresh_install_prunes_nothing(env, capsys, prod_renderers):
    write_profile(env.profiles, "p", _yaml("p", ["srv1", "srv2"]))
    assert _install(env, "p") == 0
    capsys.readouterr()
    t = env.target
    codex = tomlkit.parse((t / ".codex/config.toml").read_text())["mcp_servers"]
    assert {"srv1", "srv2"} <= set(codex.keys())


def test_reconcile_reports_pruned_names(env, capsys, prod_renderers):
    write_profile(env.profiles, "p", _yaml("p", ["srv1", "srv2"]))
    _install(env, "p")
    capsys.readouterr()
    write_profile(env.profiles, "p", _yaml("p", ["srv1"]))
    _install(env, "p")
    out = capsys.readouterr().out
    assert "srv2" in out and "pruned" in out


# ─── claude user-scope path (CLI-backed, monkeypatched) ──────────────────────


def test_claude_prune_unregisters_user_scope(monkeypatch, tmp_path):
    calls: list[list[str]] = []

    def fake_run(cmd, *a, **k):
        calls.append(cmd)

        class R:
            returncode = 0

        return R()

    monkeypatch.setattr(cl.shutil, "which", lambda _: "/usr/bin/claude")
    monkeypatch.setattr(cl.subprocess, "run", fake_run)

    dropped = Manifest(
        name="global",
        description="d",
        mcps=[{"name": "gone", "command": "/bin/true", "args": []}],
        mcp_scope="user",
    )
    cl.ClaudeRenderer().prune_mcps(dropped, tmp_path)

    removes = [c for c in calls if "remove" in c and "gone" in c]
    assert removes, f"expected a `claude mcp remove gone`, got {calls}"


def _yaml_claude_user(
    name: str, mcp_names: list[str], target_default: str | None = None
) -> str:
    lines = [
        f"name: {name}",
        "description: reconcile probe",
    ]
    if target_default is not None:
        lines.append(f"target_default: {target_default}")
    lines += [
        "mcp_scope: user",
        "mcps:",
    ]
    for n in mcp_names:
        lines += [
            f"  - name: {n}",
            "    command: /bin/true",
            "    args: [--flag]",
            "    harnesses: [claude]",
        ]
    return "\n".join(lines) + "\n"


def test_dropped_mcp_unregistered_from_claude_user_scope(
    env, capsys, monkeypatch, prod_renderers
):
    # The production `global` profile installs claude MCPs at USER scope into
    # the live ~/.claude.json (mcp_scope: user) — the only reconcile path that
    # shells out to the `claude` CLI, and the highest-stakes eviction. The
    # `_yaml` integration fixture above excludes claude, so without this the
    # reconcile loop's claude branch is never driven end-to-end through
    # cli.main. Drive it and assert the dropped server is unregistered.
    calls: list[list[str]] = []

    def fake_run(cmd, *a, **k):
        calls.append(cmd)

        class R:
            returncode = 0

        return R()

    monkeypatch.setattr(cl.shutil, "which", lambda _: "/usr/bin/claude")
    monkeypatch.setattr(cl.subprocess, "run", fake_run)

    write_profile(
        env.profiles,
        "g",
        _yaml_claude_user("g", ["srv1", "srv2"], str(env.target)),
    )
    assert install_profile(["install", "g"]) == 0
    capsys.readouterr()
    calls.clear()  # discard first-install register churn

    # Re-install with srv2 dropped from the registry.
    write_profile(
        env.profiles,
        "g",
        _yaml_claude_user("g", ["srv1"], str(env.target)),
    )
    assert install_profile(["install", "g"]) == 0
    capsys.readouterr()

    # Reconcile must `claude mcp remove srv2` and never re-add it.
    assert [
        c for c in calls if "remove" in c and "srv2" in c
    ], f"expected `claude mcp remove srv2`, got {calls}"
    assert not [
        c for c in calls if "add" in c and "srv2" in c
    ], f"dropped srv2 must not be re-registered, got {calls}"
    # The survivor is still re-registered.
    assert [
        c for c in calls if "add" in c and "srv1" in c
    ], f"survivor srv1 must stay registered, got {calls}"


def test_explicit_target_user_scope_stages_plugin_mcp_without_claude_cli(
    env, capsys, monkeypatch, prod_renderers
):
    def boom(*a, **k):
        raise AssertionError("explicit-target render must not call claude CLI")

    monkeypatch.setattr(cl.shutil, "which", boom)
    monkeypatch.setattr(cl.subprocess, "run", boom)

    write_profile(env.profiles, "g", _yaml_claude_user("g", ["srv1"]))
    assert _install(env, "g") == 0
    capsys.readouterr()

    staged = env.target / ".claude/plugins/local/g/.mcp.json"
    assert json.loads(staged.read_text())["mcpServers"]["srv1"]["command"] == "/bin/true"

def test_claude_prune_noop_for_plugin_scope(monkeypatch, tmp_path):
    def boom(*a, **k):  # would raise if the CLI were touched
        raise AssertionError("plugin-scope prune must not call the claude CLI")

    monkeypatch.setattr(cl.subprocess, "run", boom)
    dropped = Manifest(
        name="p",
        description="d",
        mcps=[{"name": "gone", "command": "/bin/true", "args": []}],
        # default mcp_scope (not "user") → plugin .mcp.json is whole-file
    )
    cl.ClaudeRenderer().prune_mcps(dropped, tmp_path)  # must be a no-op


# ─── regression: an MCP scoped out of a harness must be pruned (#265) ─────────


def _yaml_scoped(name: str, specs: dict[str, list[str]]) -> str:
    """Profile YAML with an explicit per-MCP ``harnesses`` list."""
    lines = [f"name: {name}", "description: reconcile probe", "mcps:"]
    for n, harnesses in specs.items():
        lines += [
            f"  - name: {n}",
            "    command: /bin/true",
            "    args: [--flag]",
            f"    harnesses: {json.dumps(harnesses)}",
        ]
    return "\n".join(lines) + "\n"


def test_mcp_scoped_to_no_harnesses_is_pruned(env, capsys, prod_renderers):
    # srv1 + srv2 both render into the merge-target harnesses.
    write_profile(env.profiles, "p", _yaml("p", ["srv1", "srv2"]))
    assert _install(env, "p") == 0
    capsys.readouterr()
    t = env.target
    cur = json.loads((t / ".cursor/mcp.json").read_text())["mcpServers"]
    assert "srv2" in cur  # precondition: srv2 was rendered into cursor

    # Re-install with srv2 scoped OUT of every harness (harnesses: []). It stays
    # in manifest.mcps but should no longer render anywhere — the reconcile must
    # evict the stale entry a prior render merged into cursor/copilot. The bug:
    # current_names was global, so srv2 (still in manifest.mcps) never dropped.
    write_profile(
        env.profiles,
        "p",
        _yaml_scoped(
            "p",
            {"srv1": ["codex", "opencode", "cursor", "copilot"], "srv2": []},
        ),
    )
    assert _install(env, "p") == 0
    capsys.readouterr()

    cur = json.loads((t / ".cursor/mcp.json").read_text())["mcpServers"]
    assert "srv2" not in cur, "srv2 scoped to harnesses:[] must be pruned from cursor"
    assert "srv1" in cur, "survivor srv1 must stay"

    cop = json.loads((t / ".copilot/mcp-config.json").read_text())["mcpServers"]
    assert "srv2" not in cop, "srv2 scoped to harnesses:[] must be pruned from copilot"


def _yaml_mcp_tool_scopes(name: str, allow_rules: list[str]) -> str:
    lines = [
        f"name: {name}",
        "description: mcp tool scope reconcile probe",
        "mcps:",
        "  - name: srv1",
        "    command: /bin/true",
        "    harnesses: [codex]",
    ]
    if allow_rules:
        lines += ["settings:", "  permissions_allow:"]
        lines += [f"    - {json.dumps(rule)}" for rule in allow_rules]
    return "\n".join(lines) + "\n"


def test_dropped_codex_mcp_tool_scope_is_pruned(env, capsys, prod_renderers):
    write_profile(
        env.profiles,
        "p",
        _yaml_mcp_tool_scopes("p", ["mcp__srv1__read", "mcp__srv1__write"]),
    )
    assert _install(env, "p") == 0
    capsys.readouterr()

    cfg = env.target / ".codex/config.toml"
    first = tomlkit.parse(cfg.read_text())
    assert first["mcp_servers"]["srv1"]["enabled_tools"] == ["read", "write"]

    write_profile(env.profiles, "p", _yaml_mcp_tool_scopes("p", []))
    assert _install(env, "p") == 0
    capsys.readouterr()

    after = tomlkit.parse(cfg.read_text())
    assert "enabled_tools" not in after["mcp_servers"]["srv1"]
    assert "disabled_tools" not in after["mcp_servers"]["srv1"]
    assert after["mcp_servers"]["srv1"]["command"] == "/bin/true"
