"""Resolve revision-local references without inventing dependencies."""

from __future__ import annotations

import hashlib
import json
import textwrap
from collections import Counter
from pathlib import PurePosixPath
from typing import Any

MANIFESTS = {"package.json", "Cargo.toml", "pyproject.toml"}


def group_for(path: str, manifests: set[str]) -> tuple[str, str]:
    directory = PurePosixPath(path).parent
    for parent in (directory, *directory.parents):
        manifest = next((name for name in sorted(MANIFESTS) if str(parent / name) in manifests), None)
        if manifest:
            group = str(parent)
            return group, f"manifest: {manifest}"
    first = PurePosixPath(path).parts[0]
    return first if len(PurePosixPath(path).parts) > 1 else ".", "source layout"


def assemble(revision: str, files: dict[str, dict[str, Any]], parsed: dict[str, dict[str, Any]], gaps: list[dict[str, Any]]) -> dict[str, Any]:
    manifests = {path for path in files if PurePosixPath(path).name in MANIFESTS}
    nodes: list[dict[str, Any]] = []
    edges: dict[str, dict[str, Any]] = {}
    unknowns = list(gaps)
    groups: dict[str, dict[str, Any]] = {}
    for path in sorted(files):
        group, basis = group_for(path, manifests)
        groups[group] = {"id": group, "label": group, "basis": basis, "changed": False}
        info = files[path]
        language = info.get("language", "")
        node = {"id": path, "label": PurePosixPath(path).name, "kind": "file", "path": path,
                "group": group, "language": language, "line": 1, "end": 1,
                "blob": info["blob"], "public": True}
        nodes.append(node)
        facts = parsed.get(path)
        if facts is None:
            continue
        unknowns.extend({"path": path, **item} for item in facts.get("unknowns", []))
        for definition in facts.get("defs", []):
            nodes.append({"id": f"{path}::{definition['qual']}", "label": definition["name"],
                          "kind": definition["kind"], "path": path, "group": group,
                          "language": language, "line": definition["line"],
                          "end": definition["end"], "blob": info["blob"],
                          "public": definition["public"]})
    identity_counts = Counter(node["id"] for node in nodes)
    identities = set(identity_counts)
    for path in sorted(parsed):
        facts = parsed[path]
        for ref in facts.get("refs", []):
            matches = sorted(set(ref.get("targets", [])) & identities)
            if len(matches) != 1 or (matches and identity_counts[matches[0]] != 1):
                unknowns.append({"path": path, "line": ref["line"],
                                 "reason": "ambiguous target" if matches else (ref.get("reason") or "unresolved target")})
                continue
            source = f"{path}::{ref['source']}" if ref.get("source") else path
            if identity_counts[source] != 1:
                unknowns.append({"path": path, "line": ref["line"],
                                 "reason": "ambiguous source" if source in identities else "unresolved source"})
                continue
            target = matches[0]
            key = json.dumps([source, target, ref["kind"]], separators=(",", ":"))
            edge_id = hashlib.sha256(key.encode()).hexdigest()[:16]
            edge = edges.get(edge_id)
            if edge is None:
                edge = {"id": edge_id, "source": source, "target": target,
                        "kind": ref["kind"], "line": ref["line"], "path": path,
                        "blob": files[path]["blob"], "sites": []}
                edges[edge_id] = edge
            sites = edge["sites"]
            assert isinstance(sites, list)
            sites.append(ref["line"])
    return {"revision": revision, "nodes": sorted(nodes, key=lambda item: item["id"]),
            "edges": sorted(edges.values(), key=lambda item: item["id"]),
            "unknowns": sorted(unknowns, key=lambda item: (item["path"], item.get("line", 0), item["reason"])),
            "files": {path: {key: value for key, value in info.items() if key in {"blob", "text"}}
                      for path, info in sorted(files.items())},
            "coverage": {"files": len(files), "parsed": len(parsed), "unknowns": len(unknowns),
                         "groups": sorted(groups.values(), key=lambda item: item["id"])}}


def changes(base: dict[str, Any], head: dict[str, Any]) -> dict[str, dict[str, str]]:
    def incomplete(snapshot: dict[str, Any]) -> set[str]:
        return {item["path"] for item in snapshot["unknowns"]
                if item["reason"].startswith("parse failed")
                or item["reason"] in {"large file skipped", "symlink or submodule skipped", "unsupported file"}}

    failed_base = incomplete(base)
    failed_head = incomplete(head)
    failed_either = failed_base | failed_head
    result: dict[str, dict[str, str]] = {"nodes": {}, "edges": {}}
    for kind in ("nodes", "edges"):
        before = {item["id"]: item for item in base[kind]}
        after = {item["id"]: item for item in head[kind]}
        for identity in sorted(before.keys() | after.keys()):
            old = before.get(identity)
            new = after.get(identity)
            item = new if new is not None else old
            assert item is not None
            source_path = item["path"]
            if kind == "edges" and any(endpoint.split("::", 1)[0] in failed_either
                                       for endpoint in (item["source"], item["target"])):
                continue
            if old is None and source_path not in failed_base:
                result[kind][identity] = "added"
            elif new is None and source_path not in failed_head:
                result[kind][identity] = "removed"
            elif old and new and kind == "nodes":
                old_values = {key: value for key, value in old.items() if key not in {"line", "end", "blob"}}
                new_values = {key: value for key, value in new.items() if key not in {"line", "end", "blob"}}
                if old_values != new_values or (old["kind"] == "file" and old["blob"] != new["blob"]):
                    result[kind][identity] = "modified"
                elif old["kind"] != "file" and _body(base, old) != _body(head, new):
                    result[kind][identity] = "modified"
            elif old and new and kind == "edges" and len(old["sites"]) != len(new["sites"]):
                result[kind][identity] = "modified"
    return result


def _body(snapshot: dict[str, Any], node: dict[str, Any]) -> str:
    text = snapshot["files"][node["path"]].get("text", "")
    lines = text.splitlines()[node["line"] - 1:node["end"]]
    return textwrap.dedent("\n".join(lines)).strip()
