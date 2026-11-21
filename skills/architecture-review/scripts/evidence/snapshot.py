"""Read committed source trees and cache adapter facts by blob identity."""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import subprocess
import tempfile
import tomllib
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import Any

from .graph import assemble, changes
from .rust_adapter import link_crates

LIMIT = 1_000_000
ADAPTERS = {".py": ("python_adapter", "Python"), ".ts": ("typescript_adapter", "TypeScript"),
            ".tsx": ("typescript_adapter", "TypeScript"), ".rs": ("rust_adapter", "Rust")}


def git(repo: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def revision(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}").decode().strip()


def tree(repo: Path, revision_id: str) -> list[tuple[str, str, str, str, str]]:
    rows = []
    for record in git(repo, "ls-tree", "-rlz", revision_id).split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, kind, blob, size = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8", "surrogateescape")
        rows.append((path, mode, kind, blob, size))
    return sorted(rows)


def read_blob(repo: Path, blob: str) -> bytes | None:
    with subprocess.Popen(["git", "-C", str(repo), "cat-file", "blob", blob],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        assert process.stdout is not None
        raw = process.stdout.read(LIMIT + 1)
        if len(raw) > LIMIT:
            process.kill()
            process.communicate()
            return None
        _, stderr = process.communicate()
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, process.args, stderr=stderr)
        return raw


def parse(cache: Path, path: str, blob: str, text: str, module: ModuleType) -> dict[str, Any]:
    version = getattr(module, "VERSION")
    key = hashlib.sha256(json.dumps([path, blob, module.__name__, version]).encode()).hexdigest()
    filename = cache / f"{key}.json"
    try:
        cached = json.loads(filename.read_text())
        if isinstance(cached, dict) and not cached.get("failed") and all(
                isinstance(cached.get(field), list) for field in ("defs", "refs", "unknowns")):
            return cached
    except (OSError, ValueError, UnicodeError):
        pass
    facts = module.extract(path, text)
    if facts.get("failed"):
        return facts
    cache.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=cache, delete=False) as target:
            temp_name = target.name
            json.dump(facts, target, sort_keys=True)
        os.replace(temp_name, filename)
    finally:
        if temp_name is not None and os.path.exists(temp_name):
            os.unlink(temp_name)
    return facts


def rust_crates(repo: Path, rows: list[tuple[str, str, str, str, str]]) -> tuple[dict[str, str], dict[str, str]]:
    """Return library roots by crate name, and the crate root file of each Rust file."""
    present = {row[0] for row in rows}
    crates: dict[str, str] = {}
    roots: dict[str, str] = {}
    for path, _, kind, blob, size in rows:
        if PurePosixPath(path).name != "Cargo.toml" or kind != "blob" or size == "-" or int(size) > LIMIT:
            continue
        try:
            raw = read_blob(repo, blob)
            manifest = tomllib.loads(raw.decode("utf-8")) if raw else {}
        except (subprocess.CalledProcessError, UnicodeError, tomllib.TOMLDecodeError):
            continue
        package = manifest.get("package", {}).get("name")
        library = manifest.get("lib", {})
        if not isinstance(package, str) or not isinstance(library, dict):
            continue
        directory = PurePosixPath(path).parent
        library_root = str(directory / str(library.get("path", "src/lib.rs")).removeprefix("./"))
        binary_root = str(directory / "src/main.rs")
        if library_root in present:
            crates[str(library.get("name") or package).replace("-", "_")] = library_root
        own = library_root if library_root in present else binary_root if binary_root in present else None
        if own:
            roots[str(directory)] = own
    owners = {}
    for path in present:
        if path.endswith(".rs"):
            parent = PurePosixPath(path).parent
            owner = next((roots[str(folder)] for folder in (parent, *parent.parents) if str(folder) in roots), None)
            if owner:
                owners[path] = owner
    return crates, owners


def snapshot(repo: Path, revision_id: str, cache: Path) -> dict[str, Any]:
    files: dict[str, dict[str, Any]] = {}
    parsed: dict[str, dict[str, Any]] = {}
    gaps: list[dict[str, Any]] = []
    rows = tree(repo, revision_id)
    for path, mode, kind, blob, size in rows:
        suffix = Path(path).suffix
        adapter = ADAPTERS.get(suffix)
        files[path] = {"blob": blob}
        if mode == "120000" or kind == "commit":
            gaps.append({"path": path, "line": 0, "reason": "symlink or submodule skipped"})
            continue
        if adapter is None:
            gaps.append({"path": path, "line": 0, "reason": "unsupported file"})
            continue
        if size == "-" or int(size) > LIMIT:
            gaps.append({"path": path, "line": 0, "reason": "large file skipped"})
            continue
        try:
            raw = read_blob(repo, blob)
            if raw is None:
                gaps.append({"path": path, "line": 0, "reason": "large file skipped"})
                continue
            text = raw.decode("utf-8", errors="replace")
        except subprocess.CalledProcessError:
            gaps.append({"path": path, "line": 0, "reason": "parse failed: unreadable blob"})
            continue
        files[path].update({"text": text, "language": adapter[1]})
        module = importlib.import_module(f".{adapter[0]}", package=__package__)
        try:
            facts = parse(cache, path, blob, text, module)
        except (SyntaxError, ValueError, UnicodeError, OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as exc:
            gaps.append({"path": path, "line": 0, "reason": f"parse failed: {type(exc).__name__}"})
            continue
        if facts.get("failed"):
            details = facts.get("unknowns") or [{"line": 0, "reason": "adapter"}]
            gaps.extend({"path": path, "line": item["line"],
                         "reason": f"parse failed: {item['reason']}"} for item in details)
            continue
        parsed[path] = facts
    link_crates(parsed, *rust_crates(repo, rows))
    result = assemble(revision_id, files, parsed, gaps)
    result["coverage"]["adapters"] = {
        "supported": {suffix: {"language": language, "version": getattr(importlib.import_module(f".{name}", package=__package__), "VERSION")}
                      for suffix, (name, language) in ADAPTERS.items()},
        "unsupported": {"extensions": "all other extensions", "max_bytes": LIMIT},
    }
    return result


def build(repo: Path, base: str | None, head: str, cache: Path, focus: str | None = None) -> dict[str, Any]:
    repo = repo.resolve()
    head_id = revision(repo, head)
    base_id = revision(repo, base) if base is not None else None
    current = snapshot(repo, head_id, cache)
    older = snapshot(repo, base_id, cache) if base_id else None
    snapshots = {"head": current}
    if older:
        snapshots["base"] = older
    differences = changes(older, current) if older else {"nodes": {}, "edges": {}}
    all_nodes = {node["id"]: node for side in reversed(tuple(snapshots.values())) for node in side["nodes"]}
    group_by_path = {node["path"]: node["group"] for node in all_nodes.values() if node["kind"] == "file"}
    all_nodes = {node["id"]: node for side in reversed(tuple(snapshots.values())) for node in side["nodes"]}
    group_by_path = {node["path"]: node["group"] for node in all_nodes.values() if node["kind"] == "file"}
    changed_groups: set[str] = set()
    counts: dict[str, int] = {}
    for identity in differences["nodes"]:
        node = all_nodes.get(identity)
        if node is None:
            continue
        group = node["group"]
        changed_groups.add(group)
        path = Path(node["path"])
        nonproduction = bool(set(path.parts) & {"tests", "test", "fixtures", "fixture", "generated", "__generated__"})
        nonproduction |= path.name.startswith("test_") or path.name.endswith(("_test.py", ".test.ts", ".spec.ts"))
        if node["kind"] not in {"file", "module"} and not nonproduction:
            counts[group] = counts.get(group, 0) + 1
    if not counts:
        for identity in differences["nodes"]:
            path = identity.split("::", 1)[0]
            group = group_by_path.get(path)
            if group:
                counts[group] = counts.get(group, 0) + 1
    groups_by_id = {group["id"]: group for side in reversed(tuple(snapshots.values())) for group in side["coverage"]["groups"]}
    groups = sorted(groups_by_id.values(), key=lambda group: group["id"])
    for group in groups:
        group["changed"] = group["id"] in changed_groups
    if focus is not None and focus not in {group["id"] for group in groups}:
        raise ValueError(f"unknown focus group: {focus}")
    selected = focus if focus is not None else (min(counts, key=lambda group: (-counts[group], group)) if counts else None)
    return {"schema": 1, "base": base_id, "head": head_id, "focus": selected,
            "groups": groups, "snapshots": snapshots, "changes": differences}
