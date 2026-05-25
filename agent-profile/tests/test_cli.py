"""test_cli.py — CLI surface parity (list/describe/path/help/errors/launch).

Ported from tests/agent-profile-cli.bats. String/JSON outputs assert
against golden fixtures captured from the bash.
"""

from __future__ import annotations

import json

import pytest

from agent_profile import cli
from tests.conftest import write_profile

REVIEWER_BODY = "Reviewer body for foo\n"
HOOK_BODY = "#!/bin/bash\nexit 0\n"


def make_basic_profile(root, name):
    write_profile(
        root,
        name,
        f"name: {name}\n"
        "description: Basic test profile\n"
        "agents:\n"
        "  - name: reviewer\n"
        "    description: Reviews code\n"
        "    body_path: agents/reviewer.md\n"
        "hooks:\n"
        "  - event: PreToolUse\n"
        "    matcher: \"Bash\"\n"
        "    script: hooks/h.sh\n"
        "    harnesses: [claude]\n"
        "settings:\n"
        "  permissions_allow:\n"
        f"    - \"Bash({name}:*)\"\n",
        {
            "agents/reviewer.md": REVIEWER_BODY,
            "hooks/h.sh": HOOK_BODY,
        },
    )


def run(argv) -> int:
    return cli.main(argv)


# ─── list ─────────────────────────────────────────────────────────────


def test_list_prints_discovered_profiles(env, capsys):
    make_basic_profile(env.profiles, "foo")
    make_basic_profile(env.profiles, "bar")
    assert run(["list"]) == 0
    out = capsys.readouterr().out
    assert "foo" in out
    assert "bar" in out


def test_list_empty_friendly_message(env, capsys):
    assert run(["list"]) == 0
    assert "no profiles found" in capsys.readouterr().out


# ─── describe (golden) ────────────────────────────────────────────────


def test_describe_rust_matches_bash_golden(env, capsys, golden, tmp_path, monkeypatch):
    # Use the real rust+base profiles from the source ref, copied in.
    write_profile(
        env.profiles,
        "base",
        "name: base\n"
        "description: Generic coding-agent baseline (style, safety, AGENTS.md notes)\n"
        "settings:\n"
        "  permissions_allow:\n"
        "    - \"Bash(git status:*)\"\n"
        "    - \"Bash(git diff:*)\"\n"
        "    - \"Bash(git log:*)\"\n",
    )
    write_profile(
        env.profiles,
        "rust",
        "name: rust\n"
        "description: Rust toolchain conventions, clippy command, idiomatic reviewer\n"
        "include:\n  - base\n"
        "agents:\n"
        "  - name: rust-reviewer\n"
        "    description: Reviews Rust code for idiomatic patterns, lifetimes, and clippy-clean style.\n"
        "    tools: [Read, Grep, Glob, Bash]\n"
        "    body_path: agents/rust-reviewer.md\n"
        "skills:\n"
        "  - name: cargo-workflow\n"
        "    path: skills/cargo-workflow\n"
        "commands:\n"
        "  - name: clippy\n"
        "    description: Run cargo clippy and propose fixes\n"
        "    body_path: commands/clippy.md\n"
        "hooks:\n"
        "  - event: PreToolUse\n"
        "    matcher: \"Bash\"\n"
        "    script: hooks/cargo-check.sh\n"
        "    harnesses: [claude]\n"
        "settings:\n"
        "  permissions_allow:\n"
        "    - \"Bash(cargo:*)\"\n"
        "    - \"Bash(rustc:*)\"\n"
        "    - \"Bash(rustup:*)\"\n",
    )
    assert run(["describe", "rust"]) == 0
    out = capsys.readouterr().out
    # Header line, then a blank line, then the JSON document.
    lines = out.splitlines()
    assert lines[0].startswith("Profile: rust  (")
    assert lines[1] == ""
    parsed = json.loads("\n".join(lines[2:]))
    assert parsed == golden("strings/describe_rust.json")


# ─── path ─────────────────────────────────────────────────────────────


def test_path_missing_profile_fails(env, capsys, golden):
    assert run(["path", "nope"]) == 1
    err = capsys.readouterr().err.strip()
    assert err == golden("strings/errors.json")["describe_missing"]


def test_path_existing_prints_dir(env, capsys):
    make_basic_profile(env.profiles, "foo")
    assert run(["path", "foo"]) == 0
    assert capsys.readouterr().out.strip() == str((env.profiles / "foo").resolve())


# ─── help / unknown ───────────────────────────────────────────────────


def test_help_matches_golden(env, capsys, golden):
    assert run(["help"]) == 0
    assert capsys.readouterr().out == golden("strings/help.txt")


def test_no_args_defaults_to_help(env, capsys, golden):
    assert run([]) == 0
    assert capsys.readouterr().out == golden("strings/help.txt")


def test_unknown_subcommand_errors(env, capsys, golden):
    assert run(["frobnicate"]) == 1
    captured = capsys.readouterr()
    assert captured.err.splitlines()[0] == golden("strings/errors.json")["unknown_subcommand"]
    # Usage echoed to stderr too.
    assert "Usage: dots profile" in captured.err


# ─── install error strings ────────────────────────────────────────────


def test_install_no_name_errors(env, capsys, golden):
    assert run(["install"]) == 1
    assert capsys.readouterr().err.strip() == golden("strings/errors.json")["install_noname"]


def test_install_unknown_harness_errors(env, capsys, golden):
    make_basic_profile(env.profiles, "foo")
    assert run(["install", "foo", "--harness", "bogus"]) == 1
    assert (
        capsys.readouterr().err.strip()
        == golden("strings/errors.json")["install_unknown_harness"]
    )


def test_install_traversal_name_rejected(env, capsys, golden):
    make_basic_profile(env.profiles, "foo")
    assert run(["install", "../foo"]) == 1
    first = capsys.readouterr().err.splitlines()[0]
    assert first == golden("strings/errors.json")["install_traversal_first_line"]


def test_install_slash_name_rejected(env, capsys, golden):
    make_basic_profile(env.profiles, "foo")
    assert run(["install", "x/y"]) == 1
    first = capsys.readouterr().err.splitlines()[0]
    assert first == golden("strings/errors.json")["install_slash_first_line"]


# ─── launch arg plumbing (regression: install name, not harness) ──────


def test_launch_installs_profile_not_harness(env, capsys, stub_renderers, monkeypatch):
    make_basic_profile(env.profiles, "foo")
    execed = {}

    def fake_exec(file, args):
        execed["file"] = file
        execed["args"] = args
        raise SystemExit(0)

    monkeypatch.setattr(cli.os, "execvp", fake_exec)
    with pytest.raises(SystemExit):
        run(["launch", "claude", "foo", "--target", str(env.target)])
    # The 'foo' profile installed (shared agent written); not a 'claude' profile.
    assert (env.target / ".claude/agents/reviewer.md").is_file()
    assert execed["file"] == "claude"


def test_launch_no_harness_errors(env, capsys):
    assert run(["launch"]) == 1
    assert "harness required" in capsys.readouterr().err
