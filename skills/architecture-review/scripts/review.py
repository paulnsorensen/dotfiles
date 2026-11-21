#!/usr/bin/env python3
"""Create an offline architecture review from committed Git evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

if sys.version_info < (3, 12):
    raise SystemExit("architecture-review: Python 3.12 or later is required")
sys.dont_write_bytecode = True

from analysis import accept, prepare
from evidence import build
from viewer import render
from walk import build_walk


MAX_REPLIES = 256_000
MARKER = ".architecture-review-owned"


def arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a revision-pinned offline architecture viewer.")
    parser.add_argument("repo", type=Path, help="Git repository to inspect")
    revisions = parser.add_mutually_exclusive_group()
    revisions.add_argument("--rev", help="Single commit to review (default: HEAD)")
    revisions.add_argument("--base", help="Base commit for a direct tree comparison")
    parser.add_argument("--head", help="Head commit; required with --base")
    focus = parser.add_mutually_exclusive_group()
    focus.add_argument("--focus", help="Open this subsystem")
    focus.add_argument("--explain", help="Request analysis for this subsystem")
    parser.add_argument("--out", type=Path, help="Private output directory")
    parser.add_argument("--cache", type=Path, help="Private evidence and assessment cache")
    parser.add_argument("--model", help="Available lower-tier model name; only the host dispatches workers")
    parser.add_argument("--replies", type=Path, help="JSON array of replies for earlier scheduled tasks")
    args = parser.parse_args(argv)
    if (args.base is None) != (args.head is None):
        parser.error("--base and --head must be supplied together")
    if args.rev and args.head:
        parser.error("--rev cannot be combined with --head")
    if args.replies and not args.model:
        parser.error("--replies requires --model used when tasks were scheduled")
    if args.explain and not args.base:
        parser.error("--explain requires a base/head comparison")
    return args


def no_symlink_components(path: Path) -> None:
    current = path.absolute()
    for item in (current, *current.parents):
        if item.is_symlink():
            raise ValueError(f"symlink output path is not allowed: {item}")


def private_directory(path: Path, *, owned: bool = True) -> Path:
    no_symlink_components(path)
    if path.exists():
        if not path.is_dir():
            raise ValueError(f"not a directory: {path}")
        details = path.stat()
        if details.st_uid != os.getuid() or details.st_mode & 0o077:
            raise ValueError(f"directory must be private and owned by this user: {path}")
        marker = path / MARKER
        if owned and any(path.iterdir()):
            if marker.is_symlink() or not marker.is_file() or marker.read_text(encoding="ascii") != "architecture-review v1\n":
                raise ValueError(f"refusing unmanaged output directory: {path}")
    else:
        path.mkdir(mode=0o700, parents=True)
    if owned and not (path / MARKER).exists():
        (path / MARKER).write_text("architecture-review v1\n", encoding="ascii")
    return path


def safe_file(path: Path, content: str) -> None:
    """Replace only a regular file inside an owned output directory."""
    if path.exists() or path.is_symlink():
        mode = path.lstat().st_mode
        if not stat.S_ISREG(mode):
            raise ValueError(f"refusing non-regular output: {path}")
    descriptor, temporary = tempfile.mkstemp(prefix=".review-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_replies(path: Path) -> list[dict]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("replies must be a regular file")
    if path.stat().st_size > MAX_REPLIES:
        raise ValueError("replies exceed size limit")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, list) or len(value) > 4 or not all(isinstance(item, dict) for item in value):
        raise ValueError("replies must be a JSON array with at most four objects")
    return value


def default_cache(repo: Path) -> Path:
    configured = os.environ.get("XDG_CACHE_HOME")
    if configured:
        root = Path(configured)
        if not root.is_absolute():
            raise ValueError("XDG_CACHE_HOME must be an absolute path")
    elif sys.platform == "darwin":
        root = Path.home() / "Library" / "Caches"
    else:
        root = Path.home() / ".cache"
    repo_key = hashlib.sha256(os.fsencode(repo)).hexdigest()
    return root / "architecture-review" / repo_key


def run(argv: list[str]) -> dict:
    args = arguments(argv)
    repo = args.repo.resolve(strict=True)
    if not repo.is_dir():
        raise ValueError(f"not a repository directory: {repo}")
    if args.out is None:
        out = Path(tempfile.mkdtemp(prefix="architecture-review-"))
        (out / MARKER).write_text("architecture-review v1\n", encoding="ascii")
    else:
        out = args.out
    out = private_directory(out)
    cache = private_directory(args.cache if args.cache else default_cache(repo), owned=False)
    doc = build(repo, args.base, args.rev or args.head or "HEAD", cache,
                args.focus or args.explain)
    walk = build_walk(doc)
    if walk:
        doc["walk"] = walk
    viewer = out / "index.html"
    safe_file(viewer, render(doc))  # Publish static evidence before scheduling any worker.
    tasks: list[dict] = []
    if args.replies:
        annotations = accept(doc, args.model, cache, read_replies(args.replies))
        worker_status = "replies-processed"
    elif args.model and doc.get("focus"):
        tasks, annotations = prepare(doc, args.model, cache)
        worker_status = "pending" if tasks else "cached"
    elif doc.get("focus"):
        annotations = {"claims": [], "unknowns": ["Worker model unavailable; static evidence only."], "conflicts": []}
        worker_status = "unavailable"
    else:
        annotations = {"claims": [], "unknowns": [], "conflicts": []}
        worker_status = "no-change" if args.base else "repository"
    doc["annotations"] = annotations
    safe_file(viewer, render(doc))
    task_paths: list[str] = []
    if tasks:
        task_dir = private_directory(out / "tasks")
        for task in tasks:
            task_id = task["id"]
            if not isinstance(task_id, str) or len(task_id) > 128 or not all(char in "0123456789abcdef" for char in task_id):
                raise ValueError("invalid task ID")
            path = task_dir / f"{task_id}.json"
            safe_file(path, json.dumps(task, ensure_ascii=True, indent=2) + "\n")
            task_paths.append(str(path))
    if not args.replies:
        safe_file(out / "tasks.json", json.dumps(task_paths, indent=2) + "\n")
    return {"viewer": str(viewer), "head": doc["head"], "base": doc["base"],
            "focus": doc.get("focus"), "groups": len(doc["groups"]),
            "walk_entries": len(walk["entries"]) if walk else 0,
            "tasks": task_paths, "worker_status": worker_status,
            "claims": len(annotations.get("claims", [])),
            "missing": [item for item in annotations.get("unknowns", [])
                        if item.startswith("Missing analysis") or item.startswith("Worker model unavailable")],
            "unknowns": annotations.get("unknowns", []),
            "conflicts": len(annotations.get("conflicts", []))}


def main() -> int:
    try:
        print(json.dumps(run(sys.argv[1:]), ensure_ascii=True))
        return 0
    except subprocess.CalledProcessError:
        print("architecture-review: invalid Git revision or repository", file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, UnicodeError) as exc:
        print(f"architecture-review: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
