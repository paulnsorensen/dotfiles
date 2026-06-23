"""test_canonical_permissions.py — curd 1 (foundation) of the canonical
cross-harness permission model.

Covers the shared declaration layer:

  - the settings-level ``permissions_deny`` parse channel (folded in from
    #259) union-merges across includes alongside ``permissions_allow``;
  - the shipped ``_permissions`` fragment + its wiring into ``global``
    resolve into both lists, with bare MCP names preserved and the deny
    seed's deliberate exclusions (``rg``/``fd``/``sg``/``Read``) honored.

Per-renderer lowering (Claude root, Codex, Copilot) is covered in the
respective renderer test modules.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from agent_profile.parse import parse_manifest
from tests.conftest import write_profile


# ── settings-level deny channel union-merge (parse) ──────────────────


def test_settings_permissions_deny_unions_across_includes(env):
    """``settings.permissions_deny`` is union-merged + sorted across the
    include graph, mirroring ``permissions_allow`` (the #259 parse change
    folded in here)."""
    write_profile(
        env.profiles,
        "frag",
        "name: frag\n"
        "settings:\n"
        "  permissions_deny:\n"
        "    - Grep\n"
        "    - Bash(sudo:*)\n",
    )
    write_profile(
        env.profiles,
        "host",
        "name: host\n"
        "include: [frag]\n"
        "settings:\n"
        "  permissions_deny:\n"
        "    - Glob\n"
        "    - Grep\n",  # duplicate must dedupe
    )
    m = parse_manifest(env.profiles / "host")
    assert m.settings["permissions_deny"] == [
        "Bash(sudo:*)",
        "Glob",
        "Grep",
    ]


def test_settings_permissions_deny_dropped_when_empty(env):
    """An empty merged deny list is dropped entirely (parity with the
    allow channel — no empty key left behind)."""
    write_profile(env.profiles, "plain", "name: plain\n")
    m = parse_manifest(env.profiles / "plain")
    assert "permissions_deny" not in m.settings


def test_settings_allow_and_deny_both_union_merge(env):
    """Allow and deny channels union-merge independently in one pass."""
    write_profile(
        env.profiles,
        "a",
        "name: a\n"
        "settings:\n"
        "  permissions_allow: [Edit]\n"
        "  permissions_deny: [Grep]\n",
    )
    write_profile(
        env.profiles,
        "b",
        "name: b\n"
        "include: [a]\n"
        "settings:\n"
        "  permissions_allow: [Write]\n"
        "  permissions_deny: [Glob]\n",
    )
    m = parse_manifest(env.profiles / "b")
    assert m.settings["permissions_allow"] == ["Edit", "Write"]
    assert m.settings["permissions_deny"] == ["Glob", "Grep"]


# ── shipped _permissions fragment + global wiring ────────────────────


@pytest.fixture
def global_manifest():
    """Resolve the real shipped ``global`` profile (which now includes
    ``_permissions``). Skips if the repo profiles aren't where we expect."""
    repo = Path(os.environ.get("DOTFILES_DIR") or Path.home() / "Dev/dotfiles")
    gdir = repo / "profiles" / "global"
    if not gdir.is_file() and not (gdir / "profile.yaml").is_file():
        pytest.skip(f"global profile not found at {gdir}")
    return parse_manifest(gdir)


def test_global_resolves_canonical_allow_and_deny(global_manifest):
    """``global`` resolves both canonical lists via the ``_permissions``
    include. The deny list carries the cross-harness safety floor plus
    secret-protection rules (keys, credentials) that opencode's defaults
    don't cover."""
    allow = global_manifest.settings.get("permissions_allow", [])
    deny = global_manifest.settings.get("permissions_deny", [])
    # Safety floor + code-intel-tool forcing (the original 7 entries).
    for rule in (
        "Bash(ack:*)",
        "Bash(ag:*)",
        "Bash(grep:*)",
        "Bash(rm -rf:*)",
        "Bash(sudo:*)",
        "Glob",
        "Grep",
    ):
        assert rule in deny
    # Secret-protection deny rules (keys, credentials, cert files).
    for rule in (
        "Read(**/*.pem)",
        "Read(**/id_rsa)",
        "Read(**/.aws/credentials)",
        "Read(.env)",
    ):
        assert rule in deny
    assert len(deny) >= 20
    # The allow seed is the ~50-entry migration plus 15 MCP/tool rules; assert
    # the count is in the migrated range rather than mere non-emptiness.
    assert len(allow) >= 50


def test_global_allow_carries_migrated_command_rules(global_manifest):
    """The allow seed migrated verbatim from create_settings.json is
    present (spot-check the lift-and-shift)."""
    allow = set(global_manifest.settings.get("permissions_allow", []))
    for rule in ("Bash(git:*)", "Edit", "Write", "Skill"):
        assert rule in allow


def test_global_allow_uses_bare_mcp_names(global_manifest):
    """Lever-3 MCP rules use BARE names (`mcp__<server>__*`), matching
    global's ``mcp_scope: user`` registration — not plugin-namespaced."""
    allow = set(global_manifest.settings.get("permissions_allow", []))
    assert "mcp__tilth__*" in allow
    assert "mcp__code-review-graph__*" in allow
    # No plugin-namespaced canonical MCP rule for the user-scope servers.
    assert not any(
        a.startswith("mcp__plugin_global_") for a in allow
    )


def test_global_deny_seed_forces_code_intel_tools(global_manifest):
    """The deny seed blocks the built-in search tools + their bash
    equivalents, forcing the code-intelligence tools."""
    deny = set(global_manifest.settings.get("permissions_deny", []))
    for rule in ("Grep", "Glob", "Bash(grep:*)", "Bash(ag:*)", "Bash(ack:*)"):
        assert rule in deny


def test_global_deny_seed_safety_floor(global_manifest):
    """The cross-harness safety floor (sudo + coarse rm -rf) is denied."""
    deny = set(global_manifest.settings.get("permissions_deny", []))
    assert "Bash(sudo:*)" in deny
    assert "Bash(rm -rf:*)" in deny


def test_global_deny_seed_protects_secrets(global_manifest):
    """Secret-protection deny rules (private keys, credential stores, cert
    files) are declared in the canonical _permissions fragment so every
    harness renderer lowers them onto its native permission surface.
    opencode denies .env by default, so .env itself is included for
    cross-harness coverage but .env.* is NOT — adding it would clobber
    .env.example allows under the renderer's allow-then-deny batching
    (opencode is last-match-wins; the renderer emits all allow entries
    before all deny, so a .env.* deny would override an .env.example
    allow). Claude+Codex also have the PreToolUse hook
    (agents/lib/sensitive-file-guard.js) as a redundant guard."""
    deny = set(global_manifest.settings.get("permissions_deny", []))
    # Private keys + cert files.
    for rule in (
        "Read(**/*.pem)",
        "Read(**/*.key)",
        "Read(**/*.p12)",
        "Read(**/*.pfx)",
        "Read(**/id_rsa)",
        "Read(**/id_dsa)",
        "Read(**/id_ecdsa)",
        "Read(**/id_ed25519)",
        "Read(**/.ssh/id_*)",
    ):
        assert rule in deny, f"{rule} missing from canonical deny list"
    # Credential stores.
    for rule in (
        "Read(**/.aws/credentials)",
        "Read(**/.netrc)",
        "Read(**/.npmrc)",
        "Read(**/.pgpass)",
        "Read(**/.git-credentials)",
    ):
        assert rule in deny, f"{rule} missing from canonical deny list"
    # Secret files + .env (cross-harness; opencode defaults cover .env too).
    for rule in (
        "Read(**/secrets.*)",
        "Read(**/*.secret)",
        "Read(.env)",
        "Read(**/.env)",
    ):
        assert rule in deny, f"{rule} missing from canonical deny list"
    # .env.* is deliberately NOT denied here (see docstring).
    assert "Read(.env.*)" not in deny
    assert "Read(**/.env.*)" not in deny


def test_sanctioned_tools_not_denied(global_manifest):
    """Negative: rg/fd/sg stay allowed and Read is never denied (deny-wins,
    so they MUST stay out of the deny list)."""
    allow = set(global_manifest.settings.get("permissions_allow", []))
    deny = set(global_manifest.settings.get("permissions_deny", []))
    for sanctioned in ("Bash(rg:*)", "Bash(fd:*)", "Bash(sg:*)"):
        assert sanctioned in allow
        assert sanctioned not in deny
    assert "Read" not in deny


def test_emits_canonical_block_for_opencode(env, tmp_path, monkeypatch):
    """An ``ap install global --harness opencode`` analogue: the canonical
    allow set lowers onto opencode's permission surface. Uses a minimal
    standalone fragment so the test does not depend on base/registries."""
    from agent_profile.renderers.opencode import OpencodeRenderer

    write_profile(
        env.profiles,
        "_perms_t",
        "name: _perms_t\n"
        "settings:\n"
        "  permissions_allow:\n"
        "    - Bash(git:*)\n"
        "    - Edit\n",
    )
    write_profile(
        env.profiles,
        "glob_t",
        "name: glob_t\ninclude: [_perms_t]\n",
    )
    m = parse_manifest(env.profiles / "glob_t")
    OpencodeRenderer().render(m, env.target)
    import json

    data = json.loads((env.target / "opencode.json").read_text())
    assert data["permission"]["bash"]["git *"] == "allow"
