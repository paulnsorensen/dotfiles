"""Compile live profiles into harness-scoped fragment directories."""

from __future__ import annotations

import filecmp
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any, Protocol

import yaml

from agent_profile import discover
from agent_profile.compiled_types import (
    CompiledFile,
    CompiledManifest,
    CompileTarget,
    MERGED_SETTINGS_BY_HARNESS,
    VALID_COMPILE_HARNESSES,
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


def _load_compile_targets(profile_dir: Path) -> tuple[CompileTarget, ...]:
    profile_yaml = profile_dir / "profile.yaml"
    raw = yaml.safe_load(profile_yaml.read_text()) or {}
    targets = raw.get("compile_targets")
    if not isinstance(targets, dict) or not targets:
        raise CompileError(
            f"ap compile: {profile_yaml} must define compile_targets"
        )

    parsed: list[CompileTarget] = []
    for name, target in targets.items():
        if not isinstance(name, str) or not name:
            raise CompileError("ap compile: compile target names must be strings")
        if not isinstance(target, dict):
            raise CompileError(f"ap compile: compile target '{name}' must be a map")
        symbolic_root = target.get("target_root")
        harnesses = target.get("harnesses")
        if not isinstance(symbolic_root, str) or not symbolic_root:
            raise CompileError(
                f"ap compile: compile target '{name}' needs target_root"
            )
        if not isinstance(harnesses, list) or not harnesses:
            raise CompileError(
                f"ap compile: compile target '{name}' needs harnesses"
            )
        invalid = [h for h in harnesses if h not in VALID_COMPILE_HARNESSES]
        if invalid:
            raise CompileError(
                f"ap compile: compile target '{name}' has invalid harness "
                f"'{invalid[0]}'"
            )
        resolved_root = Path(
            os.path.expandvars(os.path.expanduser(symbolic_root))
        ).resolve()
        parsed.append(
            CompileTarget(
                name=name,
                symbolic_root=symbolic_root,
                resolved_root=resolved_root,
                harnesses=tuple(harnesses),
            )
        )
    return tuple(parsed)


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

    manifest = parse_manifest(profile_dir)
    targets = _load_compile_targets(profile_dir)
    fragments = out / "fragments"
    shutil.rmtree(fragments, ignore_errors=True)
    fragments.mkdir(parents=True, exist_ok=True)

    files: list[CompiledFile] = []
    comparisons: list[FileComparison] = []
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
    )
    manifest_path.write_text(json.dumps(compiled.to_dict(), indent=2) + "\n")
    return compiled


def cmd_compile(args: list[str], renderers: dict[str, _Renderer], out_stream: Any) -> int:
    profile, baseline, out = _parse_args(args)
    compiled = compile_profile(profile, baseline, out, renderers)
    print(compiled.manifest_path, file=out_stream)
    return 0
