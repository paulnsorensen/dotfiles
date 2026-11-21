"""Bounded, revision-aware annotation jobs for the architecture review host.

This module prepares evidence and validates replies. It never invokes a model.
"""

import hashlib
import json
import os
import time
import uuid
from pathlib import Path


SCHEMA = "architecture-review.analysis.v2"
PROMPT_VERSION = 2
MAX_JOBS = 4
MAX_CLAIMS = 12
MAX_EVIDENCE = 12
MAX_INPUT_CHARS = 12000
MAX_OUTPUT_CHARS = 16000
TIMEOUT_SECONDS = 120
QUESTIONS = (
    ("depth", "What must callers know about the public interface, and what does the implementation hide?"),
    ("impact", "What changed at this boundary, and what possible impact follows from cited caller evidence?"),
)
KINDS = {"interface", "hidden", "leak", "change", "impact", "unknown"}


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _digest(value):
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _private_dir(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("cache must not be a symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ValueError("cache must be private")
    return path


def _save(path, value):
    if path.exists() and path.is_symlink():
        raise ValueError("cache file must not be a symlink")
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            json.dump(value, file, sort_keys=True, ensure_ascii=False)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _load(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        return None
    try:
        with path.open(encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return None


def _scope(doc):
    focus = doc.get("focus")
    groups = {group["id"] for group in doc.get("groups", []) if isinstance(group, dict) and "id" in group}
    if focus not in groups:
        return None
    snapshots = doc["snapshots"]
    context = []
    paired = {}
    changes = doc.get("changes", {})
    for side in ("head", "base"):
        snapshot = snapshots.get(side)
        if not snapshot:
            continue
        nodes = snapshot.get("nodes", [])
        selected = {node["id"] for node in nodes if node.get("group") == focus}
        incident = [edge for edge in snapshot.get("edges", [])
                    if edge.get("source") in selected or edge.get("target") in selected]
        selected.update(endpoint for edge in incident for endpoint in (edge["source"], edge["target"]))
        scoped_nodes = [node for node in nodes if node["id"] in selected]
        scoped_paths = {node["path"] for node in scoped_nodes}
        scoped_paths.update(edge["path"] for edge in incident)
        files = {path: snapshot.get("files", {}).get(path) for path in sorted(scoped_paths)}
        context.append({
            "side": side, "nodes": scoped_nodes, "edges": incident, "files": files,
            "unknowns": [item for item in snapshot.get("unknowns", []) if item.get("path") in scoped_paths],
            "changes": {
                "nodes": {key: value for key, value in changes.get("nodes", {}).items() if key in selected},
                "edges": {key: value for key, value in changes.get("edges", {}).items()
                          if any(edge["id"] == key for edge in incident)},
            },
        })
        for item_type, items in (("node", scoped_nodes), ("edge", incident)):
            statuses = changes.get(item_type + "s", {})
            for item in items:
                path = item["path"]
                source = files.get(path)
                blob = item.get("blob")
                if not isinstance(source, dict) or source.get("blob") != blob:
                    continue
                line = item.get("line")
                lines = source.get("text", "").splitlines()
                if not isinstance(line, int) or not 1 <= line <= len(lines):
                    continue
                snippet = "\n".join(lines[max(0, line - 2):min(len(lines), line + 3)])[:800]
                if not snippet.strip():
                    continue
                citation = {
                    "side": side, "path": path, "line": line, "blob": blob,
                    "entity": item["id"], "type": item_type, "text": snippet,
                    "status": statuses.get(item["id"], "unchanged"),
                }
                citation["id"] = _digest(citation)[:24]
                paired.setdefault((item_type, item["id"]), []).append(citation)
    def priority(pair):
        items = pair[1]
        changed = any(item["status"] != "unchanged" for item in items)
        public = any(node.get("public") for context_item in context
                     for node in context_item["nodes"]
                     if node["id"] == items[0]["entity"])
        edge = items[0]["type"] == "edge"
        return (0 if changed and public else 1 if changed and edge else
                2 if changed else 3 if public else 4 if edge else 5,
                items[0]["path"], items[0]["line"], items[0]["entity"])
    ordered = sorted(paired.items(), key=priority)
    first_edge = next((index for index, (key, _) in enumerate(ordered) if key[0] == "edge"), None)
    if first_edge is not None and first_edge > 1:
        ordered.insert(1, ordered.pop(first_edge))
    bounded = []
    used = 0
    for _, pair in ordered:
        pair.sort(key=lambda item: item["side"] != "head")
        size = sum(len(_canonical(item)) for item in pair)
        if len(bounded) + len(pair) > MAX_EVIDENCE or used + size > MAX_INPUT_CHARS:
            continue
        bounded.extend(pair)
        used += size
    return _digest(context), bounded


def _key(scope_hash, model, question):
    return _digest([SCHEMA, PROMPT_VERSION, scope_hash, model, question])


def _empty():
    return {"claims": [], "unknowns": [], "conflicts": [], "citations": {}}


def _annotations(cache, keys, evidence):
    result = _empty()
    available = {item["id"]: {key: value for key, value in item.items() if key != "id"}
                 for item in evidence}
    seen = set()
    for key in keys:
        record = _load(cache / ("assessment-" + key + ".json"))
        if not isinstance(record, dict) or record.get("schema") != SCHEMA or record.get("key") != key:
            result["unknowns"].append("Missing analysis for " + key[:12])
            continue
        for claim in record.get("claims", []):
            cited = claim["evidence_ids"]
            if any(evidence_id not in available for evidence_id in cited):
                continue
            identity = (claim["kind"], claim["claim"].strip().casefold(), tuple(sorted(cited)))
            if identity not in seen:
                seen.add(identity)
                result["claims"].append(claim)
                result["citations"].update((evidence_id, available[evidence_id]) for evidence_id in cited)
        result["unknowns"].extend(record.get("unknowns", []))
    by_citation = {}
    for claim in result["claims"]:
        for evidence_id in claim["evidence_ids"]:
            by_citation.setdefault(evidence_id, []).append(claim)
    for evidence_id, claims in by_citation.items():
        competing = []
        for claim in claims:
            words = set(claim["claim"].casefold().split())
            negative = bool(words & {"no", "not", "never", "without", "cannot", "can't"})
            if any(other["kind"] == claim["kind"] and
                   bool(set(other["claim"].casefold().split()) &
                        {"no", "not", "never", "without", "cannot", "can't"}) != negative
                   for other in claims):
                competing.append(claim["claim"])
        distinct = list(dict.fromkeys(competing))
        if len(distinct) > 1:
            result["conflicts"].append({"evidence_id": evidence_id,
                                        "status": "possible_difference", "claims": distinct})
    result["unknowns"] = list(dict.fromkeys(result["unknowns"]))
    return result


def prepare(doc, model, cache: Path):
    """Return opening-focus jobs and any reusable annotations."""
    cache = _private_dir(cache)
    scoped = _scope(doc)
    if scoped is None:
        return [], {**_empty(), "unknowns": ["No valid focus for analysis"]}
    scope_hash, evidence = scoped
    keys = [_key(scope_hash, model, question) for _, question in QUESTIONS]
    tasks = []
    for (name, question), key in zip(QUESTIONS, keys):
        if _load(cache / ("assessment-" + key + ".json")) is not None:
            continue
        if len(tasks) >= MAX_JOBS:
            break
        expires_at = time.time() + TIMEOUT_SECONDS
        task = {
            "schema": SCHEMA, "id": uuid.uuid4().hex, "focus": doc["focus"],
            "revision": {"base": doc.get("base"), "head": doc["head"]},
            "question": question, "kind": name, "evidence": evidence,
            "budget": {
                "max_claims": MAX_CLAIMS, "max_output_chars": MAX_OUTPUT_CHARS,
                "max_input_chars": MAX_INPUT_CHARS, "max_concurrent": 2,
                "max_jobs": MAX_JOBS, "timeout_seconds": TIMEOUT_SECONDS,
            },
            "expires_at": expires_at,
        }
        _save(cache / ("pending-" + task["id"] + ".json"), {
            "schema": SCHEMA, "key": key, "scope_hash": scope_hash,
            "model": model, "task": task,
        })
        tasks.append(task)
    return tasks, _annotations(cache, keys, evidence)


def _valid_reply(reply, task):
    if not isinstance(reply, dict) or set(reply) - {
        "schema", "id", "focus", "revision", "claims", "unknowns", "expires_at"
    }:
        return False
    try:
        if len(_canonical(reply)) > MAX_OUTPUT_CHARS:
            return False
    except (TypeError, ValueError):
        return False
    if any(reply.get(field) != task[field] for field in ("schema", "id", "focus", "revision")):
        return False
    if "expires_at" in reply and reply["expires_at"] != task["expires_at"]:
        return False
    claims = reply.get("claims")
    unknowns = reply.get("unknowns")
    if not isinstance(claims, list) or len(claims) > MAX_CLAIMS:
        return False
    if not isinstance(unknowns, list) or len(unknowns) > MAX_CLAIMS:
        return False
    if any(not isinstance(value, str) or not value or len(value) > 500 for value in unknowns):
        return False
    allowed = {item["id"] for item in task["evidence"]}
    for claim in claims:
        if not isinstance(claim, dict) or set(claim) != {"kind", "claim", "reasoning", "evidence_ids"}:
            return False
        if not isinstance(claim["kind"], str) or claim["kind"] not in KINDS:
            return False
        if any(not isinstance(claim[field], str) or not claim[field].strip() or len(claim[field]) > 1000
               for field in ("claim", "reasoning")):
            return False
        cited = claim["evidence_ids"]
        if not isinstance(cited, list) or not cited or len(cited) > MAX_EVIDENCE:
            return False
        if any(not isinstance(value, str) or value not in allowed for value in cited):
            return False
    return True


def accept(doc, model, cache: Path, replies: list):
    """Validate task identity and evidence before saving bounded claims."""
    cache = _private_dir(cache)
    scoped = _scope(doc)
    if scoped is None:
        return {**_empty(), "unknowns": ["No valid focus for analysis"]}
    scope_hash, evidence = scoped
    keys = [_key(scope_hash, model, question) for _, question in QUESTIONS]
    if not isinstance(replies, list):
        replies = []
    for reply in replies[:MAX_JOBS]:
        if not isinstance(reply, dict) or not isinstance(reply.get("id"), str):
            continue
        task_id = reply["id"]
        if len(task_id) != 32 or any(char not in "0123456789abcdef" for char in task_id):
            continue
        pending_path = cache / ("pending-" + task_id + ".json")
        pending = _load(pending_path)
        if not isinstance(pending, dict) or pending.get("schema") != SCHEMA:
            continue
        task = pending.get("task")
        if not isinstance(task, dict) or pending.get("model") != model:
            continue
        if (pending.get("scope_hash") != scope_hash or pending.get("key") not in keys or
                task.get("revision") != {"base": doc.get("base"), "head": doc["head"]}):
            continue
        if time.time() > task["expires_at"] or not _valid_reply(reply, task):
            continue
        key = pending["key"]
        _save(cache / ("assessment-" + key + ".json"), {
            "schema": SCHEMA, "key": key, "claims": reply["claims"],
            "unknowns": reply["unknowns"],
        })
        pending_path.unlink(missing_ok=True)
    return _annotations(cache, keys, evidence)
