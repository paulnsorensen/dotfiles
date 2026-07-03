"""Lock the ``generated`` discriminator and the absent-live drift boundary.

b4d17a4 wired two coupled behaviours into ``compile_profile`` that the existing
suite only pins from one side:

* Each fragment's ``generated`` flag is ``not _is_merged_settings(...)``. The
  preservation test (test_compile_apply_preservation) only asserts merged
  settings are ``generated=False``. If the discriminator regressed to
  *all*-False, apply would stop reconciling/deleting stale generated config
  (spec line 91); if it regressed to *all*-True, apply would clobber user-owned
  merged settings (spec line 92). These tests pin both directions.

* Drift is computed over baseline/live/compiled. A fresh machine with no live
  settings file is a clean create, not drift (drift.py contract) — the
  migration must not spuriously block ``dots sync`` on first deploy.
"""

from __future__ import annotations

import json
from pathlib import Path

from agent_profile import compile_command
from agent_profile.compiled_types import MERGED_SETTINGS_BY_HARNESS
from agent_profile.renderers.registry import build_registry

REPO_ROOT = Path(__file__).resolve().parents[2]

_MERGED_PATHS = {rel for rels in MERGED_SETTINGS_BY_HARNESS.values() for rel in rels}


def _compile_live(tmp_path, monkeypatch, *, with_live_settings: bool) -> dict:
    home = tmp_path / "home"
    home.mkdir(parents=True)
    if with_live_settings:
        (home / ".claude").mkdir()
        (home / ".claude" / "settings.json").write_text(
            json.dumps({"userOwnedKey": "keep-me"}) + "\n"
        )
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("DOTFILES_DIR", str(REPO_ROOT))
    baseline = tmp_path / "baseline"
    baseline.mkdir()
    out = tmp_path / "out"
    compile_command.compile_profile("live", baseline, out, build_registry())
    return json.loads((out / "manifest.json").read_text())


def test_normal_fragments_generated_merged_settings_not(tmp_path, monkeypatch):
    data = _compile_live(tmp_path, monkeypatch, with_live_settings=True)
    files = data["files"]

    generated = {f["relative_path"] for f in files if f["generated"] is True}
    preserved = {f["relative_path"] for f in files if f["generated"] is False}

    # Reconcilable generated config must still exist (spec 91): a regression to
    # all-False would empty this set and silently disable apply's delete pass.
    assert generated, "expected at least one generated=True fragment"

    # Every emitted merged settings file is user-owned (spec 92): a regression to
    # all-True would put these in `generated` and apply would clobber them.
    emitted_merged = {f["relative_path"] for f in files} & _MERGED_PATHS
    assert emitted_merged, "expected the live profile to emit merged settings files"
    assert emitted_merged <= preserved
    # And no generated=True fragment is a merged settings file.
    assert not (generated & _MERGED_PATHS)


def test_absent_live_settings_is_clean_create_not_drift(tmp_path, monkeypatch):
    data = _compile_live(tmp_path, monkeypatch, with_live_settings=False)
    settings_drift = [
        r for r in data["drift"] if r["relative_path"] == ".claude/settings.json"
    ]
    assert settings_drift == [], (
        "a fresh machine with no live settings.json is a clean create, "
        f"not drift, but compile reported: {settings_drift}"
    )
