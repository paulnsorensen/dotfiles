from __future__ import annotations

from pathlib import Path

import pytest

from agent_profile.compiled_types import (
    CompiledFile,
    CompiledManifest,
    CompileTarget,
)
from agent_profile.merged_settings_preservation import (
    filter_preserved,
    is_user_owned_merged,
    preserved_paths,
)


def _file(relative_path: str, *, generated: bool, target: str = "home") -> CompiledFile:
    return CompiledFile(
        target=target,
        harness="claude",
        fragment_path=Path("/fragments") / target / relative_path,
        relative_path=relative_path,
        generated=generated,
    )


def _manifest(*files: CompiledFile) -> CompiledManifest:
    target = CompileTarget(
        name="home",
        symbolic_root="$HOME",
        resolved_root=Path("/home/user"),
        harnesses=("claude",),
    )
    return CompiledManifest(
        profile="live",
        source_id="profiles/live",
        manifest_path=Path("/cache/manifest.json"),
        targets=(target,),
        files=files,
    )


def test_merged_settings_record_is_user_owned():
    merged = _file("merged/config.json", generated=False)

    assert is_user_owned_merged(merged) is True


def test_generated_fragment_is_not_user_owned():
    generated = _file(".claude/agents/reviewer.md", generated=True)

    assert is_user_owned_merged(generated) is False


def test_generated_defaults_true_so_records_are_reconcilable_by_default():
    # CompiledFile.generated defaults to True; an unmarked record must not be
    # mistaken for a preserved merged file (else reconcile would never delete).
    default = CompiledFile(
        target="home",
        harness="claude",
        fragment_path=Path("/fragments/home/.claude/x"),
        relative_path=".claude/x",
    )

    assert is_user_owned_merged(default) is False


def test_preserved_paths_lists_only_user_owned_merged_records():
    manifest = _manifest(
        _file("merged/config.json", generated=False),
        _file(".claude/agents/reviewer.md", generated=True),
        _file("merged/other.toml", generated=False),
    )

    assert preserved_paths(manifest) == frozenset(
        {"merged/config.json", "merged/other.toml"}
    )


def test_apply_reconcile_never_deletes_user_owned_merged_settings():
    # Acceptance: any generated=False record in the manifest is preserved from
    # reconcile deletion, while dropped generated files stay eligible.
    manifest = _manifest(_file("merged/config.json", generated=False))
    candidates = [
        "merged/config.json",  # user-owned merged -> preserve
        ".claude/agents/stale.md",  # generated, dropped from manifest -> delete
    ]

    safe_to_delete = filter_preserved(candidates, manifest)

    assert "merged/config.json" not in safe_to_delete
    assert safe_to_delete == [".claude/agents/stale.md"]


def test_filter_preserved_preserves_input_order():
    manifest = _manifest(_file("merged/config.json", generated=False))
    candidates = ["b.md", "merged/config.json", "a.md"]

    assert filter_preserved(candidates, manifest) == ["b.md", "a.md"]


def test_works_on_json_manifest_mappings():
    # ap apply-compiled reads the manifest as JSON; the dataclass form is not
    # guaranteed at the call site, so mapping records must behave identically.
    merged = {"relative_path": "merged/config.json", "generated": False}
    generated = {"relative_path": ".claude/hooks.json", "generated": True}
    unmarked = {"relative_path": ".claude/x"}

    assert is_user_owned_merged(merged) is True
    assert is_user_owned_merged(generated) is False
    assert is_user_owned_merged(unmarked) is False

    manifest = {"files": [merged, generated, unmarked]}
    assert preserved_paths(manifest) == frozenset({"merged/config.json"})
    assert filter_preserved(
        ["merged/config.json", ".claude/hooks.json"], manifest
    ) == [".claude/hooks.json"]


def test_empty_manifest_preserves_nothing():
    manifest = _manifest()

    assert preserved_paths(manifest) == frozenset()
    assert filter_preserved(["a", "b"], manifest) == ["a", "b"]


def test_unsupported_record_fails_loud():
    with pytest.raises(TypeError):
        is_user_owned_merged(object())  # type: ignore[arg-type]


def test_unsupported_manifest_fails_loud():
    with pytest.raises(TypeError):
        preserved_paths(object())  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        filter_preserved(["a"], object())  # type: ignore[arg-type]
