#!/usr/bin/env python3
"""Resolve lockfile conflicts by regenerating from the manifest.

Merging lockfiles textually is unreliable — the correct approach is to take
one side's manifest (or the merged manifest), then regenerate the lockfile
from scratch. This script automates the established pattern from session history:

    git checkout --theirs Cargo.lock && cargo generate-lockfile

Usage:
    python3 lockfile-resolve.py              # auto-detect conflicted lockfiles
    python3 lockfile-resolve.py --strategy theirs   # take theirs then regen (default)
    python3 lockfile-resolve.py --strategy ours     # take ours then regen
    python3 lockfile-resolve.py --strategy regen    # just regenerate (manifest already resolved)
    python3 lockfile-resolve.py --dry-run           # show what would happen
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from git_utils import has_conflict_markers


LOCKFILE_STRATEGIES = {
    "Cargo.lock": {
        "regen_cmd": ["cargo", "generate-lockfile"],
        "manifest": "Cargo.toml",
        "ecosystem": "Rust/Cargo",
    },
    "package-lock.json": {
        "regen_cmd": ["npm", "install", "--package-lock-only"],
        "manifest": "package.json",
        "ecosystem": "Node/npm",
    },
    "yarn.lock": {
        "regen_cmd": ["yarn", "install", "--frozen-lockfile=false"],
        "manifest": "package.json",
        "ecosystem": "Node/Yarn",
    },
    "pnpm-lock.yaml": {
        "regen_cmd": ["pnpm", "install", "--no-frozen-lockfile"],
        "manifest": "package.json",
        "ecosystem": "Node/pnpm",
    },
    "poetry.lock": {
        "regen_cmd": ["poetry", "lock", "--no-update"],
        "manifest": "pyproject.toml",
        "ecosystem": "Python/Poetry",
    },
    "Pipfile.lock": {
        "regen_cmd": ["pipenv", "lock"],
        "manifest": "Pipfile",
        "ecosystem": "Python/Pipenv",
    },
    "uv.lock": {
        "regen_cmd": ["uv", "lock"],
        "manifest": "pyproject.toml",
        "ecosystem": "Python/uv",
    },
    "Gemfile.lock": {
        "regen_cmd": ["bundle", "lock"],
        "manifest": "Gemfile",
        "ecosystem": "Ruby/Bundler",
    },
    "go.sum": {
        "regen_cmd": ["go", "mod", "tidy"],
        "manifest": "go.mod",
        "ecosystem": "Go",
    },
}

def run(cmd, check=True):
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
    return result


def get_conflicted_lockfiles():
    result = run(["git", "diff", "--name-only", "--diff-filter=U"])
    conflicted = [f for f in result.stdout.strip().splitlines() if f]
    return [f for f in conflicted if os.path.basename(f) in LOCKFILE_STRATEGIES]


def _file_has_conflicts(path):
    try:
        with open(path) as f:
            return has_conflict_markers(f.read())
    except OSError as e:
        raise RuntimeError(f"Failed to read '{path}' while checking for merge conflicts: {e}") from e


def manifest_is_clean(strategy_info, work_dir="."):
    manifest = strategy_info.get("manifest")
    if not manifest:
        return True
    manifest_path = os.path.join(work_dir, manifest)
    if not os.path.exists(manifest_path):
        return True
    return not _file_has_conflicts(manifest_path)


def resolve_lockfile(path, strategy, dry_run):
    """Resolve a single conflicted lockfile.

    Returns (success: bool, message: str)
    """
    filename = os.path.basename(path)
    info = LOCKFILE_STRATEGIES[filename]
    work_dir = os.path.dirname(os.path.abspath(path)) or "."

    if not manifest_is_clean(info, work_dir):
        return False, f"manifest '{info['manifest']}' still has conflicts — resolve it first"

    if strategy in ("ours", "theirs"):
        git_strategy = "--ours" if strategy == "ours" else "--theirs"
        if dry_run:
            print(f"  would: git checkout {git_strategy} -- {path}")
        else:
            run(["git", "checkout", git_strategy, "--", path])
            print(f"  took {strategy}: {path}")

    regen_cmd = info["regen_cmd"]
    if dry_run:
        print(f"  would: {' '.join(regen_cmd)}")
        return True, "dry-run"

    print(f"  regenerating ({info['ecosystem']}): {' '.join(regen_cmd)}")
    result = subprocess.run(regen_cmd, capture_output=True, text=True, timeout=120, cwd=work_dir)
    if result.returncode != 0:
        err = result.stderr.strip() or result.stdout.strip()
        return False, f"regen failed: {err[:200]}"

    run(["git", "add", "--", path])
    print(f"  staged: {path}")
    manifest = info.get("manifest")
    if manifest:
        manifest_path = os.path.join(work_dir, manifest)
        if os.path.exists(manifest_path):
            run(["git", "add", "--", manifest_path])
            print(f"  staged: {manifest_path}")
    return True, "ok"


def _print_results(success, failed):
    print(f"\n{'=' * 40}")
    print(f"Resolved: {len(success)}")
    print(f"Failed:   {len(failed)}")

    if failed:
        print("\nFailed files:")
        for path, msg in failed:
            print(f"  {path}: {msg}")


def main():
    parser = argparse.ArgumentParser(description="Resolve lockfile conflicts by regenerating from manifest")
    parser.add_argument(
        "--strategy",
        choices=["theirs", "ours", "regen"],
        default="theirs",
        help="Which side to seed the regen from (default: theirs)"
    )
    parser.add_argument("--dry-run", action="store_true", help="Show what would happen without changing files")
    parser.add_argument("files", nargs="*", help="Specific lockfiles to resolve (default: auto-detect conflicted)")
    args = parser.parse_args()

    if args.files:
        targets = args.files
    else:
        targets = get_conflicted_lockfiles()

    if not targets:
        print("No conflicted lockfiles found.")
        return

    print(f"Found {len(targets)} conflicted lockfile(s)\n")

    success = []
    failed = []

    for path in targets:
        filename = os.path.basename(path)
        if filename not in LOCKFILE_STRATEGIES:
            print(f"  skip (unknown lockfile type): {path}")
            continue

        print(f"Resolving {path} ({LOCKFILE_STRATEGIES[filename]['ecosystem']})...")
        ok, msg = resolve_lockfile(path, args.strategy, args.dry_run)
        if ok:
            success.append(path)
        else:
            print(f"  FAILED: {msg}")
            failed.append((path, msg))

    _print_results(success, failed)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
