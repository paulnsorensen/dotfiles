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


def test_describe_nameless_external_skill_uses_source(env, capsys, tmp_path, monkeypatch):
    """A repo-level external skill (auto-discovery, no explicit `name`) must
    not KeyError in describe — it falls back to its `source` repo. Regression:
    the `base` profile unions `_registry.yaml` sources that omit `skills:`,
    yielding nameless items."""
    repo = tmp_path / "repo"
    (repo / "skills").mkdir(parents=True)
    (repo / "skills" / "_registry.yaml").write_text(
        "sources:\n  owner/repo-a:\n    description: a\n"
    )
    monkeypatch.setenv("DOTFILES_DIR", str(repo))
    write_profile(
        env.profiles,
        "ext",
        "name: ext\n"
        "registries:\n"
        "  skills: [skills/_registry.yaml]\n",
    )
    assert run(["describe", "ext"]) == 0
    parsed = json.loads("\n".join(capsys.readouterr().out.splitlines()[2:]))
    assert parsed["skills"] == ["owner/repo-a"]


# ─── path ─────────────────────────────────────────────────────────────


def test_path_missing_profile_fails(env, capsys, golden):
    assert run(["path", "nope"]) == 1
    err = capsys.readouterr().err.strip()
    assert err == golden("strings/errors.json")["describe_missing"]


def test_path_existing_prints_dir(env, capsys):
    make_basic_profile(env.profiles, "foo")
    assert run(["path", "foo"]) == 0
    assert capsys.readouterr().out.strip() == str((env.profiles / "foo").resolve())


# ─── copilot-flags ────────────────────────────────────────────────────


def test_copilot_flags_emits_one_flag_per_line(env, capsys):
    make_basic_profile(env.profiles, "foo")  # allow Bash(foo:*)
    assert run(["copilot-flags", "foo"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines == ["--allow-tool=shell(foo)"]


def test_copilot_flags_missing_profile_fails(env, capsys):
    assert run(["copilot-flags", "nope"]) == 1
    assert "not found" in capsys.readouterr().err


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


# ─── install-into-git-repo guard (footgun: dump rendered files into a tree) ──


def _profile_with_default(env, name):
    """A profile that escapes to its own target_default ($HOME), so the
    cwd-in-git-repo guard must never fire for it."""
    write_profile(
        env.profiles,
        name,
        f"name: {name}\n"
        "description: Has a target_default\n"
        "target_default: $HOME\n",
    )


def test_install_guard_fires_inside_git_repo_no_target(
    env, capsys, stub_renderers, monkeypatch
):
    """WHY: a profile with no target_default, installed without --target from
    inside a git working tree, would resolve target to cwd and dump rendered
    runtime (.codex/, .cursor/, manifest.json, …) into the repo. The guard
    must abort before any rendering touches disk."""
    make_basic_profile(env.profiles, "foo")  # no target_default
    repo = env.tmp / "somerepo"
    (repo / ".git").mkdir(parents=True)
    monkeypatch.chdir(repo)
    assert run(["install", "foo"]) == 1
    err = capsys.readouterr().err
    assert "git working tree" in err
    assert "--target" in err
    # Rendered nothing into the cwd.
    assert not (repo / ".agent-profile").exists()
    assert not (repo / ".claude").exists()


def test_install_guard_silent_when_target_passed_inside_git_repo(
    env, stub_renderers, monkeypatch
):
    """WHY: an explicit --target is the operator stating where output goes —
    the guard exists only to catch the *accidental* cwd fallback, so a passed
    target must install cleanly even from inside a git repo."""
    make_basic_profile(env.profiles, "foo")
    repo = env.tmp / "somerepo"
    (repo / ".git").mkdir(parents=True)
    monkeypatch.chdir(repo)
    assert run(["install", "foo", "--target", str(env.target)]) == 0
    assert (env.target / ".claude/agents/reviewer.md").is_file()


def test_install_guard_silent_for_profile_with_target_default(
    env, stub_renderers, monkeypatch
):
    """WHY: a profile with target_default ($HOME) escapes cwd by design — it
    never lands output in the working tree, so the guard must let it through
    even inside a git repo with no --target."""
    _profile_with_default(env, "glob")
    home = env.tmp / "fakehome"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    repo = env.tmp / "somerepo"
    (repo / ".git").mkdir(parents=True)
    monkeypatch.chdir(repo)
    assert run(["install", "glob"]) == 0
    # Escaped to $HOME, never touched cwd.
    assert not (repo / ".agent-profile").exists()


def test_install_guard_silent_when_cwd_not_in_git_repo(
    env, stub_renderers, monkeypatch
):
    """WHY: outside any git repo the cwd fallback is a legitimate staging
    target (build a tarball, inspect a render), so the guard must not fire."""
    make_basic_profile(env.profiles, "foo")
    staging = env.tmp / "staging"  # no .git ancestor under tmp_path
    staging.mkdir()
    monkeypatch.chdir(staging)
    assert run(["install", "foo"]) == 0
    assert (staging / ".claude/agents/reviewer.md").is_file()


def test_install_guard_fires_in_git_subdirectory(
    env, capsys, stub_renderers, monkeypatch
):
    """WHY: _within_git_repo walks ancestors, not just cwd — the real footgun
    is running `ap install foo` from a nested dir inside the repo, not the repo
    root. A guard that only checked cwd would miss every subdirectory case."""
    make_basic_profile(env.profiles, "foo")
    repo = env.tmp / "somerepo"
    (repo / ".git").mkdir(parents=True)
    nested = repo / "pkg" / "sub"
    nested.mkdir(parents=True)
    monkeypatch.chdir(nested)
    assert run(["install", "foo"]) == 1
    assert "git working tree" in capsys.readouterr().err
    assert not (nested / ".agent-profile").exists()


def test_install_guard_fires_when_git_is_a_file_worktree(
    env, capsys, stub_renderers, monkeypatch
):
    """WHY: the docstring claims worktrees (where .git is a FILE, not a dir)
    are also caught. A `.git`-dir-only check would silently dump render output
    into a linked worktree — exactly the tree this guard protects."""
    make_basic_profile(env.profiles, "foo")
    worktree = env.tmp / "wt"
    worktree.mkdir(parents=True)
    (worktree / ".git").write_text("gitdir: /some/repo/.git/worktrees/wt\n")
    monkeypatch.chdir(worktree)
    assert run(["install", "foo"]) == 1
    assert "git working tree" in capsys.readouterr().err
    assert not (worktree / ".agent-profile").exists()


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


def test_launch_no_profile_passthrough(env, stub_renderers, monkeypatch):
    """`launch <harness> -- <args>` with no profile name execs the harness
    with the passthrough args and installs nothing. Regression: the `--`
    boundary used to be folded into the positionals, so the first
    passthrough token (`--resume`) was mis-read as a profile name and the
    command died "profile '--resume' not found"."""
    execed = {}

    def fake_exec(file, args):
        execed["file"] = file
        execed["args"] = args
        raise SystemExit(0)

    monkeypatch.setattr(cli.os, "execvp", fake_exec)
    with pytest.raises(SystemExit):
        run(["launch", "claude", "--", "--resume"])
    assert execed["file"] == "claude"
    assert execed["args"] == ["claude", "--resume"]
    # No profile name => nothing installed.
    assert not (env.target / ".agent-profile" / "manifest.json").exists()


def test_launch_exec_failure_is_clean_error(env, capsys, monkeypatch):
    """A missing harness binary surfaces a clean stderr line + exit 1, not
    an uncaught `FileNotFoundError` traceback out of `os.execvp`."""

    def boom(file, args):
        raise FileNotFoundError(2, "No such file or directory")

    monkeypatch.setattr(cli.os, "execvp", boom)
    assert run(["launch", "claude"]) == 1
    err = capsys.readouterr().err
    assert "cannot exec 'claude'" in err


def test_describe_isolated_surfaces_overlay(env, capsys):
    """describe must surface the launch-overlay fields for an isolated
    profile so the closed world is inspectable (not hidden behind the YAML)."""
    write_profile(
        env.profiles,
        "todo",
        "name: todo\n"
        "description: Todoist-only closed world\n"
        "isolated: true\n"
        "system_prompt: CLAUDE.md\n"
        "tools: [Skill, Read]\n"
        "permissions_deny: [Edit, Write]\n"
        "enabled_plugins:\n"
        '  "todoist-flow@todoist-flow": true\n'
        "extra_args: [--dangerously-skip-permissions]\n"
        "mcps:\n"
        "  - name: todoist\n"
        "    command: npx\n"
        '    args: ["-y", "x"]\n',
    )
    assert run(["describe", "todo"]) == 0
    parsed = json.loads("\n".join(capsys.readouterr().out.splitlines()[2:]))
    assert parsed["isolated"] is True
    assert parsed["tools"] == ["Skill", "Read"]
    assert parsed["permissions"] == {"allow": [], "deny": ["Edit", "Write"]}
    assert parsed["enabled_plugins"] == {"todoist-flow@todoist-flow": True}
    assert parsed["extra_args"] == ["--dangerously-skip-permissions"]
