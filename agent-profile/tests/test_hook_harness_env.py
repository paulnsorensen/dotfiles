"""test_hook_harness_env.py — the renderer, not the script, supplies harness
identity to a deployed hook.

The hook must not infer harness identity from an installation path (a
symlinked or relocated deploy root would break a path-based guess). Instead
each renderer prefixes its rendered hook command with DOTFILES_HARNESS=<name>
for its own harness, so the shared bridge script (agents/hooks/*.sh) reads
one env var and never inspects its own path.
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_profile.parse import parse_manifest
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer

from .conftest import write_profile

_HOOK_PROFILE = """\
name: envprof
hooks:
  - name: probe-hook
    event: PreToolUse
    script: hooks/probe.sh
    matcher: "Bash"
    timeout: 5
    harnesses: [claude, codex]
"""


def _materialize(profiles_root: Path) -> Path:
    return write_profile(
        profiles_root,
        "envprof",
        _HOOK_PROFILE,
        {"hooks/probe.sh": "#!/usr/bin/env bash\ntrue\n"},
    )


def test_claude_command_is_prefixed_with_dotfiles_harness_claude(env):
    profile_dir = _materialize(env.profiles)
    manifest = parse_manifest(profile_dir)
    ClaudeRenderer().render(manifest, env.target)
    plugin_mf = env.target / ".claude/plugins/local/envprof/.claude-plugin/plugin.json"
    data = json.loads(plugin_mf.read_text())
    cmd = data["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
    assert cmd.startswith("DOTFILES_HARNESS=claude ")
    assert cmd.endswith("/hooks/probe.sh")


def test_codex_command_is_prefixed_with_dotfiles_harness_codex(env):
    profile_dir = _materialize(env.profiles)
    manifest = parse_manifest(profile_dir)
    CodexRenderer().render(manifest, env.target)
    hooks_json = env.target / ".codex/hooks.json"
    data = json.loads(hooks_json.read_text())
    cmd = data["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
    assert cmd.startswith("DOTFILES_HARNESS=codex bash ")
    assert cmd.endswith("hooks/probe.sh")
