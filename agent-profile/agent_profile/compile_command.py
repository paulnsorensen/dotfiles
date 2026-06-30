"""Compile live profiles into harness-scoped fragment directories."""

from __future__ import annotations

import filecmp
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any, Protocol

from agent_profile import discover
from agent_profile.compiled_types import (
    CompiledFile,
    CompiledManifest,
    CompileTarget,
    MERGED_SETTINGS_BY_HARNESS,
)
from agent_profile.drift import FileComparison, compute_drift
from agent_profile.parse import parse_manifest


class CompileError(Exception):
    """A handled ``ap compile`` failure."""


class _Renderer(Protocol):
    name: str

    def render(
        self, manifest: Any, target: Path, logical_root: Path | None = None
    ) -> list[str]:
        raise NotImplementedError


def _usage() -> str:
    return "Usage: ap compile <profile> --baseline <dir> --out <dir>"


def _require_value(args: list[str], i: int, flag: str) -> str:
    if i + 1 >= len(args):
        raise CompileError(f"ap compile: option '{flag}' requires a value")
    return args[i + 1]


def profile_arg(args: list[str]) -> str:
    """Return the profile positional from ``args``, ignoring flags in any order.

    Mirrors the positional handling in ``_parse_args`` so a caller can pre-check
    the profile before full argument parsing, regardless of flag/positional order.
    Returns "" when no positional is present.
    """
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("--baseline", "--out"):
            i += 2
        elif arg.startswith(("--baseline=", "--out=")):
            i += 1
        else:
            return arg
    return ""

def _parse_args(args: list[str]) -> tuple[str, Path, Path]:
    profile = ""
    baseline: Path | None = None
    out: Path | None = None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--baseline":
            baseline = Path(_require_value(args, i, "--baseline")).resolve()
            i += 2
        elif arg.startswith("--baseline="):
            baseline = Path(arg.split("=", 1)[1]).resolve()
            i += 1
        elif arg == "--out":
            out = Path(_require_value(args, i, "--out")).resolve()
            i += 2
        elif arg.startswith("--out="):
            out = Path(arg.split("=", 1)[1]).resolve()
            i += 1
        elif not profile:
            profile = arg
            i += 1
        else:
            raise CompileError(f"ap compile: unexpected argument '{arg}'")
    if not profile:
        raise CompileError(_usage())
    if baseline is None:
        raise CompileError("ap compile: --baseline is required")
    if out is None:
        raise CompileError("ap compile: --out is required")
    return profile, baseline, out


def _baseline_root(baseline: Path, target: CompileTarget) -> Path:
    home = os.environ.get("HOME")
    if home:
        try:
            rel = target.resolved_root.relative_to(Path(home).resolve())
            return baseline / rel
        except ValueError:
            pass
    named = baseline / target.name
    return named if named.exists() else baseline


def _copy_tree(src: Path, dst: Path) -> None:
    if src.exists():
        shutil.copytree(src, dst, dirs_exist_ok=True)
    else:
        dst.mkdir(parents=True, exist_ok=True)


def _is_merged_settings(harness: str, rel: str) -> bool:
    """True when ``rel`` is a user-owned merged settings file for ``harness``."""
    return rel in MERGED_SETTINGS_BY_HARNESS.get(harness, ())


def _existing(path: Path) -> Path | None:
    return path if path.is_file() else None


def _merged_comparisons(
    target: CompileTarget, harness: str, target_baseline: Path, work: Path
) -> list[FileComparison]:
    """Drift inputs for ``harness``'s merged settings under ``target``.

    Compares the scratch chezmoi baseline, the live target file, and the
    compiled (rendered) result for every merged settings file the harness owns.
    """
    return [
        FileComparison(
            target=target.name,
            relative_path=rel,
            baseline=_existing(target_baseline / rel),
            live=_existing(target.resolved_root / rel),
            compiled=_existing(work / rel),
        )
        for rel in MERGED_SETTINGS_BY_HARNESS.get(harness, ())
    ]


def _changed_files(before: Path, after: Path) -> list[Path]:
    changed: list[Path] = []
    for path in sorted(p for p in after.rglob("*") if p.is_file()):
        rel = path.relative_to(after)
        prior = before / rel
        if not prior.is_file() or not filecmp.cmp(path, prior, shallow=False):
            changed.append(rel)
    return changed


def compile_profile(
    profile: str,
    baseline: Path,
    out: Path,
    renderers: dict[str, _Renderer],
) -> CompiledManifest:
    profile_dir = discover.find_profile_dir(profile)
    if profile_dir is None:
        raise CompileError(f"ap compile: profile '{profile}' not found")

    # parse_manifest already attaches strictly-validated compile_targets
    # (absolute-root, env-resolution, cross-target duplicate-harness, and
    # harness-field coverage all enforced in validate_compile_targets). Consume
    # that single validated path rather than re-parsing the raw YAML weakly.
    manifest = parse_manifest(profile_dir)
    targets = manifest.compile_targets
    if not targets:
        raise CompileError(
            f"ap compile: profile '{profile}' must define compile_targets"
        )
    fragments = out / "fragments"
    shutil.rmtree(fragments, ignore_errors=True)
    fragments.mkdir(parents=True, exist_ok=True)

    files: list[CompiledFile] = []
    comparisons: list[FileComparison] = []
    user_mcps: list[dict[str, Any]] = []
    seen_user_mcps: set[str] = set()
    with tempfile.TemporaryDirectory(prefix="ap-compile-") as tmp:
        tmp_root = Path(tmp)
        for target in targets:
            target_baseline = _baseline_root(baseline, target)
            before = tmp_root / "before" / target.name
            _copy_tree(target_baseline, before)
            for harness in target.harnesses:
                renderer = renderers.get(harness)
                if renderer is None:
                    raise CompileError(
                        f"ap compile: no renderer registered for harness '{harness}'"
                    )
                work = tmp_root / "work" / target.name / harness
                _copy_tree(target_baseline, work)
                # Files render into the scratch `work` dir, but absolute deploy
                # paths a renderer bakes into content (codex hooks.json) must
                # point at where the fragment will be applied — the target's
                # resolved root — not this ephemeral tempdir.
                renderer.render(manifest, work, logical_root=target.resolved_root)
                # User-scope MCP registrations are a live ~/.claude.json write
                # the renderer defers during compile (logical_root is set).
                # Collect the spec here so apply performs it post-gate.
                collect = getattr(renderer, "user_mcp_registrations", None)
                if collect is not None:
                    for reg in collect(manifest):
                        if reg["name"] not in seen_user_mcps:
                            seen_user_mcps.add(reg["name"])
                            user_mcps.append(reg)
                fragment_dir = fragments / target.name / harness
                for rel in _changed_files(before, work):
                    src = work / rel
                    dst = fragment_dir / rel
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
                    posix = rel.as_posix()
                    files.append(
                        CompiledFile(
                            target=target.name,
                            harness=harness,
                            fragment_path=dst,
                            relative_path=posix,
                            # Merged settings carry user content: mark them
                            # not-generated so apply preserves the live file
                            # instead of overwriting it (ADR-001).
                            generated=not _is_merged_settings(harness, posix),
                        )
                    )
                comparisons.extend(
                    _merged_comparisons(target, harness, target_baseline, work)
                )
        # Drift reads the scratch work/baseline files, so compute it before the
        # tempdir is torn down (ADR-003): baseline vs live vs compiled.
        drift = compute_drift(comparisons)

    manifest_path = out / "manifest.json"
    compiled = CompiledManifest(
        profile=manifest.name,
        source_id=str(profile_dir),
        manifest_path=manifest_path,
        targets=targets,
        files=tuple(files),
        drift=tuple(drift),
        user_mcps=tuple(user_mcps),
    )
    manifest_path.write_text(json.dumps(compiled.to_dict(), indent=2) + "\n")
    return compiled


def cmd_compile(args: list[str], renderers: dict[str, _Renderer], out_stream: Any) -> int:
    profile, baseline, out = _parse_args(args)
    compiled = compile_profile(profile, baseline, out, renderers)
    print(compiled.manifest_path, file=out_stream)
    return 0
