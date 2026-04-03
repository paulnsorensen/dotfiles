#!/usr/bin/env python3
"""Batch-resolve merge conflicts using mergiraf's structural merge.

Scans the current repo for conflicted files, extracts 3-way inputs from git's
stage slots, runs mergiraf merge on each, and reports which files resolved
cleanly vs which need manual intervention.

Usage:
    python3 batch-resolve.py --dry-run          # Preview only
    python3 batch-resolve.py --apply            # Write resolved files and git add
    python3 batch-resolve.py --dry-run --verbose  # With mergiraf debug output
"""

import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from git_utils import check_mergiraf_support, get_conflicted_files, has_conflict_markers


def run(cmd, env=None, check=True):
    result = subprocess.run(
        cmd, capture_output=True, text=True, timeout=60, env=env
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, result.stdout, result.stderr
        )
    return result


def extract_stage(path, stage):
    result = run(["git", "show", f":{stage}:{path}"], check=False)
    if result.returncode != 0:
        return None
    return result.stdout


def _write_stage_files(tmpdir, base, ours, theirs):
    base_path = os.path.join(tmpdir, "base")
    ours_path = os.path.join(tmpdir, "ours")
    theirs_path = os.path.join(tmpdir, "theirs")
    for fpath, content in [(base_path, base), (ours_path, ours), (theirs_path, theirs)]:
        with open(fpath, "w") as f:
            f.write(content)
    return base_path, ours_path, theirs_path


def _run_mergiraf(stage_paths, path, tmpdir, verbose):
    base_path, ours_path, theirs_path = stage_paths
    out_path = os.path.join(tmpdir, "merged")
    env = None
    if verbose:
        env = {**os.environ, "RUST_LOG": "mergiraf=debug"}
    result = run(
        ["mergiraf", "merge", base_path, ours_path, theirs_path, "-o", out_path, "-p", path],
        env=env, check=False,
    )
    if verbose and result.stderr:
        print(f"  [debug] {path}:", file=sys.stderr)
        for line in result.stderr.strip().splitlines()[:20]:
            print(f"    {line}", file=sys.stderr)
    if not os.path.exists(out_path):
        return None
    with open(out_path) as f:
        return f.read()


def resolve_file(path, apply, verbose):
    info = {"path": path, "supported": False, "resolved": False, "error": None}

    if not check_mergiraf_support(path):
        info["error"] = "not registered for mergiraf"
        return info

    info["supported"] = True

    base = extract_stage(path, 1)
    ours = extract_stage(path, 2)
    theirs = extract_stage(path, 3)

    if base is None or ours is None or theirs is None:
        info["error"] = "missing stage slot (file may be added/deleted, not modified)"
        return info

    with tempfile.TemporaryDirectory() as tmpdir:
        stage_paths = _write_stage_files(tmpdir, base, ours, theirs)
        merged = _run_mergiraf(stage_paths, path, tmpdir, verbose)

        if merged is None:
            info["error"] = "mergiraf produced no output"
            return info

        if not merged.strip():
            info["error"] = "mergiraf produced empty output"
            return info

        if has_conflict_markers(merged):
            info["error"] = "structural merge left conflict markers"
            return info

        info["resolved"] = True

        if apply:
            with open(path, "w") as f:
                f.write(merged)
            run(["git", "add", path])

    return info


def _print_summary(resolved, unresolved, unsupported, files, args):
    print(f"\n{'=' * 50}")
    print(f"Resolved:    {len(resolved)}")
    print(f"Unresolved:  {len(unresolved)}")
    print(f"Unsupported: {len(unsupported)}")
    print(f"Total:       {len(files)}")

    if unresolved:
        print("\nFiles needing manual resolution:")
        for info in unresolved:
            print(f"  {info['path']}: {info['error']}")
        print("\nUse `git mergetool` to resolve remaining conflicts.")

    if args.dry_run and resolved:
        print(f"\nRe-run with --apply to write {len(resolved)} resolved file(s).")


def main():
    parser = argparse.ArgumentParser(description="Batch-resolve merge conflicts with mergiraf")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="Preview only, no file changes")
    mode.add_argument("--apply", action="store_true", help="Write resolved files and git add")
    parser.add_argument("--verbose", action="store_true", help="Show mergiraf debug output")
    args = parser.parse_args()

    files = get_conflicted_files()
    if not files:
        print("No conflicted files found.")
        return

    print(f"Found {len(files)} conflicted file(s)\n")

    resolved = []
    unresolved = []
    unsupported = []

    for path in files:
        info = resolve_file(path, apply=args.apply, verbose=args.verbose)

        if info["resolved"]:
            action = "applied" if args.apply else "would resolve"
            print(f"  {action}: {path}")
            resolved.append(info)
        elif not info["supported"]:
            print(f"  skip (unsupported): {path} — {info['error']}")
            unsupported.append(info)
        else:
            print(f"  CONFLICT: {path} — {info['error']}")
            unresolved.append(info)

    _print_summary(resolved, unresolved, unsupported, files, args)
    sys.exit(1 if unresolved else 0)


if __name__ == "__main__":
    main()
