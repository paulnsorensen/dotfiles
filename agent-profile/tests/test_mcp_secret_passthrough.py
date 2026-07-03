"""test_mcp_secret_passthrough.py — criterion 10 regression.

MCP-secret-passthrough: ``ap`` carries the literal ``${VAR}`` from ingest to
each renderer instead of baking the resolved secret. This module is the
cross-harness backstop: render a ``${VAR}``-bearing MCP through every
``ap`` renderer that writes a persistent config (claude plugin-scope, codex,
opencode, cursor) with real secret values present in the process env, then
grep the entire rendered tree and assert no secret value leaked to disk.

copilot is excluded from the ``ap`` MCP default membership, so its live
config is written by the chezmoi template, not a renderer here — that arm is
covered by ``tests/chezmoi-wiring.bats`` (criterion 9).
"""

from __future__ import annotations

from pathlib import Path

from agent_profile.parse import Manifest
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer
from agent_profile.renderers.cursor import CursorRenderer
from agent_profile.renderers.opencode import OpencodeRenderer

SECRET = "sk-real-secret-VALUE-do-not-leak"
VARNAME = "CONTEXT7_API_KEY"


def _manifest() -> Manifest:
    """A plugin-scope manifest with one ${VAR}-bearing MCP that every
    persistent-config renderer (claude/codex/opencode/cursor) accepts."""
    return Manifest(
        name="secrets",
        mcps=[
            {
                "name": "context7",
                "command": "npx",
                "args": ["-y", "@upstash/context7-mcp"],
                "env": {VARNAME: f"${{{VARNAME}}}"},
                # Default membership = [claude, codex, opencode, cursor].
                "_source_dir": ".",
            }
        ],
    )


def _tree_text(root: Path) -> str:
    """Concatenate every rendered file's text under ``root`` (config files
    only — skip nothing; a leak anywhere is a failure)."""
    parts: list[str] = []
    for p in sorted(root.rglob("*")):
        if p.is_file():
            try:
                parts.append(p.read_text())
            except UnicodeDecodeError:
                continue
    return "\n".join(parts)


def test_no_renderer_bakes_the_secret(tmp_path, monkeypatch):
    # Real secret live in the process env (as it would be after zsh sources
    # .env) — the renderers must NOT resolve ${VAR} to it on disk.
    monkeypatch.setenv(VARNAME, SECRET)
    # codex scrub keys off $DOTFILES_DIR/.env containing the key name.
    dotfiles = tmp_path / "df"
    dotfiles.mkdir()
    (dotfiles / ".env").write_text(f"{VARNAME}={SECRET}\n")
    monkeypatch.setenv("DOTFILES_DIR", str(dotfiles))
    monkeypatch.delenv("AP_CODEX_INHERIT_ENV", raising=False)

    target = tmp_path / "target"
    target.mkdir()

    for renderer in (
        ClaudeRenderer(),
        CodexRenderer(),
        OpencodeRenderer(),
        CursorRenderer(),
    ):
        renderer.render(_manifest(), target)

    rendered = _tree_text(target)
    assert rendered, "no files were rendered — test would vacuously pass"
    assert SECRET not in rendered


def test_claude_user_scope_does_not_bake_secret(tmp_path, monkeypatch):
    # The user-scope path shells out to `claude mcp add`; capture its argv via
    # a fake CLI and assert the secret never reaches it.
    monkeypatch.setenv(VARNAME, SECRET)
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    log = tmp_path / "claude-calls.log"
    shim = bindir / "claude"
    shim.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$*" >> "$AP_TEST_CLAUDE_LOG"\nexit 0\n'
    )
    shim.chmod(0o755)
    monkeypatch.setenv("AP_TEST_CLAUDE_LOG", str(log))
    monkeypatch.setenv("PATH", f"{bindir}:{Path('/usr/bin')}")

    m = _manifest()
    m.mcp_scope = "user"
    ClaudeRenderer().render(m, tmp_path / "t")
    text = log.read_text()
    assert f"-e {VARNAME}=${{{VARNAME}}}" in text
    assert SECRET not in text
