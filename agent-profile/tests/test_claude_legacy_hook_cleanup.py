"""test_claude_legacy_hook_cleanup.py — strip orphan hook entries from
``~/.claude/settings.json`` that the retired ``agents/hooks/sync.sh``
jq-merged there before the ap migration (#217).

Claude merges ``settings.json`` hooks with the plugin tree's
``plugin.json`` hooks at load time, so a machine that migrated from the
legacy bash sync to ap fires every managed hook twice — or, for a hook
whose script moved into the plugin and was deleted from
``~/.claude/hooks/``, errors on a dead path every session. The ap Claude
renderer is now responsible for cleaning the legacy entries when it wires
the hooks into the plugin (mirrors the codex renderer's config.toml sweep).

Tests assert: the dead script-hook entry (cheese-flair) is stripped,
command-type duplicates (moshi) are stripped across every event,
user-authored hooks the plugin does NOT manage (JS guards, rtk, a tmux
Stop hook) are preserved, non-hook keys survive, a managed basename
routed through an unmanaged event survives (cross-event invariant), and
the sweep is a no-op when settings.json has no orphans.
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_profile.parse import Manifest
from agent_profile.renderers.claude import (
    ClaudeRenderer,
    _ManagedSigs,
    _managed_signatures_per_event,
    _prune_settings_blocks,
)


def _manifest_with_hooks(src: Path) -> Manifest:
    """A manifest carrying the two hook shapes the migration left behind:
    a script hook (cheese-flair, SessionStart) and a command hook (moshi,
    fanned across SessionStart + Stop)."""
    hooks_dir = src / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    (hooks_dir / "session-start-cheese-flair.sh").write_text(
        "#!/bin/bash\n: cheese flair\n"
    )
    moshi = "'/home/paul/.local/bin/moshi-hook' claude-hook"
    return Manifest(
        name="global",
        description="t",
        hooks=[
            {
                "name": "session-start-cheese-flair",
                "event": "SessionStart",
                "script": "hooks/session-start-cheese-flair.sh",
                "matcher": "startup|resume",
                "timeout": 5,
                "harnesses": ["claude"],
                "_source_dir": str(src),
            },
            {
                "name": "moshi-session-start",
                "event": "SessionStart",
                "command": moshi,
                "harnesses": ["claude"],
                "_source_dir": str(src),
            },
            {
                "name": "moshi-stop",
                "event": "Stop",
                "command": moshi,
                "harnesses": ["claude"],
                "_source_dir": str(src),
            },
        ],
    )


def _seed_legacy_settings(target: Path) -> Path:
    """Pre-seed <target>/.claude/settings.json with pre-ap leftovers PLUS
    legit settings-only hooks (JS guard, rtk, tmux) the plugin never owns."""
    moshi = "'/home/paul/.local/bin/moshi-hook' claude-hook"
    settings = target / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(
        json.dumps(
            {
                "model": "sonnet",
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "Bash",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": 'node "$HOME/.claude/hooks/hook-runner.js" bash-guard.js',
                                },
                                {"type": "command", "command": "rtk hook claude"},
                            ],
                        }
                    ],
                    "SessionStart": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": 'bash "$HOME/.claude/hooks/session-start-cheese-flair.sh"',
                                    "timeout": 5,
                                }
                            ]
                        },
                        {"hooks": [{"type": "command", "command": moshi, "async": True}]},
                    ],
                    "Stop": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": 'if [ -n "$TMUX" ]; then tmux set-option -q @jmux-attention 1; fi',
                                    "timeout": 5,
                                }
                            ]
                        },
                        {"hooks": [{"type": "command", "command": moshi, "async": True}]},
                    ],
                },
            },
            indent=2,
        )
        + "\n"
    )
    return settings


def _render(tmp_path: Path) -> Path:
    src = tmp_path / "src"
    src.mkdir()
    target = tmp_path / "home"
    target.mkdir()
    settings = _seed_legacy_settings(target)
    ClaudeRenderer().render(_manifest_with_hooks(src), target)
    return settings


# ── full-render integration ──────────────────────────────────────────────────


def test_dead_cheese_flair_entry_stripped(tmp_path: Path) -> None:
    settings = _render(tmp_path)
    data = json.loads(settings.read_text())
    # SessionStart held only cheese-flair + moshi → both managed → key gone.
    assert "SessionStart" not in data["hooks"]


def test_moshi_duplicate_stripped_across_events(tmp_path: Path) -> None:
    settings = _render(tmp_path)
    assert "moshi-hook" not in settings.read_text()


def test_tmux_stop_hook_preserved(tmp_path: Path) -> None:
    settings = _render(tmp_path)
    data = json.loads(settings.read_text())
    assert len(data["hooks"]["Stop"]) == 1
    assert "jmux-attention" in data["hooks"]["Stop"][0]["hooks"][0]["command"]


def test_js_guard_and_rtk_preserved(tmp_path: Path) -> None:
    settings = _render(tmp_path)
    text = settings.read_text()
    assert "bash-guard.js" in text
    assert "rtk hook claude" in text
    # The mixed PreToolUse block kept BOTH inner hooks (neither managed).
    data = json.loads(settings.read_text())
    assert len(data["hooks"]["PreToolUse"][0]["hooks"]) == 2


def test_non_hook_keys_preserved(tmp_path: Path) -> None:
    settings = _render(tmp_path)
    data = json.loads(settings.read_text())
    assert data["model"] == "sonnet"


def test_result_is_valid_json(tmp_path: Path) -> None:
    settings = _render(tmp_path)
    json.loads(settings.read_text())  # raises on invalid


def test_idempotent_second_render(tmp_path: Path) -> None:
    src = tmp_path / "src"
    src.mkdir()
    target = tmp_path / "home"
    target.mkdir()
    settings = _seed_legacy_settings(target)
    manifest = _manifest_with_hooks(src)
    ClaudeRenderer().render(manifest, target)
    after_first = settings.read_text()
    ClaudeRenderer().render(manifest, target)
    assert settings.read_text() == after_first


def test_no_settings_file_is_noop(tmp_path: Path) -> None:
    src = tmp_path / "src"
    src.mkdir()
    target = tmp_path / "home"
    target.mkdir()
    # No settings.json seeded → render must not crash or create one.
    ClaudeRenderer().render(_manifest_with_hooks(src), target)
    assert not (target / ".claude" / "settings.json").is_file()


# ── helper units ─────────────────────────────────────────────────────────────


def test_signatures_split_script_basename_vs_command() -> None:
    entries = {
        "SessionStart": [
            {"hooks": [{"command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-cheese-flair.sh"}]},
            {"hooks": [{"command": "'/x/moshi-hook' claude-hook"}]},
        ]
    }
    sigs = _managed_signatures_per_event(entries)
    assert sigs["SessionStart"].basenames == {"session-start-cheese-flair.sh"}
    assert sigs["SessionStart"].commands == {"'/x/moshi-hook' claude-hook"}


def test_cross_event_basename_survives() -> None:
    # A user routing the managed basename through an UNMANAGED event keeps it:
    # the per-event managed set for PreToolUse is empty, so prune is skipped.
    sigs = _managed_signatures_per_event(
        {"SessionStart": [{"hooks": [{"command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-cheese-flair.sh"}]}]}
    )
    assert "PreToolUse" not in sigs


def test_prune_returns_none_when_nothing_matches() -> None:
    arr = [{"hooks": [{"command": "rtk hook claude"}]}]
    assert _prune_settings_blocks(arr, _ManagedSigs(set(), {"moshi"})) is None


def test_prune_keeps_unmanaged_inner_in_mixed_block() -> None:
    arr = [
        {
            "hooks": [
                {"command": "'/x/moshi-hook' claude-hook"},
                {"command": "rtk hook claude"},
            ]
        }
    ]
    rebuilt = _prune_settings_blocks(
        arr, _ManagedSigs(set(), {"'/x/moshi-hook' claude-hook"})
    )
    assert rebuilt == [{"hooks": [{"command": "rtk hook claude"}]}]


def test_user_command_mentioning_managed_basename_survives() -> None:
    # A user hook whose command merely CONTAINS a managed script basename as
    # a non-script substring must NOT be pruned. The old substring matcher
    # (`any(sig in cmd ...)`) wrongly evicted it.
    arr = [{"hooks": [{"command": "echo session-start-cheese-flair.sh ran"}]}]
    sigs = _ManagedSigs({"session-start-cheese-flair.sh"}, set())
    assert _prune_settings_blocks(arr, sigs) is None


def test_user_command_wrapping_managed_command_survives() -> None:
    # A user hook that WRAPS the managed command (extra args / a shell
    # wrapper) is not the managed command — exact equality, not substring,
    # so it survives. The old substring matcher wrongly evicted it.
    managed = "'/x/moshi-hook' claude-hook"
    arr = [{"hooks": [{"command": f'bash -lc "{managed} --extra"'}]}]
    sigs = _ManagedSigs(set(), {managed})
    assert _prune_settings_blocks(arr, sigs) is None


def test_managed_command_exact_match_still_pruned() -> None:
    # The exact managed command IS pruned (the fix must not under-match).
    managed = "'/x/moshi-hook' claude-hook"
    arr = [{"hooks": [{"command": managed}]}]
    assert _prune_settings_blocks(arr, _ManagedSigs(set(), {managed})) == []
