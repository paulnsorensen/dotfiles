"""End-to-end: user-owned merged settings survive compile -> apply-compiled.

Spec line 92 / ADR-001: ``ap apply-compiled`` must never overwrite or delete a
user-owned merged settings file. The data-loss regression these pin is compile
emitting ``.claude/settings.json`` as ``generated=True`` (apply clobber-copies
it) or apply reconciling it out of a stale apply state (apply deletes it).
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_profile import apply_compiled, compile_command
from agent_profile.compiled_types import ApplyState
from agent_profile.renderers.registry import build_registry

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_live_global_settings_stay_unmanaged_across_compile_then_apply(
    tmp_path, monkeypatch
):
    home = tmp_path / "home"
    (home / ".claude").mkdir(parents=True)
    settings = home / ".claude" / "settings.json"
    settings.write_text(json.dumps({"userOwnedKey": "keep-me"}) + "\n")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("DOTFILES_DIR", str(REPO_ROOT))

    baseline = tmp_path / "baseline"
    baseline.mkdir()
    out = tmp_path / "out"

    compile_command.compile_profile("live", baseline, out, build_registry())
    manifest = out / "manifest.json"

    data = json.loads(manifest.read_text())
    settings_entries = [
        f for f in data["files"] if f["relative_path"] == ".claude/settings.json"
    ]
    assert settings_entries == []

    apply_compiled.apply_compiled(manifest)

    assert json.loads(settings.read_text()) == {"userOwnedKey": "keep-me"}


def test_apply_does_not_delete_disconnected_global_settings_from_prior_state(
    tmp_path,
):
    root = tmp_path / "home"
    settings = root / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text('{"userOwnedKey": "keep-me"}\n')

    cache = tmp_path / "cache"
    cache.mkdir()
    apply_compiled.write_apply_state(
        cache / apply_compiled.DEFAULT_STATE_FILENAME,
        ApplyState(managed_files=(str(settings),)),
    )

    frag = cache / "fragments/home/claude/.claude/agents/r.md"
    frag.parent.mkdir(parents=True)
    frag.write_text("body\n")

    manifest = {
        "profile": "live",
        "source_id": "/src",
        "manifest_path": str(cache / "manifest.json"),
        "compile_targets": [
            {
                "name": "home",
                "symbolic_root": "$HOME",
                "resolved_root": str(root),
                "harnesses": ["claude"],
            }
        ],
        "files": [
            {
                "target": "home",
                "harness": "claude",
                "fragment_path": str(frag),
                "relative_path": ".claude/agents/r.md",
                "generated": True,
            }
        ],
        "drift": [],
        "user_mcps": [],
    }
    mpath = cache / "manifest.json"
    mpath.write_text(json.dumps(manifest, indent=2) + "\n")

    result = apply_compiled.apply_compiled(mpath)

    assert settings.exists()
    assert json.loads(settings.read_text()) == {"userOwnedKey": "keep-me"}
    assert str(settings) not in result.deleted
