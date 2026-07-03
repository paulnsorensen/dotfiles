"""test_integration_production.py — seam hardening through the *production* renderers.

Every other CLI/integration test drives ``cmd_install`` / ``cmd_uninstall``
through ``StubRenderer`` (conftest). That leaves the real
``registry.build_registry()`` → ``cli.set_renderers`` → real
``render``/``clean`` → manifest ref-count seam uncovered: no test ran a
profile that touches 3+ production renderers in one install, nor proved the
production install→uninstall round-trip is byte-clean.

These tests close that gap. They wire the production renderers (the
exact path ``__main__`` takes) and assert the cross-renderer interactions
the per-curd goldens cannot see:

  - one ``cmd_install`` fans a multi-surface profile across codex, opencode,
    cursor, and the shared ``.claude/agents`` write;
  - the production round-trip tears every merged file (``.codex/config.toml``,
    ``opencode.json``, ``.cursor/mcp.json``) and whole-file artefact back to
    empty, manifest ``{}``;
  - a user-authored ``.codex/config.toml`` comment survives the full
    install→uninstall merged-file cycle driven by the CLI (not just the
    codex unit test);
  - cross-renderer ref-counting on the shared ``.claude/agents/<n>.md``
    holds when two profiles install through the real renderers.
"""

from __future__ import annotations

import json

import pytest
import tomlkit

from agent_profile import cli
from agent_profile.manifest import manifest_path
from agent_profile.renderers.registry import build_registry
from tests.conftest import install_profile, write_profile


@pytest.fixture
def prod_renderers():
    """Wire the production renderers into the CLI for one test,
    exactly as ``agent_profile.__main__.install()`` does in production."""
    saved = cli.RENDERERS
    cli.set_renderers(build_registry())
    yield
    cli.set_renderers(saved)


def _multi_surface_yaml(name: str) -> str:
    # An agent (→ shared .claude/agents + cursor/opencode read it), a skill
    # (→ shared .agents/skills, read by codex+opencode+cursor), two MCPs
    # explicitly scoped to codex+opencode+cursor, and a cursor hook.
    return (
        f"name: {name}\n"
        "description: multi-surface profile\n"
        "agents:\n"
        "  - name: rev\n"
        "    description: reviews\n"
        "    body_path: agents/rev.md\n"
        "skills:\n"
        "  - name: widget\n"
        "    path: skills/widget\n"
        "mcps:\n"
        "  - name: srv\n"
        "    command: /bin/true\n"
        "    args: [--flag]\n"
        "    harnesses: [codex, opencode, cursor, crush]\n"
        "hooks:\n"
        "  - name: h\n"
        "    event: PreToolUse\n"
        "    script: hooks/h.sh\n"
        "    harnesses: [cursor]\n"
    )


def _make_multi(root, name):
    write_profile(
        root,
        name,
        _multi_surface_yaml(name),
        {
            "agents/rev.md": f"{name} reviewer body\n",
            "skills/widget/SKILL.md": f"{name} widget\n",
            "hooks/h.sh": "#!/bin/sh\necho hi\n",
        },
    )


# ─── Seam 1: one install fans across 3+ production renderers ──────────


def test_production_install_touches_all_surfaces(env, capsys, prod_renderers):
    _make_multi(env.profiles, "multi")
    assert install_profile(["install", "multi", "--target", str(env.target)]) == 0
    capsys.readouterr()
    t = env.target

    # Shared cross-harness writes (claude/cursor/opencode all read these).
    assert (t / ".claude/agents/rev.md").is_file()
    assert (t / ".agents/skills/widget/SKILL.md").is_file()

    # Codex: agent TOML + config.toml [mcp_servers] merge.
    assert (t / ".codex/agents/rev.toml").is_file()
    codex_cfg = tomlkit.parse((t / ".codex/config.toml").read_text())
    assert "srv" in codex_cfg["mcp_servers"]
    assert codex_cfg["mcp_servers"]["srv"]["command"] == "/bin/true"

    # opencode: merged opencode.json with the MCP under "mcp".
    oc = json.loads((t / "opencode.json").read_text())
    assert "srv" in oc["mcp"]
    assert oc["mcp"]["srv"]["command"] == ["/bin/true", "--flag"]

    # cursor: mcp.json merge + hooks.json + copied hook script.
    cur = json.loads((t / ".cursor/mcp.json").read_text())
    assert "srv" in cur["mcpServers"]
    hooks = json.loads((t / ".cursor/hooks.json").read_text())
    assert len(hooks) == 1 and hooks[0]["event"] == "PreToolUse"
    assert (t / ".cursor/hooks/h.sh").is_file()

    # crush: merged crush.json with the MCP under "mcp".
    crush = json.loads((t / ".config/crush/crush.json").read_text())
    assert "srv" in crush["mcp"]

    # The whole-file artefacts (not the merged files) are tracked exactly once.
    manifest = json.loads(manifest_path(t).read_text())
    files = manifest["multi"]["files"]
    assert files == sorted(set(files)), "tracked files must be sorted + deduped"
    # Merged files are surgically un-merged in clean(), never tracked.
    for merged in ("opencode.json", ".codex/config.toml", ".cursor/mcp.json", ".config/crush/crush.json"):
        assert merged not in files, f"{merged} is a merged file, must not be tracked"
    # Whole-file artefacts that ARE tracked.
    assert ".claude/agents/rev.md" in files
    assert ".codex/agents/rev.toml" in files


# ─── Seam 2: production round-trip is byte-clean ──────────────────────


def test_production_install_uninstall_roundtrip_clean(env, capsys, prod_renderers):
    _make_multi(env.profiles, "multi")
    t = env.target

    install_profile(["install", "multi", "--target", str(t)])
    capsys.readouterr()
    tracked = list(json.loads(manifest_path(t).read_text())["multi"]["files"])
    assert tracked

    assert cli.main(["uninstall", "multi", "--target", str(t)]) == 0
    capsys.readouterr()

    # Every tracked whole-file artefact is gone.
    for rel in tracked:
        assert not (t / rel).exists(), f"{rel} survived uninstall"

    # Every merged file is surgically removed (the renderers owned them).
    for merged in ("opencode.json", ".codex/config.toml", ".cursor/mcp.json", ".config/crush/crush.json"):
        assert not (t / merged).exists(), f"merged {merged} survived clean"

    # Manifest empty.
    assert json.loads(manifest_path(t).read_text()) == {}


# ─── Seam 3: user-authored codex config survives the CLI round-trip ───


def test_production_codex_user_config_preserved_through_cli(
    env, capsys, prod_renderers
):
    """The codex unit test proves the renderer preserves user keys; this
    proves the *CLI* round-trip (install banner + merged_json cache +
    uninstall sweep + codex clean) does not shred a user-authored
    config.toml comment/key the profile never owned."""
    _make_multi(env.profiles, "multi")
    t = env.target
    cfg = t / ".codex/config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text(
        "# user comment — must survive\n"
        "approval_policy = \"on-request\"\n"
        "\n"
        "[mcp_servers.user_owned]\n"
        "command = \"keep-me\"\n"
    )

    install_profile(["install", "multi", "--target", str(t)])
    capsys.readouterr()

    after_install = cfg.read_text()
    assert "# user comment — must survive" in after_install
    parsed = tomlkit.parse(after_install)
    assert parsed["approval_policy"] == "on-request"
    assert parsed["mcp_servers"]["user_owned"]["command"] == "keep-me"
    assert "srv" in parsed["mcp_servers"]  # ours merged in

    cli.main(["uninstall", "multi", "--target", str(t)])
    capsys.readouterr()

    # File survives (user still owns it); our entry gone, user entry + comment stay.
    assert cfg.is_file(), "config.toml with user content must not be deleted"
    final = cfg.read_text()
    assert "# user comment — must survive" in final
    final_parsed = tomlkit.parse(final)
    assert final_parsed["approval_policy"] == "on-request"
    assert final_parsed["mcp_servers"]["user_owned"]["command"] == "keep-me"
    assert "srv" not in final_parsed.get("mcp_servers", {})


# ─── Seam 4: cross-renderer ref-count on shared .claude/agents ────────


def test_production_refcount_shared_agent_full_install(env, capsys, prod_renderers):
    """Two profiles defining an agent of the same name both write
    ``.claude/agents/shared.md`` through the real renderers (claude + cursor
    + opencode all target it). First uninstall must keep it (beta claims);
    second removes it. Exercises ref-count across renderers, not via stubs."""
    for p, body in (("alpha", "alpha body"), ("beta", "beta body")):
        write_profile(
            env.profiles,
            p,
            f"name: {p}\n"
            "agents:\n"
            "  - name: shared\n"
            "    description: d\n"
            "    body_path: agents/shared.md\n",
            {"agents/shared.md": f"{body}\n"},
        )
    t = env.target
    shared = t / ".claude/agents/shared.md"

    install_profile(["install", "alpha", "--target", str(t)])
    install_profile(["install", "beta", "--target", str(t)])
    capsys.readouterr()
    assert shared.is_file()
    assert "beta body" in shared.read_text()  # beta wrote last

    cli.main(["uninstall", "alpha", "--target", str(t)])
    out = capsys.readouterr().out
    assert (
        "↳ keeping .claude/agents/shared.md (claimed by another profile)" in out
    )
    assert shared.is_file()

    cli.main(["uninstall", "beta", "--target", str(t)])
    capsys.readouterr()
    assert not shared.exists()
    assert json.loads(manifest_path(t).read_text()) == {}
