"""Drift detection is wired into ``ap compile``.

Spec acceptance (specs/ap-chezmoi-compiler.md) + ADR-003: WHEN live merged
settings differ from the scratch chezmoi baseline or compiled result THE SYSTEM
SHALL surface grouped diffs before any apply step. The deployment contract is
that ``ap compile`` records those differences in ``manifest["drift"]`` — the
exact field the ``dots sync`` shell gate (``agent_profile_has_drift`` in
chezmoi/lib/agent-profile-sync.sh) reads to decide whether to prompt/block.

``compile_profile`` calls ``compute_drift`` over each target's merged settings
files (baseline vs live vs compiled), so a divergent live ``settings.json`` is
reported under ``manifest["drift"]``. See .cheese/press/ap-chezmoi-compiler.md.
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_profile import compile_command
from agent_profile.renderers.registry import build_registry

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_compile_records_drift_for_divergent_live_settings(tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / ".claude").mkdir(parents=True)
    # A user-owned key the migration must surface as drift, not silently clobber.
    (home / ".claude" / "settings.json").write_text(
        json.dumps({"userOwnedKey": "keep-me"}) + "\n"
    )
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("DOTFILES_DIR", str(REPO_ROOT))

    baseline = tmp_path / "baseline"
    baseline.mkdir()
    out = tmp_path / "out"

    compile_command.compile_profile("live", baseline, out, build_registry())

    data = json.loads((out / "manifest.json").read_text())
    drift_targets = {(r["target"], r["relative_path"]) for r in data["drift"]}
    assert ("home", ".claude/settings.json") in drift_targets
