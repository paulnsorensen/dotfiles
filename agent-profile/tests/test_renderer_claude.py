"""Byte/string-parity tests for the Claude native-plugin renderer.

Golden fixtures under ``tests/fixtures/golden/claude/`` were captured from
the source bash (``agent-profile/renderers/claude.sh`` on
``origin/paulnsorensen/pr-177-nih-audit``) installing the real ``rust``
profile and a synthetic ``mcptest`` profile against a scratch target. These
tests materialize the same profile inputs, run :class:`ClaudeRenderer`, and
assert the on-disk tree is byte-for-byte identical to the bash output.

Two profiles cover the renderer's surface:

- ``rust`` (includes ``base``): plugin marker + ``.claude-plugin`` manifest
  with merged hook wiring, plugin-scoped + shared agent, skill tree copy,
  command, executable hook script, sorted ``permissions.allow``, and the
  "no ``.mcp.json`` when no claude MCPs" path.
- ``mcptest``: ``.mcp.json`` projection (claude member kept, codex-only
  dropped) and ``models.claude`` frontmatter on agent + command, with the
  shared agent carrying the same claude model (it is the user-scoped file
  Claude resolves ahead of the plugin-scoped copy).
"""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path

import pytest

from agent_profile.parse import parse_manifest
from agent_profile.renderers.base import Renderer
from agent_profile.renderers.claude import ClaudeRenderer

from .conftest import write_profile

GOLDEN = Path(__file__).parent / "fixtures" / "golden" / "claude"


# ─── profile inputs (identical to what golden was captured from) ─────

_BASE_YAML = """\
name: base
description: Generic coding-agent baseline (style, safety, AGENTS.md notes)

settings:
  permissions_allow:
    - "Bash(git status:*)"
    - "Bash(git diff:*)"
    - "Bash(git log:*)"
"""

_RUST_YAML = """\
name: rust
description: Rust toolchain conventions, clippy command, idiomatic reviewer
include:
  - base

agents:
  - name: rust-reviewer
    description: Reviews Rust code for idiomatic patterns, lifetimes, and clippy-clean style.
    tools: [Read, Grep, Glob, Bash]
    body_path: agents/rust-reviewer.md

skills:
  - name: cargo-workflow
    path: skills/cargo-workflow

commands:
  - name: clippy
    description: Run cargo clippy and propose fixes
    body_path: commands/clippy.md

hooks:
  - event: PreToolUse
    matcher: "Bash"
    script: hooks/cargo-check.sh
    harnesses: [claude]

settings:
  permissions_allow:
    - "Bash(cargo:*)"
    - "Bash(rustc:*)"
    - "Bash(rustup:*)"
"""

_RUST_REVIEWER_BODY = """\
You review Rust code for idiomatic style, correctness, and clippy cleanliness.

When invoked, do the following in order:

1. Identify the changed Rust files (`git diff --name-only HEAD`).
2. For each, look for:
   - Unnecessary `.clone()` or `.to_string()` calls.
   - Excessive `.unwrap()` / `.expect()` outside of tests.
   - Missing `#[must_use]` on important return types.
   - Lifetimes that could be elided.
   - Iterator chains that should be `.collect::<Result<_, _>>()`.
   - `match` blocks that should be `if let` / `let else`.
3. Run `cargo clippy --all-targets -- -D warnings` if available and surface anything new.
4. Summarize findings as a short bulleted list with file:line references. Do not rewrite the code; suggest the change.

Be terse. Skip praise. Only flag things that materially affect correctness or idiom.
"""

_CLIPPY_BODY = """\
Run `cargo clippy --all-targets --all-features -- -D warnings` and walk the user through each warning.

For each warning:

1. Quote the file:line reference.
2. Explain what clippy is complaining about in one sentence.
3. Propose the smallest fix that satisfies the lint without changing behavior.
4. Apply the fix only after the user confirms (or if they passed `--auto`).

When done, re-run clippy and report whether the workspace is clean.
"""

_CARGO_CHECK_BODY = """\
#!/usr/bin/env bash
# PreToolUse hook (Bash matcher): warn before destructive cargo calls.
# Exit 0 = allow; exit 2 (per Claude Code hook protocol) = block.

set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

case "$CMD" in
    *"cargo clean"*)
        echo "Blocking: 'cargo clean' wipes target/ — confirm with the user first." >&2
        exit 2 ;;
    *"cargo install"*"--force"*)
        echo "Blocking: 'cargo install --force' overwrites global binaries." >&2
        exit 2 ;;
esac

exit 0
"""

_CARGO_SKILL = """\
---
name: cargo-workflow
description: Standard cargo workflow for build/test/lint cycles.
---

# Cargo Workflow

Use this skill when working on Rust code that compiles via cargo.

## Standard cycle

```bash
cargo check          # fast type-check (use first)
cargo test           # run tests
cargo clippy         # lint (treat warnings as errors)
cargo fmt            # format
```

## Common patterns

- For long-running test suites, prefer `cargo nextest run` if `cargo-nextest` is installed.
- Use `cargo check --message-format=json` when you need structured diagnostics.
- For workspace members, scope with `-p <crate>` to avoid recompiling the world.

## When tests fail

1. Re-run with `--nocapture` to see prints.
2. Run a single test: `cargo test -p <crate> <test_name> -- --exact --nocapture`.
3. For flakes, run with `--test-threads=1` to rule out concurrency.
"""

_NOBODY_YAML = """\
name: nobody
description: agent without body
agents:
  - name: bare-agent
    description: no body file
    tools: [Read]
"""

_MCPTEST_YAML = """\
name: mcptest
description: mcp parity capture
mcps:
  - name: context7
    command: npx
    args: ["-y", "@upstash/context7-mcp"]
    env:
      KEY: VAL
    harnesses: [claude, codex]
  - name: codexonly
    command: foo
    harnesses: [codex]
agents:
  - name: modeled-agent
    description: has a model
    tools: [Read, Bash]
    body_path: agents/modeled-agent.md
    models:
      claude: opus
commands:
  - name: modeled-cmd
    description: cmd with model
    body_path: commands/modeled-cmd.md
    models:
      claude: haiku
"""


def _read_golden(rel: str) -> str:
    return (GOLDEN / rel).read_text()


def _materialize_rust(profiles_root: Path) -> Path:
    write_profile(profiles_root, "base", _BASE_YAML)
    return write_profile(
        profiles_root,
        "rust",
        _RUST_YAML,
        {
            "agents/rust-reviewer.md": _RUST_REVIEWER_BODY,
            "commands/clippy.md": _CLIPPY_BODY,
            "hooks/cargo-check.sh": _CARGO_CHECK_BODY,
            "skills/cargo-workflow/SKILL.md": _CARGO_SKILL,
        },
    )


def _materialize_mcptest(profiles_root: Path) -> Path:
    return write_profile(
        profiles_root,
        "mcptest",
        _MCPTEST_YAML,
        {
            "agents/modeled-agent.md": "agent body here\n",
            "commands/modeled-cmd.md": "cmd body here\n",
        },
    )


@pytest.fixture
def rendered_rust(env):
    """Render the rust profile (incl. base) and return (target, written)."""
    profile_dir = _materialize_rust(env.profiles)
    manifest = parse_manifest(profile_dir)
    written = ClaudeRenderer().render(manifest, env.target)
    return env.target, written


@pytest.fixture
def rendered_mcptest(env):
    profile_dir = _materialize_mcptest(env.profiles)
    manifest = parse_manifest(profile_dir)
    written = ClaudeRenderer().render(manifest, env.target)
    return env.target, written


# ─── protocol / contract ─────────────────────────────────────────────


def test_satisfies_renderer_protocol():
    r = ClaudeRenderer()
    assert isinstance(r, Renderer)
    assert r.name == "claude"


def test_clean_is_noop(env):
    profile_dir = _materialize_rust(env.profiles)
    manifest = parse_manifest(profile_dir)
    r = ClaudeRenderer()
    r.render(manifest, env.target)
    before = sorted(p.read_bytes() for p in env.target.rglob("*") if p.is_file())
    # clean must not touch any whole-file artefact (no merged files here).
    assert r.clean(manifest, env.target) is None
    after = sorted(p.read_bytes() for p in env.target.rglob("*") if p.is_file())
    assert before == after


# ─── rust profile byte parity ────────────────────────────────────────


def test_rust_plugin_marker_manifest_byte_parity(rendered_rust):
    target, _ = rendered_rust
    on_disk = (target / ".claude/plugins/local/rust/plugin.json").read_text()
    assert on_disk == _read_golden("rust/plugin/plugin.json")


def test_rust_loaded_manifest_byte_parity(rendered_rust):
    target, _ = rendered_rust
    on_disk = (
        target / ".claude/plugins/local/rust/.claude-plugin/plugin.json"
    ).read_text()
    assert on_disk == _read_golden("rust/plugin/.claude-plugin/plugin.json")


def test_rust_marker_and_loaded_manifests_are_identical(rendered_rust):
    target, _ = rendered_rust
    root = (target / ".claude/plugins/local/rust/plugin.json").read_text()
    loaded = (
        target / ".claude/plugins/local/rust/.claude-plugin/plugin.json"
    ).read_text()
    assert root == loaded


def test_rust_loaded_manifest_hook_wiring(rendered_rust):
    target, _ = rendered_rust
    data = json.loads(
        (target / ".claude/plugins/local/rust/.claude-plugin/plugin.json").read_text()
    )
    cmd = data["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
    assert cmd == "${CLAUDE_PLUGIN_ROOT}/hooks/cargo-check.sh"
    assert data["hooks"]["PreToolUse"][0]["matcher"] == "Bash"
    # The hooks key must land last (matches jq `.hooks = $h`).
    assert list(data.keys()) == ["name", "version", "description", "hooks"]


def test_rust_plugin_agent_byte_parity(rendered_rust):
    target, _ = rendered_rust
    on_disk = (
        target / ".claude/plugins/local/rust/agents/rust-reviewer.md"
    ).read_text()
    assert on_disk == _read_golden("rust/plugin/agents/rust-reviewer.md")


def test_rust_shared_agent_byte_parity(rendered_rust):
    target, _ = rendered_rust
    on_disk = (target / ".claude/agents/rust-reviewer.md").read_text()
    assert on_disk == _read_golden("rust/shared/.claude/agents/rust-reviewer.md")


def test_rust_plugin_and_shared_agent_differ_in_blank_line(rendered_rust):
    """The plugin-scoped file separates frontmatter from body with a blank
    line (``---\\n\\n``); the shared writer does not (``---\\n``). Asserting
    the difference guards against silently collapsing the two writers."""
    target, _ = rendered_rust
    plugin = (
        target / ".claude/plugins/local/rust/agents/rust-reviewer.md"
    ).read_text()
    shared_md = (target / ".claude/agents/rust-reviewer.md").read_text()
    assert "---\n\nYou review Rust" in plugin
    assert "---\nYou review Rust" in shared_md
    # Shared file is model-neutral and lacks the blank-line separator.
    assert "---\n\nYou review Rust" not in shared_md


def test_rust_command_byte_parity(rendered_rust):
    target, _ = rendered_rust
    on_disk = (target / ".claude/plugins/local/rust/commands/clippy.md").read_text()
    assert on_disk == _read_golden("rust/plugin/commands/clippy.md")


def test_rust_skill_tree_byte_parity(rendered_rust):
    target, _ = rendered_rust
    on_disk = (
        target / ".claude/plugins/local/rust/skills/cargo-workflow/SKILL.md"
    ).read_text()
    assert on_disk == _read_golden(
        "rust/plugin/skills/cargo-workflow/SKILL.md"
    )


def test_rust_hook_script_byte_parity_and_executable(rendered_rust):
    target, _ = rendered_rust
    script = target / ".claude/plugins/local/rust/hooks/cargo-check.sh"
    assert script.read_text() == _read_golden(
        "rust/plugin/hooks/cargo-check.sh"
    )
    mode = script.stat().st_mode
    assert mode & stat.S_IXUSR
    assert mode & stat.S_IXGRP
    assert mode & stat.S_IXOTH


def test_rust_settings_byte_parity_sorted_union(rendered_rust):
    target, _ = rendered_rust
    on_disk = (target / ".claude/plugins/local/rust/settings.json").read_text()
    assert on_disk == _read_golden("rust/plugin/settings.json")
    # Union of base (git) + rust (cargo/rustc/rustup), jq `unique` => sorted.
    allow = json.loads(on_disk)["permissions"]["allow"]
    assert allow == sorted(allow)
    assert "Bash(cargo:*)" in allow
    assert "Bash(git status:*)" in allow


def test_rust_no_mcp_json_when_no_claude_mcps(rendered_rust):
    target, _ = rendered_rust
    assert not (target / ".claude/plugins/local/rust/.mcp.json").exists()


def test_rust_tracked_files_match_bash_manifest(rendered_rust):
    """``render`` must return the exact path set the bash recorded — the
    plugin-dir root and skill-tree root (whole-tree removal markers), the
    shared agent, and every whole-file artefact."""
    _, written = rendered_rust
    expected = {
        ".claude/agents/rust-reviewer.md",
        ".claude/plugins/local/rust",
        ".claude/plugins/local/rust/.claude-plugin/plugin.json",
        ".claude/plugins/local/rust/agents/rust-reviewer.md",
        ".claude/plugins/local/rust/commands/clippy.md",
        ".claude/plugins/local/rust/hooks/cargo-check.sh",
        ".claude/plugins/local/rust/plugin.json",
        ".claude/plugins/local/rust/settings.json",
        ".claude/plugins/local/rust/skills/cargo-workflow",
    }
    assert set(written) == expected
    # No path tracked twice (feeds the install manifest; must dedupe).
    assert len(written) == len(set(written))


# ─── mcptest profile parity (MCP projection + model overrides) ───────


def test_mcptest_mcp_json_byte_parity(rendered_mcptest):
    target, _ = rendered_mcptest
    on_disk = (target / ".claude/plugins/local/mcptest/.mcp.json").read_text()
    assert on_disk == _read_golden("mcptest/plugin/.mcp.json")


def test_mcptest_mcp_json_drops_non_claude_servers(rendered_mcptest):
    target, _ = rendered_mcptest
    servers = json.loads(
        (target / ".claude/plugins/local/mcptest/.mcp.json").read_text()
    )["mcpServers"]
    # context7 is a claude member; codexonly is codex-only and must be absent.
    assert set(servers) == {"context7"}
    assert servers["context7"] == {
        "command": "npx",
        "args": ["-y", "@upstash/context7-mcp"],
        "env": {"KEY": "VAL"},
    }


def test_mcptest_agent_model_frontmatter_byte_parity(rendered_mcptest):
    target, _ = rendered_mcptest
    on_disk = (
        target / ".claude/plugins/local/mcptest/agents/modeled-agent.md"
    ).read_text()
    assert on_disk == _read_golden("mcptest/plugin/agents/modeled-agent.md")
    assert "model: opus" in on_disk


def test_mcptest_command_model_frontmatter_byte_parity(rendered_mcptest):
    target, _ = rendered_mcptest
    on_disk = (
        target / ".claude/plugins/local/mcptest/commands/modeled-cmd.md"
    ).read_text()
    assert on_disk == _read_golden("mcptest/plugin/commands/modeled-cmd.md")
    assert "model: haiku" in on_disk


def test_mcptest_shared_agent_carries_claude_model(rendered_mcptest):
    target, _ = rendered_mcptest
    on_disk = (target / ".claude/agents/modeled-agent.md").read_text()
    assert on_disk == _read_golden(
        "mcptest/shared/.claude/agents/modeled-agent.md"
    )
    # The user-scoped shared file is the one Claude actually resolves — it
    # wins over the plugin-scoped copy (priority 4 > 5), so it MUST carry the
    # claude model (and color/effort/skills). A neutral shared file would
    # silently drop the agent's pinned model. opencode reads its own
    # .opencode/agent/ path (unaffected); Cursor overrides via .cursor/agents/.
    assert "model: opus" in on_disk


def test_mcptest_plugin_manifest_has_no_hooks_key(rendered_mcptest):
    target, _ = rendered_mcptest
    on_disk = (target / ".claude/plugins/local/mcptest/plugin.json").read_text()
    assert on_disk == _read_golden("mcptest/plugin/plugin.json")
    assert "hooks" not in json.loads(on_disk)


# ─── nobody profile: agent without body, no permissions ──────────────


@pytest.fixture
def rendered_nobody(env):
    profile_dir = write_profile(env.profiles, "nobody", _NOBODY_YAML)
    manifest = parse_manifest(profile_dir)
    written = ClaudeRenderer().render(manifest, env.target)
    return env.target, written


def test_nobody_plugin_agent_frontmatter_only_byte_parity(rendered_nobody):
    """A body-less agent writes a frontmatter-only plugin file ending in the
    blank-line separator (``---\\n\\n``) with no body, byte-identical to bash."""
    target, _ = rendered_nobody
    on_disk = (
        target / ".claude/plugins/local/nobody/agents/bare-agent.md"
    ).read_text()
    assert on_disk == _read_golden("nobody/plugin/agents/bare-agent.md")
    assert on_disk.endswith("---\n\n")


def test_nobody_no_shared_agent_when_body_absent(rendered_nobody):
    """No body => no cross-harness shared write (matches bash, which guards
    the shared write on ``[[ -n "$body_abs" ]]``)."""
    target, _ = rendered_nobody
    assert not (target / ".claude/agents/bare-agent.md").exists()
    assert not (target / ".claude/agents").exists()


def test_nobody_no_settings_json_when_no_permissions(rendered_nobody):
    target, _ = rendered_nobody
    assert not (target / ".claude/plugins/local/nobody/settings.json").exists()


def test_nobody_tracked_files_exclude_shared_agent(rendered_nobody):
    _, written = rendered_nobody
    assert set(written) == {
        ".claude/plugins/local/nobody",
        ".claude/plugins/local/nobody/.claude-plugin/plugin.json",
        ".claude/plugins/local/nobody/agents/bare-agent.md",
        ".claude/plugins/local/nobody/plugin.json",
    }


# ─── failure paths (fail fast and loud — parity with bash `return 1`) ─


def test_hook_with_neither_script_nor_command_raises(env):
    yaml_text = """\
name: badhook
description: hook with no execution target
hooks:
  - event: PreToolUse
    matcher: "Bash"
    harnesses: [claude]
"""
    profile_dir = write_profile(env.profiles, "badhook", yaml_text)
    manifest = parse_manifest(profile_dir)
    with pytest.raises(ValueError, match="neither 'script' nor 'command'"):
        ClaudeRenderer().render(manifest, env.target)


def test_hook_with_both_script_and_command_raises(env):
    yaml_text = """\
name: bothhook
description: hook setting both script and command
hooks:
  - event: SessionStart
    script: hooks/h.sh
    command: "/usr/bin/true"
    harnesses: [claude]
"""
    profile_dir = write_profile(
        env.profiles, "bothhook", yaml_text,
        {"hooks/h.sh": "#!/usr/bin/env bash\nexit 0\n"},
    )
    manifest = parse_manifest(profile_dir)
    with pytest.raises(ValueError, match="mutually exclusive"):
        ClaudeRenderer().render(manifest, env.target)


def test_hook_command_literal_is_used_verbatim(env):
    """A `command:` hook renders the literal command with async/timeout and
    no file deploy — the moshi-hook bridge pattern."""
    yaml_text = """\
name: cmdhook
description: literal command hook
hooks:
  - event: Stop
    command: "'/home/paul/.local/bin/moshi-hook' claude-hook"
    async: true
    harnesses: [claude]
  - event: PermissionRequest
    command: "'/home/paul/.local/bin/moshi-hook' claude-hook"
    timeout: 300
    async: false
    harnesses: [claude]
"""
    profile_dir = write_profile(env.profiles, "cmdhook", yaml_text)
    manifest = parse_manifest(profile_dir)
    ClaudeRenderer().render(manifest, env.target)
    data = json.loads(
        (env.target / ".claude/plugins/local/cmdhook/plugin.json").read_text()
    )
    stop = data["hooks"]["Stop"][0]
    assert "matcher" not in stop
    assert stop["hooks"][0]["command"] == "'/home/paul/.local/bin/moshi-hook' claude-hook"
    assert stop["hooks"][0]["async"] is True
    perm = data["hooks"]["PermissionRequest"][0]["hooks"][0]
    assert perm["timeout"] == 300
    assert perm["async"] is False
    # No script file deployed for a command-literal hook.
    hooks_dir = env.target / ".claude/plugins/local/cmdhook/hooks"
    assert not hooks_dir.exists() or not any(hooks_dir.iterdir())


def test_hook_matcher_dropped_for_non_matcher_event(env):
    """A SessionStart entry carrying a matcher (the codex-only source regex,
    e.g. cheese-flair's "startup|resume") must render WITHOUT a matcher on the
    Claude side — Claude only consumes matchers for PreToolUse/PostToolUse.
    Locks parity with `_hook_event_uses_matcher` in agents/hooks/lib.sh so the
    live `ap` render path doesn't leak a dead matcher field Claude ignores."""
    yaml_text = """\
name: matcherhook
description: SessionStart hook that carries a (codex-only) matcher
hooks:
  - event: SessionStart
    matcher: "startup|resume"
    command: "echo hi"
    harnesses: [claude]
  - event: PreToolUse
    matcher: "Bash"
    command: "echo bash"
    harnesses: [claude]
"""
    profile_dir = write_profile(env.profiles, "matcherhook", yaml_text)
    manifest = parse_manifest(profile_dir)
    ClaudeRenderer().render(manifest, env.target)
    data = json.loads(
        (env.target / ".claude/plugins/local/matcherhook/plugin.json").read_text()
    )
    session_block = data["hooks"]["SessionStart"][0]
    assert "matcher" not in session_block, (
        "SessionStart matcher should be dropped on the Claude render"
    )
    # PreToolUse is a matcher event — its matcher must survive.
    assert data["hooks"]["PreToolUse"][0]["matcher"] == "Bash"


def test_hook_with_nonexistent_script_raises(env):
    yaml_text = """\
name: ghosthook
description: hook points at a script that does not exist
hooks:
  - event: PreToolUse
    matcher: "Bash"
    script: hooks/missing.sh
    harnesses: [claude]
"""
    profile_dir = write_profile(env.profiles, "ghosthook", yaml_text)
    manifest = parse_manifest(profile_dir)
    with pytest.raises(FileNotFoundError, match="hook script not found"):
        ClaudeRenderer().render(manifest, env.target)


def test_codex_only_hook_is_skipped_no_wiring(env):
    """A hook scoped to harness=codex must not land in the claude plugin nor
    wire into plugin.json (membership filter parity)."""
    yaml_text = """\
name: codexhook
description: hook for codex only
hooks:
  - event: PreToolUse
    matcher: "Bash"
    script: hooks/codex-only.sh
    harnesses: [codex]
"""
    profile_dir = write_profile(
        env.profiles, "codexhook", yaml_text,
        {"hooks/codex-only.sh": "#!/usr/bin/env bash\nexit 0\n"},
    )
    manifest = parse_manifest(profile_dir)
    ClaudeRenderer().render(manifest, env.target)
    # No hook script copied, and the manifest carries no hooks key.
    assert not (
        env.target / ".claude/plugins/local/codexhook/hooks/codex-only.sh"
    ).exists()
    data = json.loads(
        (env.target / ".claude/plugins/local/codexhook/plugin.json").read_text()
    )
    assert "hooks" not in data


def test_default_membership_hook_without_harnesses_wires_for_claude(env):
    """A hook omitting ``harnesses`` defaults to claude-only and IS wired
    (matches bash `(.harnesses // ["claude"])`)."""
    yaml_text = """\
name: defaulthook
description: hook with no harnesses field
hooks:
  - event: PreToolUse
    matcher: "Bash"
    script: hooks/default.sh
"""
    profile_dir = write_profile(
        env.profiles, "defaulthook", yaml_text,
        {"hooks/default.sh": "#!/usr/bin/env bash\nexit 0\n"},
    )
    manifest = parse_manifest(profile_dir)
    ClaudeRenderer().render(manifest, env.target)
    script = env.target / ".claude/plugins/local/defaulthook/hooks/default.sh"
    assert script.is_file()
    assert script.stat().st_mode & stat.S_IXUSR
    data = json.loads(
        (env.target / ".claude/plugins/local/defaulthook/plugin.json").read_text()
    )
    assert data["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == (
        "${CLAUDE_PLUGIN_ROOT}/hooks/default.sh"
    )


def test_render_is_idempotent_on_rerun(env):
    """Re-rendering the same profile yields byte-identical files and the same
    tracked-path set (install is re-runnable without drift)."""
    profile_dir = _materialize_rust(env.profiles)
    manifest = parse_manifest(profile_dir)
    r = ClaudeRenderer()
    first = r.render(manifest, env.target)
    snapshot = {
        str(p.relative_to(env.target)): p.read_bytes()
        for p in env.target.rglob("*")
        if p.is_file()
    }
    second = r.render(manifest, env.target)
    after = {
        str(p.relative_to(env.target)): p.read_bytes()
        for p in env.target.rglob("*")
        if p.is_file()
    }
    assert first == second
    assert snapshot == after


# ─── user-scope MCP registration (mcp_scope: user) ───────────────────

_MCPTEST_USER_YAML = """\
name: mcpuser
description: user-scope mcp registration
mcp_scope: user
mcps:
  - name: context7
    command: npx
    args: ["-y", "@upstash/context7-mcp"]
    env:
      KEY: VAL
    harnesses: [claude, codex]
  - name: codexonly
    command: foo
    harnesses: [codex]
"""


def _install_fake_claude(tmp_path: Path, monkeypatch) -> Path:
    """Put a fake ``claude`` binary first on PATH that logs each invocation's
    args (one line per call) to a file, and returns that log path."""
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    log = tmp_path / "claude-calls.log"
    shim = bindir / "claude"
    shim.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$*" >> "$AP_TEST_CLAUDE_LOG"\nexit 0\n'
    )
    shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    monkeypatch.setenv("AP_TEST_CLAUDE_LOG", str(log))
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ['PATH']}")
    return log


def test_user_scope_skips_plugin_mcp_json(env, monkeypatch):
    _install_fake_claude(env.tmp, monkeypatch)
    profile_dir = write_profile(env.profiles, "mcpuser", _MCPTEST_USER_YAML)
    manifest = parse_manifest(profile_dir)
    assert manifest.mcp_scope == "user"
    written = ClaudeRenderer().render(manifest, env.target)
    # No plugin .mcp.json, and it is not tracked in the install manifest.
    assert not (
        env.target / ".claude/plugins/local/mcpuser/.mcp.json"
    ).exists()
    assert not any(".mcp.json" in w for w in written)


def test_user_scope_registers_bare_via_cli(env, monkeypatch):
    log = _install_fake_claude(env.tmp, monkeypatch)
    profile_dir = write_profile(env.profiles, "mcpuser", _MCPTEST_USER_YAML)
    ClaudeRenderer().render(parse_manifest(profile_dir), env.target)
    lines = log.read_text().splitlines()
    # remove-then-add per server, idempotent; context7 only (codexonly dropped).
    assert lines == [
        "mcp remove context7 --scope user",
        "mcp add context7 --scope user -e KEY=VAL -- npx -y @upstash/context7-mcp",
    ]


def test_user_scope_clean_removes_via_cli(env, monkeypatch):
    log = _install_fake_claude(env.tmp, monkeypatch)
    profile_dir = write_profile(env.profiles, "mcpuser", _MCPTEST_USER_YAML)
    manifest = parse_manifest(profile_dir)
    ClaudeRenderer().clean(manifest, env.target)
    assert "mcp remove context7 --scope user" in log.read_text().splitlines()


def test_user_scope_missing_cli_fails_loud(env, monkeypatch):
    # PATH with no `claude` -> user-scope render must raise, not silently skip.
    emptybin = env.tmp / "emptybin"
    emptybin.mkdir()
    monkeypatch.setenv("PATH", str(emptybin))
    profile_dir = write_profile(env.profiles, "mcpuser", _MCPTEST_USER_YAML)
    with pytest.raises(FileNotFoundError):
        ClaudeRenderer().render(parse_manifest(profile_dir), env.target)


def test_user_scope_clean_missing_cli_fails_loud(env, monkeypatch):
    # Clean must fail loud too — a silent return would report success while
    # leaving the user-scope registrations behind in ~/.claude.json.
    emptybin = env.tmp / "emptybin"
    emptybin.mkdir()
    monkeypatch.setenv("PATH", str(emptybin))
    profile_dir = write_profile(env.profiles, "mcpuser", _MCPTEST_USER_YAML)
    with pytest.raises(FileNotFoundError):
        ClaudeRenderer().clean(parse_manifest(profile_dir), env.target)
