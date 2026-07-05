"""test_codex_legacy_hook_cleanup.py — strip orphan ``[[hooks.<event>]]``
blocks from ``~/.codex/config.toml`` that the retired
``agents/hooks/sync.sh`` wrote.

Codex CLI merges ``hooks.json`` and ``config.toml`` hooks at load time
(developers.openai.com/codex/hooks), so a machine that migrated from the
legacy bash sync to ap ends up firing every managed hook twice per
session — once from each file. The ap codex renderer is now responsible
for cleaning the legacy entries before writing ``hooks.json``.

Tests assert: managed legacy blocks are stripped, user-authored
``[[hooks.*]]`` entries are preserved, every other top-level key in
``config.toml`` survives (``[mcp_servers]``, ``approval_policy``, …),
both quoted and unquoted ``$HOME`` command forms are recognized, and
the cleanup is a no-op when ``config.toml`` has no orphan blocks.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import tomlkit

from agent_profile.parse import Manifest
from agent_profile.renderers.codex import CodexRenderer


def _manifest_with_hook(src: Path, script_basename: str) -> Manifest:
    """A minimal manifest with one codex SessionStart hook. ``harnesses``
    is set explicitly because ``hooks_for`` defaults to claude-only
    membership — the real registry declares ``harnesses: [claude, codex]``
    for the cheese-flair hook so codex picks it up."""
    hooks_dir = src / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    (hooks_dir / script_basename).write_text("#!/bin/bash\n: cheese flair\n")
    return Manifest(
        name="p1",
        description="t",
        # isolated: the legacy config.toml sweep only runs for isolated
        # launches now (live installs leave the shared config.toml alone).
        isolated=True,
        hooks=[
            {
                "name": "session-start-cheese-flair",
                "event": "SessionStart",
                "script": f"hooks/{script_basename}",
                "matcher": "startup|resume",
                "timeout": 5,
                "harnesses": ["claude", "codex"],
                "_source_dir": str(src),
            }
        ],
    )


def _config_with_legacy_block(
    target: Path,
    *,
    command: str,
    extra_user_blocks: list[dict] | None = None,
    extra_top_level: dict | None = None,
) -> Path:
    """Write a ``.codex/config.toml`` shaped like one the retired sync.sh
    would have produced. ``extra_user_blocks`` lets a test inject
    user-authored ``[[hooks.SessionStart]]`` entries that must survive
    the cleanup."""
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    doc = tomlkit.document()
    if extra_top_level:
        for k, v in extra_top_level.items():
            doc[k] = v
    hooks_table = tomlkit.table()
    aot = tomlkit.aot()
    block = tomlkit.table()
    block["matcher"] = "startup|resume"
    inner_aot = tomlkit.aot()
    inner = tomlkit.table()
    inner["type"] = "command"
    inner["command"] = command
    inner["timeout"] = 5
    inner_aot.append(inner)
    block["hooks"] = inner_aot
    aot.append(block)
    for user in extra_user_blocks or []:
        user_block = tomlkit.table()
        user_block["matcher"] = user.get("matcher", "")
        u_inner = tomlkit.aot()
        u_t = tomlkit.table()
        u_t["type"] = "command"
        u_t["command"] = user["command"]
        u_inner.append(u_t)
        user_block["hooks"] = u_inner
        aot.append(user_block)
    hooks_table["SessionStart"] = aot
    doc["hooks"] = hooks_table
    cfg.write_text(tomlkit.dumps(doc))
    return cfg


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


def test_strips_legacy_block_with_unquoted_home(renderer, src, target):
    cfg = _config_with_legacy_block(
        target,
        command="bash $HOME/.codex/hooks/session-start-cheese-flair.sh",
    )
    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")

    renderer.render(m, target)

    doc = tomlkit.parse(cfg.read_text())
    assert "hooks" not in doc, (
        "the only block was a managed-legacy one; the empty table should "
        "have been dropped"
    )


def test_strips_legacy_block_with_quoted_home(renderer, src, target):
    cfg = _config_with_legacy_block(
        target,
        command='bash "$HOME/.codex/hooks/session-start-cheese-flair.sh"',
    )
    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")

    renderer.render(m, target)

    doc = tomlkit.parse(cfg.read_text())
    assert "hooks" not in doc


def test_preserves_user_authored_session_start_block(renderer, src, target):
    """A user's own SessionStart hook (different basename or different
    path) must survive the strip — basename + path-contains match keeps
    the cleanup tightly scoped to migration debris."""
    cfg = _config_with_legacy_block(
        target,
        command="bash $HOME/.codex/hooks/session-start-cheese-flair.sh",
        extra_user_blocks=[
            {
                "matcher": "startup",
                "command": "bash /opt/user/scripts/my-custom-startup.sh",
            }
        ],
    )
    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")

    renderer.render(m, target)

    doc = tomlkit.parse(cfg.read_text())
    survived = doc["hooks"]["SessionStart"]
    assert len(survived) == 1
    assert (
        survived[0]["hooks"][0]["command"]
        == "bash /opt/user/scripts/my-custom-startup.sh"
    )


def test_preserves_user_hook_with_same_basename_at_different_path(
    renderer, src, target
):
    """A user could legitimately have their own script with the same
    basename but a different parent. We anchor on
    ``/.codex/hooks/`` in the command path; anything outside that prefix
    is left alone."""
    cfg = _config_with_legacy_block(
        target,
        command="bash $HOME/.codex/hooks/session-start-cheese-flair.sh",
        extra_user_blocks=[
            {
                "matcher": "startup",
                # Same basename, different path → not managed.
                "command": "bash /opt/me/session-start-cheese-flair.sh",
            }
        ],
    )
    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")

    renderer.render(m, target)

    doc = tomlkit.parse(cfg.read_text())
    survived = doc["hooks"]["SessionStart"]
    assert len(survived) == 1
    assert (
        survived[0]["hooks"][0]["command"]
        == "bash /opt/me/session-start-cheese-flair.sh"
    )


def test_preserves_other_top_level_keys(renderer, src, target):
    """``[mcp_servers]`` and other user keys must survive the cleanup —
    the whole reason codex.py uses tomlkit (not ``yq -o=toml``) is to
    keep the user's file shape intact."""
    cfg = _config_with_legacy_block(
        target,
        command="bash $HOME/.codex/hooks/session-start-cheese-flair.sh",
        extra_top_level={
            "approval_policy": "on-request",
            "sandbox_mode": "workspace-write",
        },
    )
    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")

    renderer.render(m, target)

    doc = tomlkit.parse(cfg.read_text())
    assert doc["approval_policy"] == "on-request"
    assert doc["sandbox_mode"] == "workspace-write"
    assert "hooks" not in doc


def test_no_op_when_config_has_no_legacy_block(renderer, src, target):
    """Cleanup must not touch an unrelated config — round-trip identity
    on a file with no managed-legacy entries."""
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    original = (
        'approval_policy = "on-request"\n'
        "\n"
        "[mcp_servers.example]\n"
        'command = "echo"\n'
    )
    cfg.write_text(original)
    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")

    renderer.render(m, target)

    # No managed-legacy hooks, so config.toml stays byte-identical apart
    # from any [mcp_servers] write the renderer performs. The codex
    # renderer only writes [mcp_servers] when MCPs are in the manifest;
    # this manifest has none, so the file must be unchanged.
    assert cfg.read_text() == original


def test_no_op_when_config_toml_missing(renderer, src, target):
    """A fresh machine has no ``.codex/config.toml`` yet; the cleanup
    must not crash or create the file."""
    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")

    renderer.render(m, target)

    # _write_hooks writes hooks.json but never config.toml on a fresh box.
    assert not (target / ".codex" / "config.toml").exists()
    assert (target / ".codex" / "hooks.json").is_file()


def test_strips_two_legacy_blocks_with_different_command_forms(
    renderer, src, target
):
    """The exact regression observed in the wild: two legacy blocks with
    different command quoting both managed by us — both must go."""
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    doc = tomlkit.document()
    hooks_table = tomlkit.table()
    aot = tomlkit.aot()
    for cmd in (
        "bash $HOME/.codex/hooks/session-start-cheese-flair.sh",
        'bash "$HOME/.codex/hooks/session-start-cheese-flair.sh"',
    ):
        block = tomlkit.table()
        block["matcher"] = "startup|resume"
        inner_aot = tomlkit.aot()
        inner = tomlkit.table()
        inner["type"] = "command"
        inner["command"] = cmd
        inner["timeout"] = 5
        inner_aot.append(inner)
        block["hooks"] = inner_aot
        aot.append(block)
    hooks_table["SessionStart"] = aot
    doc["hooks"] = hooks_table
    cfg.write_text(tomlkit.dumps(doc))

    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")
    renderer.render(m, target)

    doc_after = tomlkit.parse(cfg.read_text())
    assert "hooks" not in doc_after


def test_preserves_user_hook_with_same_basename_under_different_event(
    renderer, src, target
):
    """A user could legitimately route the same script basename through
    a different event slot (e.g. PreToolUse) than the one the registry
    manages (SessionStart). The migration invariant is "only strip what
    we're about to re-write into the same event slot" — so the user's
    cross-event entry must survive even when its command path-ends in a
    basename the registry manages."""
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    doc = tomlkit.document()
    hooks_table = tomlkit.table()

    # Managed legacy SessionStart block (will be stripped)
    ss_aot = tomlkit.aot()
    ss_block = tomlkit.table()
    ss_block["matcher"] = "startup|resume"
    ss_inner = tomlkit.aot()
    ss_t = tomlkit.table()
    ss_t["type"] = "command"
    ss_t["command"] = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
    ss_inner.append(ss_t)
    ss_block["hooks"] = ss_inner
    ss_aot.append(ss_block)
    hooks_table["SessionStart"] = ss_aot

    # User's PreToolUse block pointing at the SAME script basename — must
    # survive because the registry hook is on SessionStart, not PreToolUse.
    pre_aot = tomlkit.aot()
    pre_block = tomlkit.table()
    pre_inner = tomlkit.aot()
    pre_t = tomlkit.table()
    pre_t["type"] = "command"
    pre_t["command"] = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
    pre_inner.append(pre_t)
    pre_block["hooks"] = pre_inner
    pre_aot.append(pre_block)
    hooks_table["PreToolUse"] = pre_aot

    doc["hooks"] = hooks_table
    cfg.write_text(tomlkit.dumps(doc))

    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")
    renderer.render(m, target)

    doc_after = tomlkit.parse(cfg.read_text())
    assert "SessionStart" not in doc_after["hooks"], (
        "managed SessionStart entry should have been stripped"
    )
    assert "PreToolUse" in doc_after["hooks"], (
        "user's PreToolUse entry must survive — only SessionStart was managed"
    )
    assert (
        doc_after["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        == "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
    )


def test_preserves_other_event_types(renderer, src, target):
    """A managed SessionStart block is stripped, but an unrelated
    ``[[hooks.PreToolUse]]`` block must survive."""
    cfg = target / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    doc = tomlkit.document()
    hooks_table = tomlkit.table()

    ss_aot = tomlkit.aot()
    ss_block = tomlkit.table()
    ss_block["matcher"] = "startup|resume"
    ss_inner = tomlkit.aot()
    ss_t = tomlkit.table()
    ss_t["type"] = "command"
    ss_t["command"] = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
    ss_inner.append(ss_t)
    ss_block["hooks"] = ss_inner
    ss_aot.append(ss_block)
    hooks_table["SessionStart"] = ss_aot

    pre_aot = tomlkit.aot()
    pre_block = tomlkit.table()
    pre_inner = tomlkit.aot()
    pre_t = tomlkit.table()
    pre_t["type"] = "command"
    pre_t["command"] = "bash /opt/me/pre-tool.sh"
    pre_inner.append(pre_t)
    pre_block["hooks"] = pre_inner
    pre_aot.append(pre_block)
    hooks_table["PreToolUse"] = pre_aot

    doc["hooks"] = hooks_table
    cfg.write_text(tomlkit.dumps(doc))

    m = _manifest_with_hook(src, "session-start-cheese-flair.sh")
    renderer.render(m, target)

    doc_after = tomlkit.parse(cfg.read_text())
    assert "SessionStart" not in doc_after["hooks"]
    assert "PreToolUse" in doc_after["hooks"]
    assert (
        doc_after["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        == "bash /opt/me/pre-tool.sh"
    )
