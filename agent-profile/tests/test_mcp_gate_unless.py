"""test_mcp_gate_unless.py — claude-only `gate_unless` MCP suppression parity.

The bash `mcp_filter_for_harness` drops a `gate_unless` MCP from the claude
surface when the named process-env var is exactly `"true"` (the cheese-flow
plugin sets `CHEESE_FLOW`), and leaves every other harness untouched:

    map(select((.value.gate_unless // "") as $g | $g == "" or (env[$g] // "false") != "true"))

These tests lock that parity onto `gate_blocks` / `mcps_for` (the renderer
seam every harness shares) and prove the gate reaches the claude `.mcp.json`
projection end-to-end. Three live registry MCPs (tilth, context7, tavily)
carry `gate_unless: CHEESE_FLOW`, so the gate is consumed, not dead schema.
"""

from __future__ import annotations

import json

import pytest

from agent_profile.parse import Manifest, parse_manifest
from agent_profile.renderers.base import gate_blocks, mcps_for
from agent_profile.renderers.claude import ClaudeRenderer

from .conftest import write_profile

_ALL = ("claude", "codex", "opencode", "cursor", "copilot", "crush")


# ─── gate_blocks: claude-only, exact-"true" process-env match ─────────


def test_gate_blocks_true_for_claude_when_var_is_true(monkeypatch):
    monkeypatch.setenv("CHEESE_FLOW", "true")
    item = {"name": "tilth", "command": "tilth", "gate_unless": "CHEESE_FLOW"}
    assert gate_blocks(item, "claude") is True


def test_gate_does_not_block_when_var_unset(monkeypatch):
    monkeypatch.delenv("CHEESE_FLOW", raising=False)
    item = {"name": "tilth", "command": "tilth", "gate_unless": "CHEESE_FLOW"}
    assert gate_blocks(item, "claude") is False


def test_gate_does_not_block_when_var_not_exactly_true(monkeypatch):
    # Bash compares against the literal string "true"; any other value (even
    # "1" or "TRUE") keeps the MCP. Lock the exact-match contract.
    monkeypatch.setenv("CHEESE_FLOW", "1")
    item = {"name": "tilth", "command": "tilth", "gate_unless": "CHEESE_FLOW"}
    assert gate_blocks(item, "claude") is False


def test_gate_is_claude_only(monkeypatch):
    # The bash applies gate_unless only in the claude branch; every other
    # harness ignores it (a plugin-provided MCP is a claude concern).
    monkeypatch.setenv("CHEESE_FLOW", "true")
    item = {"name": "tilth", "command": "tilth", "gate_unless": "CHEESE_FLOW"}
    for harness in ("codex", "opencode", "cursor", "copilot", "crush"):
        assert gate_blocks(item, harness) is False


def test_gate_does_not_block_item_without_gate_field(monkeypatch):
    monkeypatch.setenv("CHEESE_FLOW", "true")
    item = {"name": "hallouminate", "command": "hallouminate"}
    assert gate_blocks(item, "claude") is False


# ─── mcps_for: gate folds into the shared membership projection ───────


def _manifest_with_gated_and_plain() -> Manifest:
    return Manifest(
        name="gatetest",
        mcps=[
            {"name": "tilth", "command": "tilth", "gate_unless": "CHEESE_FLOW"},
            {"name": "hallouminate", "command": "hallouminate"},
        ],
    )


def test_mcps_for_claude_drops_gated_when_set(monkeypatch):
    monkeypatch.setenv("CHEESE_FLOW", "true")
    names = [m["name"] for m in mcps_for(_manifest_with_gated_and_plain(), "claude", _ALL)]
    assert names == ["hallouminate"]


def test_mcps_for_claude_keeps_gated_when_unset(monkeypatch):
    monkeypatch.delenv("CHEESE_FLOW", raising=False)
    names = [m["name"] for m in mcps_for(_manifest_with_gated_and_plain(), "claude", _ALL)]
    assert names == ["tilth", "hallouminate"]


def test_mcps_for_codex_keeps_gated_even_when_set(monkeypatch):
    # gate_unless is claude-only: codex (and friends) keep the gated MCP
    # regardless of CHEESE_FLOW, matching the bash else-branch.
    monkeypatch.setenv("CHEESE_FLOW", "true")
    names = [m["name"] for m in mcps_for(_manifest_with_gated_and_plain(), "codex", _ALL)]
    assert names == ["tilth", "hallouminate"]


# ─── end-to-end: the gate reaches the claude .mcp.json projection ─────

_GATED_PROFILE = """\
name: gated
description: gate_unless render parity
mcps:
  - name: tilth
    command: tilth
    args: ["--mcp"]
    gate_unless: CHEESE_FLOW
  - name: hallouminate
    command: hallouminate
"""


@pytest.fixture
def gated_manifest(env):
    profile_dir = write_profile(env.profiles, "gated", _GATED_PROFILE)
    return parse_manifest(profile_dir), env.target


def test_claude_mcp_json_omits_gated_server_when_flow_active(gated_manifest, monkeypatch):
    monkeypatch.setenv("CHEESE_FLOW", "true")
    manifest, target = gated_manifest
    ClaudeRenderer().render(manifest, target)
    servers = json.loads(
        (target / ".claude/plugins/local/gated/.mcp.json").read_text()
    )["mcpServers"]
    # cheese-flow provides tilth; the base render must not duplicate it.
    assert set(servers) == {"hallouminate"}


def test_claude_mcp_json_includes_gated_server_when_flow_inactive(gated_manifest, monkeypatch):
    monkeypatch.delenv("CHEESE_FLOW", raising=False)
    manifest, target = gated_manifest
    ClaudeRenderer().render(manifest, target)
    servers = json.loads(
        (target / ".claude/plugins/local/gated/.mcp.json").read_text()
    )["mcpServers"]
    assert set(servers) == {"tilth", "hallouminate"}
