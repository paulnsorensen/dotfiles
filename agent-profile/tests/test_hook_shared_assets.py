"""test_hook_shared_assets.py — hook shared_assets are deployed alongside
the script so the self-locating SessionStart script resolves its lib/bank
(spec curd 5).

The session-start-cheese-flair.sh hook resolves LIB at
``$(dirname $SCRIPT_DIR)/lib/<file>`` and BANK at ``.../reference/<file>``.
Under the claude plugin layout the script lands at
``.claude/plugins/local/<profile>/hooks/<script>``, so its HARNESS_ROOT is the
plugin dir; assets must land at ``<plugin>/lib/...`` and ``<plugin>/reference/...``.
Under codex the script lands at ``.codex/hooks/<script>`` so HARNESS_ROOT is
``.codex/``; assets land at ``.codex/lib/...`` and ``.codex/reference/...``.

The deployed asset path drops the leading repo subdir (``agents/``) and roots
the remainder (``lib/<file>``) at the harness root — matching the chezmoi
``agents/<subdir>/<file>`` -> ``~/.<harness>/<subdir>/<file>`` deploy rule.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from agent_profile.parse import parse_manifest
from agent_profile.renderers.base import shared_asset_relpath
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer

from .conftest import write_profile

_HOOK_PROFILE = """\
name: flairprof
hooks:
  - name: session-start-cheese-flair
    event: SessionStart
    script: hooks/flair.sh
    shared_assets:
      - agents/lib/cheese-flair.sh
      - agents/reference/cheese-flair.md
    matcher: "startup|resume"
    timeout: 5
    harnesses: [claude, codex]
"""


def _materialize(profiles_root: Path) -> Path:
    return write_profile(
        profiles_root,
        "flairprof",
        _HOOK_PROFILE,
        {
            "hooks/flair.sh": "#!/usr/bin/env bash\necho flair\n",
            "agents/lib/cheese-flair.sh": "# the lib\ncheese_sample() { :; }\n",
            "agents/reference/cheese-flair.md": "# the bank\n- Cheese Lord\n",
        },
    )


# ─── shared_asset_relpath unit (the deploy-path derivation) ───────────


def test_relpath_drops_leading_repo_subdir():
    # The chezmoi rule: agents/<subdir>/<file> -> <subdir>/<file> rooted at
    # the harness root. The leading `agents/` component is dropped.
    assert shared_asset_relpath("agents/lib/cheese-flair.sh") == "lib/cheese-flair.sh"
    assert (
        shared_asset_relpath("agents/reference/cheese-flair.md")
        == "reference/cheese-flair.md"
    )


def test_relpath_keeps_deeper_subdirs():
    # Only the FIRST component is dropped; deeper structure is preserved.
    assert shared_asset_relpath("agents/lib/sub/x.sh") == "lib/sub/x.sh"


def test_relpath_single_component_passthrough():
    # A bare filename (no leading subdir) has nothing to drop and passes
    # through unchanged — the len(parts) <= 1 branch.
    assert shared_asset_relpath("flair.sh") == "flair.sh"


# ─── claude ───────────────────────────────────────────────────────────


@pytest.fixture
def rendered_claude(env):
    profile_dir = _materialize(env.profiles)
    manifest = parse_manifest(profile_dir)
    written = ClaudeRenderer().render(manifest, env.target)
    return env.target, written


def test_claude_copies_shared_assets_into_plugin_subdirs(rendered_claude):
    target, _ = rendered_claude
    plugin = target / ".claude/plugins/local/flairprof"
    lib = plugin / "lib/cheese-flair.sh"
    bank = plugin / "reference/cheese-flair.md"
    assert lib.is_file()
    assert bank.is_file()
    assert lib.read_text() == "# the lib\ncheese_sample() { :; }\n"
    assert bank.read_text() == "# the bank\n- Cheese Lord\n"


def test_claude_shared_assets_are_tracked(rendered_claude):
    _, written = rendered_claude
    assert ".claude/plugins/local/flairprof/lib/cheese-flair.sh" in written
    assert ".claude/plugins/local/flairprof/reference/cheese-flair.md" in written


def test_claude_self_location_invariant(rendered_claude):
    # The script's HARNESS_ROOT = dirname(hooks/) = the plugin dir. The lib
    # it sources must sit at <HARNESS_ROOT>/lib/<file> for the hook to work.
    target, _ = rendered_claude
    plugin = target / ".claude/plugins/local/flairprof"
    script = plugin / "hooks/flair.sh"
    assert script.is_file()
    harness_root = script.parent.parent
    assert (harness_root / "lib/cheese-flair.sh").is_file()
    assert (harness_root / "reference/cheese-flair.md").is_file()


def test_claude_missing_shared_asset_fails_loud(env):
    profile_dir = write_profile(
        env.profiles,
        "badassets",
        "name: badassets\n"
        "hooks:\n  - name: h\n    event: SessionStart\n    script: hooks/h.sh\n"
        "    shared_assets: [agents/lib/missing.sh]\n",
        {"hooks/h.sh": "#!/bin/bash\n"},
    )
    manifest = parse_manifest(profile_dir)
    with pytest.raises(FileNotFoundError, match="missing.sh"):
        ClaudeRenderer().render(manifest, env.target)


# ─── codex ──────────────────────────────────────────────────────────────


@pytest.fixture
def rendered_codex(env):
    profile_dir = _materialize(env.profiles)
    manifest = parse_manifest(profile_dir)
    written = CodexRenderer().render(manifest, env.target)
    return env.target, written


def test_codex_copies_shared_assets_into_harness_root_subdirs(rendered_codex):
    target, _ = rendered_codex
    lib = target / ".codex/lib/cheese-flair.sh"
    bank = target / ".codex/reference/cheese-flair.md"
    assert lib.is_file()
    assert bank.is_file()
    assert lib.read_text() == "# the lib\ncheese_sample() { :; }\n"


def test_codex_shared_assets_are_tracked(rendered_codex):
    _, written = rendered_codex
    assert ".codex/lib/cheese-flair.sh" in written
    assert ".codex/reference/cheese-flair.md" in written


def test_codex_self_location_invariant(rendered_codex):
    # The codex script lands at .codex/hooks/flair.sh -> HARNESS_ROOT = .codex/.
    target, _ = rendered_codex
    script = target / ".codex/hooks/flair.sh"
    assert script.is_file()
    harness_root = script.parent.parent
    assert (harness_root / "lib/cheese-flair.sh").is_file()
    assert (harness_root / "reference/cheese-flair.md").is_file()
