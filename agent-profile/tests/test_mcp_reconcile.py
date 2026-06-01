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

from agent_profile import cli
from agent_profile.parse import Manifest
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.registry import build_registry
from tests.conftest import write_profile


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
    return cli.main(["install", name, "--target", str(env.target)])


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
    import agent_profile.renderers.claude as cl

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
    ClaudeRenderer().prune_mcps(dropped, tmp_path)

    removes = [c for c in calls if "remove" in c and "gone" in c]
    assert removes, f"expected a `claude mcp remove gone`, got {calls}"


def test_claude_prune_noop_for_plugin_scope(monkeypatch, tmp_path):
    import agent_profile.renderers.claude as cl

    def boom(*a, **k):  # would raise if the CLI were touched
        raise AssertionError("plugin-scope prune must not call the claude CLI")

    monkeypatch.setattr(cl.subprocess, "run", boom)
    dropped = Manifest(
        name="p",
        description="d",
        mcps=[{"name": "gone", "command": "/bin/true", "args": []}],
        # default mcp_scope (not "user") → plugin .mcp.json is whole-file
    )
    ClaudeRenderer().prune_mcps(dropped, tmp_path)  # must be a no-op
