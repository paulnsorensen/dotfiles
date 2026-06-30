"""Steel threads for ``ap apply-compiled``.

These exercise the pure apply module against tmp_path fixtures only — never the
real ``$HOME``. Every resolved target root points inside ``tmp_path``.
"""

from __future__ import annotations

import json
import sys

import pytest

from agent_profile import apply_compiled
from agent_profile.compiled_types import ApplyState


def _target(name, root, *, symbolic="$HOME", harnesses=("claude",)):
    return {
        "name": name,
        "symbolic_root": symbolic,
        "resolved_root": str(root),
        "harnesses": list(harnesses),
    }


def _fragment(cache, target, harness, rel, content, *, generated=True):
    frag = cache / "fragments" / target / harness / rel
    frag.parent.mkdir(parents=True, exist_ok=True)
    frag.write_text(content)
    return {
        "target": target,
        "harness": harness,
        "fragment_path": str(frag),
        "relative_path": rel,
        "generated": generated,
    }


def _manifest(targets, files, *, profile="live"):
    return {
        "profile": profile,
        "source_id": "/src",
        "manifest_path": "/cache/manifest.json",
        "compile_targets": targets,
        "files": files,
        "drift": [],
    }


def _write_manifest(cache, manifest):
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path


# --- copy / update ---------------------------------------------------------


def test_apply_copies_managed_files_to_resolved_root(tmp_path):
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/reviewer.md", "review\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    dest = root / ".claude/agents/reviewer.md"
    assert dest.read_text() == "review\n"
    assert result.copied == (str(dest),)
    assert result.state.managed_files == (str(dest),)


def test_apply_updates_existing_file_in_place(tmp_path):
    root = tmp_path / "live"
    dest = root / ".claude/agents/reviewer.md"
    dest.parent.mkdir(parents=True)
    dest.write_text("old body\n")
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/reviewer.md", "new body\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    apply_compiled.apply_compiled(mpath)

    assert dest.read_text() == "new body\n"


def test_apply_writes_to_each_target_resolved_root(tmp_path):
    home = tmp_path / "home"
    oc = tmp_path / "oc"
    cache = tmp_path / "compiled"
    f_home = _fragment(cache, "home", "claude", ".claude/agents/r.md", "h\n")
    f_oc = _fragment(cache, "opencode", "opencode", ".opencode/agents/r.md", "o\n")
    targets = [
        _target("home", home),
        _target(
            "opencode",
            oc,
            symbolic="$HOME/.config/opencode",
            harnesses=("opencode",),
        ),
    ]
    mpath = _write_manifest(cache, _manifest(targets, [f_home, f_oc]))

    apply_compiled.apply_compiled(mpath)

    assert (home / ".claude/agents/r.md").read_text() == "h\n"
    assert (oc / ".opencode/agents/r.md").read_text() == "o\n"


def test_apply_writes_state_beside_manifest_by_default(tmp_path):
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/r.md", "x\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    state_path = cache / apply_compiled.DEFAULT_STATE_FILENAME
    assert result.state_path == state_path
    assert apply_compiled.read_apply_state(state_path) == result.state


# --- delete previously-managed, absent from new manifest -------------------


def test_apply_deletes_previously_managed_file_absent_from_manifest(tmp_path):
    root = tmp_path / "live"
    stale = root / ".claude/agents/old.md"
    stale.parent.mkdir(parents=True)
    stale.write_text("stale\n")
    cache = tmp_path / "compiled"
    cache.mkdir()
    apply_compiled.write_apply_state(
        cache / apply_compiled.DEFAULT_STATE_FILENAME,
        ApplyState(managed_files=(str(stale),)),
    )
    frag = _fragment(cache, "home", "claude", ".claude/agents/new.md", "new\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    assert not stale.exists()
    assert str(stale) in result.deleted
    assert str(stale) not in result.state.managed_files
    assert (root / ".claude/agents/new.md").read_text() == "new\n"


def test_apply_keeps_file_present_in_new_manifest(tmp_path):
    root = tmp_path / "live"
    dest = root / ".claude/agents/reviewer.md"
    dest.parent.mkdir(parents=True)
    dest.write_text("old\n")
    cache = tmp_path / "compiled"
    cache.mkdir()
    apply_compiled.write_apply_state(
        cache / apply_compiled.DEFAULT_STATE_FILENAME,
        ApplyState(managed_files=(str(dest),)),
    )
    frag = _fragment(cache, "home", "claude", ".claude/agents/reviewer.md", "fresh\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    assert dest.read_text() == "fresh\n"
    assert str(dest) not in result.deleted
    assert str(dest) in result.state.managed_files


def test_reconcile_removes_dropped_file_across_applies(tmp_path):
    """End-to-end: a file present in compile #1 but dropped in compile #2 is
    removed on the second apply, driven entirely by the persisted apply state."""
    root = tmp_path / "live"
    cache = tmp_path / "cache"  # stable per-source/profile cache reused each run
    a1 = _fragment(cache, "home", "claude", ".claude/agents/a.md", "a\n")
    b1 = _fragment(cache, "home", "claude", ".claude/agents/b.md", "b\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [a1, b1]))

    apply_compiled.apply_compiled(mpath)
    assert (root / ".claude/agents/b.md").exists()

    a2 = _fragment(cache, "home", "claude", ".claude/agents/a.md", "a\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [a2]))
    result = apply_compiled.apply_compiled(mpath)

    assert not (root / ".claude/agents/b.md").exists()
    assert (root / ".claude/agents/a.md").read_text() == "a\n"
    assert str(root / ".claude/agents/b.md") in result.deleted


# --- CRITICAL boundary: never touch files not in prior apply state ---------


def test_apply_never_deletes_file_not_in_prior_state(tmp_path):
    root = tmp_path / "live"
    user_file = root / ".claude/settings.json"
    user_file.parent.mkdir(parents=True)
    user_file.write_text('{"user":"owned"}\n')
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/reviewer.md", "body\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    assert user_file.read_text() == '{"user":"owned"}\n'
    assert str(user_file) not in result.deleted


def test_apply_deletes_dropped_managed_but_preserves_untracked_neighbor(tmp_path):
    """The reconcile and safety guarantees together: a dropped managed file is
    removed while an untracked user file in the same target survives."""
    root = tmp_path / "live"
    stale = root / ".claude/agents/old.md"
    stale.parent.mkdir(parents=True)
    stale.write_text("stale\n")
    user_file = root / ".claude/settings.json"
    user_file.write_text('{"user":"owned"}\n')
    cache = tmp_path / "compiled"
    cache.mkdir()
    apply_compiled.write_apply_state(
        cache / apply_compiled.DEFAULT_STATE_FILENAME,
        ApplyState(managed_files=(str(stale),)),  # user_file deliberately untracked
    )
    frag = _fragment(cache, "home", "claude", ".claude/agents/new.md", "new\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    assert not stale.exists()
    assert str(stale) in result.deleted
    assert user_file.read_text() == '{"user":"owned"}\n'
    assert str(user_file) not in result.deleted


def test_apply_skips_non_generated_files(tmp_path):
    """Whole merged files (generated=False) are owned by the merge module: this
    apply neither copies nor tracks them."""
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    merged = _fragment(
        cache, "home", "claude", ".claude/settings.json", '{"m":1}\n', generated=False
    )
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [merged]))

    result = apply_compiled.apply_compiled(mpath)

    assert not (root / ".claude/settings.json").exists()
    assert result.state.managed_files == ()
    assert result.copied == ()


def test_apply_skips_prior_managed_path_already_gone(tmp_path):
    """A prior-managed file the user already deleted is reconciled out of state
    without error and is not reported as deleted."""
    root = tmp_path / "live"
    gone = root / ".claude/agents/gone.md"  # never created on disk
    cache = tmp_path / "compiled"
    cache.mkdir()
    apply_compiled.write_apply_state(
        cache / apply_compiled.DEFAULT_STATE_FILENAME,
        ApplyState(managed_files=(str(gone),)),
    )
    frag = _fragment(cache, "home", "claude", ".claude/agents/r.md", "r\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    assert result.deleted == ()
    assert str(gone) not in result.state.managed_files


# --- idempotency -----------------------------------------------------------


def test_second_apply_same_manifest_is_idempotent(tmp_path):
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/r.md", "body\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    apply_compiled.apply_compiled(mpath)
    result = apply_compiled.apply_compiled(mpath)

    dest = root / ".claude/agents/r.md"
    assert result.deleted == ()
    assert dest.read_text() == "body\n"
    assert result.state.managed_files == (str(dest),)


# --- apply state read/write ------------------------------------------------


def test_read_apply_state_missing_returns_empty(tmp_path):
    assert apply_compiled.read_apply_state(tmp_path / "nope.json") == ApplyState()


def test_apply_state_round_trip(tmp_path):
    path = tmp_path / "state.json"
    state = ApplyState(managed_files=("/a/x", "/b/y"))
    apply_compiled.write_apply_state(path, state)
    assert apply_compiled.read_apply_state(path) == state


def test_read_apply_state_rejects_malformed(tmp_path):
    path = tmp_path / "state.json"
    path.write_text('{"managed_files": "not-a-list"}')
    with pytest.raises(apply_compiled.ApplyError):
        apply_compiled.read_apply_state(path)


# --- input validation ------------------------------------------------------


def test_apply_missing_manifest_raises(tmp_path):
    with pytest.raises(apply_compiled.ApplyError):
        apply_compiled.apply_compiled(tmp_path / "missing.json")


def test_apply_malformed_manifest_raises(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text("{ not json")
    with pytest.raises(apply_compiled.ApplyError):
        apply_compiled.apply_compiled(path)


def test_apply_missing_fragment_raises(tmp_path):
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    cache.mkdir()
    entry = {
        "target": "home",
        "harness": "claude",
        "fragment_path": str(cache / "fragments/home/claude/x.md"),
        "relative_path": "x.md",
        "generated": True,
    }
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [entry]))
    with pytest.raises(apply_compiled.ApplyError):
        apply_compiled.apply_compiled(mpath)


def test_apply_file_referencing_unknown_target_raises(tmp_path):
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "ghost", "claude", "x.md", "x\n")
    mpath = _write_manifest(
        cache, _manifest([_target("home", tmp_path / "live")], [frag])
    )
    with pytest.raises(apply_compiled.ApplyError):
        apply_compiled.apply_compiled(mpath)


@pytest.mark.parametrize("escaping", ["../escape.md", "a/../../escape.md", "/abs/escape.md"])
def test_apply_rejects_relative_path_escaping_target_root(tmp_path, escaping):
    """Finding regression: a ``relative_path`` that is absolute or climbs out of
    its target root via ``..`` is rejected with a handled ApplyError, so a
    malicious manifest cannot write or unlink outside the resolved root."""
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", "placeholder.md", "x\n")
    frag["relative_path"] = escaping
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))
    with pytest.raises(apply_compiled.ApplyError, match="relative_path"):
        apply_compiled.apply_compiled(mpath)

# --- CLI seam --------------------------------------------------------------


def test_cmd_apply_compiled_applies_and_returns_zero(tmp_path, capsys):
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/r.md", "body\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    rc = apply_compiled.cmd_apply_compiled([str(mpath)], sys.stdout)

    assert rc == 0
    assert (root / ".claude/agents/r.md").read_text() == "body\n"
    assert "applied 1 file(s)" in capsys.readouterr().out


def test_cmd_apply_compiled_requires_manifest_arg():
    with pytest.raises(apply_compiled.ApplyError):
        apply_compiled.cmd_apply_compiled([], sys.stdout)


# --- user-scope MCP registration (deferred from compile) -------------------


def _fake_claude(tmp_path, monkeypatch):
    """A fake ``claude`` first on PATH logging each call's args; returns the log."""
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    log = tmp_path / "claude-calls.log"
    shim = bindir / "claude"
    shim.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$AP_TEST_CLAUDE_LOG"\nexit 0\n')
    shim.chmod(0o755)
    monkeypatch.setenv("AP_TEST_CLAUDE_LOG", str(log))
    monkeypatch.setenv("PATH", f"{bindir}:/usr/bin")
    return log


_USER_MCP = {
    "name": "context7",
    "command": "npx",
    "args": ["-y", "@upstash/context7-mcp"],
    "env": {"CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"},
}


def _manifest_user_mcps(targets, user_mcps):
    m = _manifest(targets, [])
    m["user_mcps"] = user_mcps
    return m


def test_apply_registers_user_mcps_via_cli(tmp_path, monkeypatch):
    """apply performs the live ``claude mcp add`` the compile deferred —
    remove-then-add per server, idempotent."""
    log = _fake_claude(tmp_path, monkeypatch)
    cache = tmp_path / "compiled"
    mpath = _write_manifest(
        cache,
        _manifest_user_mcps([_target("home", tmp_path / "live")], [_USER_MCP]),
    )

    result = apply_compiled.apply_compiled(mpath)

    assert result.registered_mcps == ("context7",)
    assert log.read_text().splitlines() == [
        "mcp remove context7 --scope user",
        "mcp add context7 --scope user -e CONTEXT7_API_KEY=${CONTEXT7_API_KEY} "
        "-- npx -y @upstash/context7-mcp",
    ]


def test_apply_user_mcp_passes_literal_var_not_secret(tmp_path, monkeypatch):
    """The ``claude mcp add`` argv carries the literal ``${VAR}``; a real
    process-env value never leaks into the stored registration."""
    monkeypatch.setenv("CONTEXT7_API_KEY", "sk-real-secret-123")
    log = _fake_claude(tmp_path, monkeypatch)
    cache = tmp_path / "compiled"
    mpath = _write_manifest(
        cache,
        _manifest_user_mcps([_target("home", tmp_path / "live")], [_USER_MCP]),
    )

    apply_compiled.apply_compiled(mpath)

    text = log.read_text()
    assert "-e CONTEXT7_API_KEY=${CONTEXT7_API_KEY}" in text
    assert "sk-real-secret-123" not in text


def test_apply_user_mcp_missing_cli_fails_loud(tmp_path, monkeypatch):
    """No ``claude`` on PATH but user_mcps present → handled ApplyError."""
    emptybin = tmp_path / "emptybin"
    emptybin.mkdir()
    monkeypatch.setenv("PATH", str(emptybin))
    cache = tmp_path / "compiled"
    mpath = _write_manifest(
        cache,
        _manifest_user_mcps([_target("home", tmp_path / "live")], [_USER_MCP]),
    )
    with pytest.raises(apply_compiled.ApplyError, match="claude` CLI"):
        apply_compiled.apply_compiled(mpath)


def test_apply_user_mcp_add_failure_is_handled(tmp_path, monkeypatch):
    """A non-zero ``claude mcp add`` raises a handled ApplyError, not an
    uncaught CalledProcessError."""
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    shim = bindir / "claude"
    # `remove` succeeds (exit 0); `add` fails (exit 1).
    shim.write_text('#!/bin/sh\ncase "$1 $2" in "mcp add") exit 1;; esac\nexit 0\n')
    shim.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}:/usr/bin")
    cache = tmp_path / "compiled"
    mpath = _write_manifest(
        cache,
        _manifest_user_mcps([_target("home", tmp_path / "live")], [_USER_MCP]),
    )
    with pytest.raises(apply_compiled.ApplyError, match="claude mcp add context7"):
        apply_compiled.apply_compiled(mpath)


def test_apply_no_user_mcps_makes_no_claude_call(tmp_path, monkeypatch):
    """A manifest without user_mcps never touches the claude CLI."""
    log = _fake_claude(tmp_path, monkeypatch)
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/r.md", "r\n")
    mpath = _write_manifest(cache, _manifest([_target("home", root)], [frag]))

    result = apply_compiled.apply_compiled(mpath)

    assert result.registered_mcps == ()
    assert not log.exists()


def test_apply_persists_state_when_mcp_registration_fails(tmp_path, monkeypatch):
    """Finding regression: disk copy/delete is committed before MCP registration,
    so when ``claude mcp add`` raises, the apply state must still record the
    already-moved files — otherwise the next reconcile uses stale managed_files
    and orphans them."""
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    shim = bindir / "claude"
    shim.write_text('#!/bin/sh\ncase "$1 $2" in "mcp add") exit 1;; esac\nexit 0\n')
    shim.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}:/usr/bin")
    root = tmp_path / "live"
    cache = tmp_path / "compiled"
    frag = _fragment(cache, "home", "claude", ".claude/agents/r.md", "r\n")
    manifest = _manifest_user_mcps([_target("home", root)], [_USER_MCP])
    manifest["files"] = [frag]
    mpath = _write_manifest(cache, manifest)

    with pytest.raises(apply_compiled.ApplyError, match="claude mcp add context7"):
        apply_compiled.apply_compiled(mpath)

    dest = root / ".claude/agents/r.md"
    assert dest.read_text() == "r\n"  # file was moved before the failure
    state = apply_compiled.read_apply_state(
        cache / apply_compiled.DEFAULT_STATE_FILENAME
    )
    assert state.managed_files == (str(dest),)


def test_apply_user_mcp_missing_required_key_is_handled(tmp_path):
    """Finding regression: a user_mcps entry missing ``name``/``command`` raises a
    handled ApplyError, not an uncaught KeyError."""
    cache = tmp_path / "compiled"
    bad = {"command": "npx", "args": ["-y", "x"]}  # no 'name'
    mpath = _write_manifest(
        cache,
        _manifest_user_mcps([_target("home", tmp_path / "live")], [bad]),
    )
    with pytest.raises(apply_compiled.ApplyError, match="'name' and 'command'"):
        apply_compiled.apply_compiled(mpath)


@pytest.mark.parametrize(
    ("bad", "match"),
    [
        ({"name": 123, "command": "npx"}, "'name' must be a non-empty string"),
        ({"name": "", "command": "npx"}, "'name' must be a non-empty string"),
        ({"name": "ctx", "command": 123}, "'command' must be a non-empty string"),
        ({"name": "ctx", "command": ""}, "'command' must be a non-empty string"),
    ],
)
def test_apply_user_mcp_non_string_key_is_handled(tmp_path, bad, match):
    """Finding regression: a user_mcps entry whose ``name``/``command`` is present
    but not a non-empty string raises a handled ApplyError before the argv ever
    reaches ``subprocess.run`` (which would otherwise raise an uncaught TypeError).
    """
    cache = tmp_path / "compiled"
    mpath = _write_manifest(
        cache,
        _manifest_user_mcps([_target("home", tmp_path / "live")], [bad]),
    )
    with pytest.raises(apply_compiled.ApplyError, match=match):
        apply_compiled.apply_compiled(mpath)
