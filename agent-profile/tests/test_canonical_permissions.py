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


@pytest.fixture(scope="module")
def global_manifest():
    """Resolve the real shipped ``global`` profile (which now includes
    ``_permissions``). Skips if the repo profiles aren't where we expect."""
    repo = Path(os.environ.get("DOTFILES_DIR") or Path.home() / "Dev/dotfiles")
    gdir = repo / "profiles" / "global"
    if not gdir.is_file() and not (gdir / "profile.yaml").is_file():
        pytest.skip(f"global profile not found at {gdir}")
    return parse_manifest(gdir)



def test_global_resolves_canonical_allow_and_deny(global_manifest):
    """``global`` resolves both canonical lists via ``_permissions``.

    The deny channel now carries only the cross-harness safety floor plus the
    secret-protection rules; search-tool rerouting moved out of the hard deny
    list and into the tool-routing layer.
    """
    allow = global_manifest.settings.get("permissions_allow", [])
    deny = global_manifest.settings.get("permissions_deny", [])
    for rule in (
        "Bash(rtk proxy git grep:*)",
        "Bash(rm -rf:*)",
        "Bash(sudo:*)",
    ):
        assert rule in deny
    for rule in (
        "Read(**/*.pem)",
        "Read(**/id_rsa)",
        "Read(**/.aws/credentials)",
        "Read(.env)",
    ):
        assert rule in deny
    assert len(deny) >= 20
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
    # No plugin-namespaced canonical MCP rule for the user-scope servers.
    assert not any(
        a.startswith("mcp__plugin_global_") for a in allow
    )


def test_global_deny_seed_leaves_search_routing_to_hooks(global_manifest):
    """Search-tool routing is no longer a hard deny here.

    grep/ag/ack plus the Grep/Glob tools are rerouted by hooks or prompting, so
    they must stay out of the deny list. The only unroutable tunnel we still hard
    deny is ``rtk proxy git grep`` because it would bypass structural search.
    """
    deny = set(global_manifest.settings.get("permissions_deny", []))
    for rule in ("Grep", "Glob", "Bash(grep:*)", "Bash(ag:*)", "Bash(ack:*)"):
        assert rule not in deny
    assert "Bash(rtk proxy git grep:*)" in deny


def test_global_deny_seed_safety_floor(global_manifest):
    """The cross-harness safety floor (sudo + coarse rm -rf) is denied."""
    deny = set(global_manifest.settings.get("permissions_deny", []))
    assert "Bash(sudo:*)" in deny
    assert "Bash(rm -rf:*)" in deny


def test_global_deny_seed_protects_secrets(global_manifest):
    """Secret-protection rules are declared in the canonical permissions
    fragment so every renderer lowers them onto its native surface. Exact
    `.env` paths are denied, but `.env.*` is not because that would also block
    safe fixtures such as `.env.example`. Claude and Codex additionally apply
    the sensitive-file PreToolUse hook."""
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
    # Secret files and exact .env paths.
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
    """Negative: fd/sg stay allowed, rg is prompt-gated rather than denied, and
    ``Read`` itself is never denied."""
    allow = set(global_manifest.settings.get("permissions_allow", []))
    deny = set(global_manifest.settings.get("permissions_deny", []))
    for sanctioned in ("Bash(fd:*)", "Bash(sg:*)"):
        assert sanctioned in allow
        assert sanctioned not in deny
    assert "Bash(rg:*)" not in allow
    assert "Bash(rg:*)" not in deny
    assert "Read" not in deny
