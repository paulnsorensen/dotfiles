"""test_integration.py — steel threads through cmd_install / cmd_uninstall.

The three mandatory steel threads (spec Quality gates) plus CLI
orchestration parity, driven with stub renderers. Parity-critical strings
and shapes (the "keeping ... (claimed by another profile)" message, the
empty-after-uninstall manifest ``{}``, the install/uninstall banners) are
captured from the bash and asserted exactly.
"""

from __future__ import annotations

import json

import pytest

from agent_profile import cli
from agent_profile.manifest import manifest_path
from tests.conftest import write_profile


def _agent_profile(name, agent="reviewer"):
    return (
        f"name: {name}\n"
        "description: Basic test profile\n"
        "agents:\n"
        f"  - name: {agent}\n"
        "    description: Reviews code\n"
        f"    body_path: agents/{agent}.md\n"
    )


def make_basic(root, name, agent="reviewer", body=None):
    write_profile(
        root,
        name,
        _agent_profile(name, agent),
        {f"agents/{agent}.md": body or f"{name} body\n"},
    )


def run(argv):
    return cli.main(argv)


# ─── Steel thread 1: install -> uninstall round-trip is empty ─────────


def test_steel_install_uninstall_roundtrip_empty(env, capsys, stub_renderers):
    make_basic(env.profiles, "foo")

    assert run(["install", "foo", "--target", str(env.target)]) == 0
    install_out = capsys.readouterr().out
    # Banner parity (no color, non-TTY).
    assert "→ Installing profile 'foo' from" in install_out
    assert "✓ Installed" in install_out

    # Shared agent + per-harness markers + merged manifest exist.
    assert (env.target / ".claude/agents/reviewer.md").is_file()
    manifest = json.loads(manifest_path(env.target).read_text())
    assert "foo" in manifest
    assert manifest["foo"]["files"] == sorted(manifest["foo"]["files"])

    # Snapshot the tracked files for the round-trip assertion.
    tracked = list(manifest["foo"]["files"])
    assert tracked  # non-empty

    assert run(["uninstall", "foo", "--target", str(env.target)]) == 0
    uninstall_out = capsys.readouterr().out
    assert "→ Uninstalling profile 'foo' from" in uninstall_out
    assert "✓ Uninstalled" in uninstall_out

    # Every tracked artefact is gone (bash leaves empty parent dirs; we
    # assert on the recorded files exactly, as the bats integration does).
    for rel in tracked:
        assert not (env.target / rel).exists(), f"{rel} survived uninstall"

    # Manifest is back to {} (parity with the bash st1_uninstall capture).
    assert json.loads(manifest_path(env.target).read_text()) == {}


# ─── Steel thread 2: ref-count survival on shared .claude/agents/<n>.md ─


def test_steel_refcount_survival(env, capsys, stub_renderers, golden):
    # Two profiles both define agent 'shared' -> same .claude/agents/shared.md.
    make_basic(env.profiles, "alpha", agent="shared", body="alpha shared agent\n")
    make_basic(env.profiles, "beta", agent="shared", body="beta shared agent\n")

    run(["install", "alpha", "--harness", "cursor", "--target", str(env.target)])
    run(["install", "beta", "--harness", "cursor", "--target", str(env.target)])
    capsys.readouterr()

    shared = env.target / ".claude/agents/shared.md"
    assert shared.is_file()
    # Beta wrote last; its body is on disk.
    assert "beta shared agent" in shared.read_text()

    # Uninstall alpha — beta still claims the shared file, so it stays.
    run(["uninstall", "alpha", "--harness", "cursor", "--target", str(env.target)])
    out = capsys.readouterr().out
    assert "↳ keeping .claude/agents/shared.md (claimed by another profile)" in out
    assert shared.is_file()

    # Uninstall beta — last claimant gone, file removed.
    run(["uninstall", "beta", "--harness", "cursor", "--target", str(env.target)])
    assert not shared.exists()


# ─── Steel thread 3: install -> delete profile dir -> uninstall cleans ─


def test_steel_uninstall_after_profile_dir_deleted(env, capsys, stub_renderers):
    import shutil

    make_basic(env.profiles, "foo")
    run(["install", "foo", "--target", str(env.target)])
    capsys.readouterr()

    assert (env.target / ".claude/agents/reviewer.md").is_file()

    # Delete the profile source dir entirely — uninstall must still work
    # via the cached merged_json.
    shutil.rmtree(env.profiles / "foo")

    assert run(["uninstall", "foo", "--target", str(env.target)]) == 0
    assert not (env.target / ".claude/agents/reviewer.md").exists()
    assert json.loads(manifest_path(env.target).read_text()) == {}


# ─── CLI orchestration parity ─────────────────────────────────────────


def test_install_idempotent(env, capsys, stub_renderers):
    make_basic(env.profiles, "foo")
    run(["install", "foo", "--target", str(env.target)])
    capsys.readouterr()
    before = sorted(
        str(p.relative_to(env.target))
        for p in env.target.rglob("*")
        if p.is_file()
    )
    run(["install", "foo", "--target", str(env.target)])
    capsys.readouterr()
    after = sorted(
        str(p.relative_to(env.target))
        for p in env.target.rglob("*")
        if p.is_file()
    )
    assert before == after


def test_install_records_merged_json(env, capsys, stub_renderers):
    make_basic(env.profiles, "foo")
    run(["install", "foo", "--target", str(env.target)])
    capsys.readouterr()
    manifest = json.loads(manifest_path(env.target).read_text())
    assert manifest["foo"]["merged_json"]["name"] == "foo"


def test_install_harness_subset_writes_only_that_harness(env, capsys, stub_renderers):
    make_basic(env.profiles, "foo")
    run(["install", "foo", "--harness", "claude", "--target", str(env.target)])
    capsys.readouterr()
    # claude marker present, codex marker absent.
    assert (env.target / ".claude/agents/reviewer.md").is_file()
    assert not (env.target / ".codex").exists()


def test_reinstall_drops_orphaned_agent(env, capsys, stub_renderers):
    # Profile with two agents; drop one; re-install; orphan removed.
    write_profile(
        env.profiles,
        "twoagent",
        "name: twoagent\n"
        "agents:\n"
        "  - name: keep-me\n    body_path: agents/keep-me.md\n"
        "  - name: drop-me\n    body_path: agents/drop-me.md\n",
        {"agents/keep-me.md": "keep\n", "agents/drop-me.md": "drop\n"},
    )
    run(["install", "twoagent", "--harness", "claude", "--target", str(env.target)])
    capsys.readouterr()
    assert (env.target / ".claude/agents/drop-me.md").is_file()

    write_profile(
        env.profiles,
        "twoagent",
        "name: twoagent\nagents:\n  - name: keep-me\n    body_path: agents/keep-me.md\n",
        {"agents/keep-me.md": "keep\n"},
    )
    run(["install", "twoagent", "--harness", "claude", "--target", str(env.target)])
    capsys.readouterr()
    assert (env.target / ".claude/agents/keep-me.md").is_file()
    assert not (env.target / ".claude/agents/drop-me.md").exists()
    manifest = json.loads(manifest_path(env.target).read_text())
    assert not any("drop-me" in f for f in manifest["twoagent"]["files"])


def test_selective_reinstall_keeps_other_harness_files(env, capsys, stub_renderers):
    # MCP scoped to all harnesses -> codex marker written on full install.
    write_profile(
        env.profiles,
        "multi",
        "name: multi\n"
        "agents:\n  - name: a\n    body_path: agents/a.md\n"
        "mcps:\n  - name: omni\n    command: /bin/true\n"
        "    harnesses: [claude, codex, opencode, cursor, copilot]\n",
        {"agents/a.md": "body\n"},
    )
    run(["install", "multi", "--target", str(env.target)])
    capsys.readouterr()
    assert (env.target / ".codex/agents/a.md").is_file()

    run(["install", "multi", "--harness", "claude", "--target", str(env.target)])
    capsys.readouterr()
    # Selective re-install must not delete the codex marker.
    assert (env.target / ".codex/agents/a.md").is_file()


def test_uninstall_harness_subset_still_runs_all_cleaners(env, capsys, stub_renderers):
    # MCP scoped to opencode -> opencode merged file written. Uninstall with
    # --harness claude must still run opencode_clean (all cleaners run).
    write_profile(
        env.profiles,
        "multi",
        "name: multi\n"
        "agents:\n  - name: a\n    body_path: agents/a.md\n"
        "mcps:\n  - name: omni\n    command: /bin/true\n"
        "    harnesses: [claude, codex, opencode, cursor, copilot]\n",
        {"agents/a.md": "body\n"},
    )
    run(["install", "multi", "--target", str(env.target)])
    capsys.readouterr()
    opencode_merged = env.target / "opencode.json"
    assert opencode_merged.is_file()
    assert "omni" in json.loads(opencode_merged.read_text())["mcpServers"]

    run(["uninstall", "multi", "--harness", "claude", "--target", str(env.target)])
    capsys.readouterr()
    # opencode_clean evicted omni; the stub removes the now-empty file.
    assert not opencode_merged.exists()


def test_unknown_harness_rejected_before_any_render(env, capsys, stub_renderers):
    make_basic(env.profiles, "foo")
    assert run(["install", "foo", "--harness", "claude,bogus,codex", "--target", str(env.target)]) == 1
    assert "unknown harness" in capsys.readouterr().err
    assert not (env.target / ".claude/agents/reviewer.md").exists()


def test_install_fails_loud_when_renderer_unregistered(env, capsys, stub_renderers):
    # A valid harness whose renderer is missing from the registry must
    # fail loud (stderr + exit 1), never a green "✓ Installed" no-op.
    make_basic(env.profiles, "foo")
    missing = dict(stub_renderers)
    del missing["claude"]
    cli.set_renderers(missing)

    rc = run(["install", "foo", "--harness", "claude", "--target", str(env.target)])
    err = capsys.readouterr().err
    assert rc == 1
    assert "no renderer registered for harness 'claude'" in err


def test_two_profiles_share_skill_refcounted(env, capsys, stub_renderers):
    # Shared skill path .agents/skills/widget across two profiles.
    for p, body in (("alpha", "alpha widget"), ("beta", "beta widget")):
        write_profile(
            env.profiles,
            p,
            f"name: {p}\nskills:\n  - name: widget\n    path: skills/widget\n",
            {"skills/widget/SKILL.md": f"{body}\n"},
        )
    # The stub renderer does not write skills; use the shared writer directly
    # to exercise ref-counting on .agents/skills/<n>/ at the manifest level.
    from agent_profile import shared, manifest as m

    out_a: list[str] = []
    shared.copy_shared_skill(env.target, "widget", env.profiles / "alpha/skills/widget", out_a)
    m.record_file(env.target, "alpha", out_a[0])
    out_b: list[str] = []
    shared.copy_shared_skill(env.target, "widget", env.profiles / "beta/skills/widget", out_b)
    m.record_file(env.target, "beta", out_b[0])

    widget = env.target / ".agents/skills/widget"
    assert widget.is_dir()
    assert "beta widget" in (widget / "SKILL.md").read_text()

    # Uninstall alpha: beta still claims widget.
    assert m.other_profiles_claim_file(env.target, "alpha", ".agents/skills/widget") is True
