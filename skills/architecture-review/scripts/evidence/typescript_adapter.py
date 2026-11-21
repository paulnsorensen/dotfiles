"""Extract conservative TypeScript evidence with an isolated ast-grep parser."""

import json
import os
import posixpath
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

VERSION = "typescript-ast-grep-1"

_KINDS = (
    "ERROR", "import_statement", "export_statement", "function_declaration",
    "class_declaration", "interface_declaration", "type_alias_declaration",
    "enum_declaration", "method_definition", "lexical_declaration",
    "call_expression",
)
_DECL = {
    "function_declaration": (r"\bfunction\s+([A-Za-z_$][\w$]*)", "function"),
    "class_declaration": (r"\bclass\s+([A-Za-z_$][\w$]*)", "class"),
    "interface_declaration": (r"\binterface\s+([A-Za-z_$][\w$]*)", "interface"),
    "type_alias_declaration": (r"\btype\s+([A-Za-z_$][\w$]*)", "type"),
    "enum_declaration": (r"\benum\s+([A-Za-z_$][\w$]*)", "enum"),
    "method_definition": (r"^\s*(?:public |private |protected |static |async )*([A-Za-z_$][\w$]*)\s*\(", "method"),
}
_NAME = re.compile(r"^[A-Za-z_$][\w$]*$")
_IMPORT = re.compile(r"\bfrom\s*['\"]([^'\"]+)['\"]|\bimport\s*['\"]([^'\"]+)['\"]")
_PARAMS = re.compile(r"\((.*?)\)", re.S)


def _ast_grep() -> str | None:
    paths = [part for part in os.environ.get("PATH", "").split(os.pathsep)
             if part and Path(part).is_absolute()]
    found = shutil.which("ast-grep", path=os.pathsep.join(paths))
    return found if found and Path(found).is_absolute() else None


def _nodes(executable: str, file: Path, kind: str) -> list[dict]:
    run = subprocess.run(
        [executable, "run", "-k", kind, "-l", "tsx" if file.suffix == ".tsx" else "ts",
         "--json=compact", str(file)],
        cwd=file.parent, text=True, capture_output=True, check=False, timeout=15,
    )
    if run.returncode not in (0, 1):
        raise ValueError(f"ast-grep {kind}: {run.stderr.strip() or 'invalid output'}")
    if not run.stdout.strip():
        return []
    data = json.loads(run.stdout)
    if not isinstance(data, list):
        raise ValueError(f"ast-grep {kind}: invalid JSON")
    return data


def _line(node: dict) -> int:
    return node["range"]["start"]["line"] + 1


def _end(node: dict) -> int:
    return node["range"]["end"]["line"] + 1


def _contains(outer: dict, inner: dict) -> bool:
    start, end = outer["range"]["start"], outer["range"]["end"]
    inner_start, inner_end = inner["range"]["start"], inner["range"]["end"]
    return ((start["line"], start["column"]) <= (inner_start["line"], inner_start["column"])
            and (inner_end["line"], inner_end["column"]) <= (end["line"], end["column"])
            and (start != inner_start or end != inner_end))


def _targets(path: str, module: str, name: str) -> list[str]:
    base = posixpath.normpath(posixpath.join(posixpath.dirname(path), module))
    if Path(base).suffix in (".ts", ".tsx"):
        candidates = [base]
    else:
        candidates = [f"{base}.ts", f"{base}.tsx", f"{base}/index.ts", f"{base}/index.tsx"]
    return [f"{candidate}::{name}" if name else candidate for candidate in candidates]


def _imports(path: str, nodes: list[dict], refs: list[dict],
             unknowns: list[dict]) -> dict[str, list[str]]:
    bindings = {}
    for node in nodes:
        raw = node["text"]
        match = _IMPORT.search(raw)
        if not match:
            unknowns.append({"line": _line(node), "reason": "unresolved import syntax"})
            continue
        module = match.group(1) or match.group(2)
        if not module.startswith("."):
            unknowns.append({"line": _line(node), "reason": "external import"})
            continue
        if match.group(2):
            refs.append({"source": "", "targets": _targets(path, module, ""),
                         "kind": "import", "line": _line(node), "reason": "side-effect import"})
            continue
        named = re.search(r"\{([^}]*)\}", raw, re.S)
        if not named:
            unknowns.append({"line": _line(node), "reason": "default or namespace import unresolved"})
            continue
        for item in named.group(1).split(","):
            part = item.strip()
            if not part:
                continue
            type_only = bool(re.match(r"^type\s+", part)) or bool(re.match(r"^import\s+type\b", raw))
            part = re.sub(r"^type\s+", "", part)
            pieces = re.split(r"\s+as\s+", part)
            if len(pieces) > 2 or not all(_NAME.fullmatch(p) for p in pieces):
                unknowns.append({"line": _line(node), "reason": "unresolved import binding"})
                continue
            original, local = pieces[0], pieces[-1]
            targets = _targets(path, module, original)
            refs.append({"source": "", "targets": targets, "kind": "type_import" if type_only else "import",
                         "line": _line(node), "reason": "relative named import"})
            if not type_only:
                bindings[local] = targets
    return bindings


def _definitions(path: str, nodes: dict[str, list[dict]]) -> tuple[list[dict], list[tuple[dict, str]]]:
    entries = []
    for kind, (pattern, label) in _DECL.items():
        for node in nodes[kind]:
            match = re.search(pattern, node["text"])
            if match:
                entries.append((node, match.group(1), label))
    for node in nodes["lexical_declaration"]:
        match = re.match(r"\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>", node["text"])
        if match:
            entries.append((node, match.group(1), "function"))
    exports = nodes["export_statement"]
    exported_names = set()
    for export in exports:
        match = re.fullmatch(r"export\s*\{([^}]*)\}\s*;?", export["text"].strip(), re.S)
        if match:
            exported_names.update(part.strip().split(" as ")[0]
                                  for part in match.group(1).split(",") if part.strip())
    defs = []
    locations = []
    for node, name, label in entries:
        parents = [(other, other_name) for other, other_name, _ in entries
                   if _contains(other, node) and other is not node]
        parents.sort(key=lambda item: item[0]["range"]["start"]["line"])
        qual = ".".join([parent_name for _, parent_name in parents] + [name])
        public = bool(not parents and (name in exported_names or
                      any(_contains(export, node) for export in exports)))
        defs.append({"qual": qual, "name": name, "line": _line(node), "end": _end(node),
                     "kind": label, "public": public})
        locations.append((node, qual))
    return defs, locations


def _calls(path: str, nodes: dict[str, list[dict]], defs: list[dict],
           locations: list[tuple[dict, str]], bindings: dict[str, list[str]],
           refs: list[dict], unknowns: list[dict]) -> None:
    declarations = {qual: node for node, qual in locations}
    functions = [item for item in defs if item["kind"] == "function"]
    for node in nodes["call_expression"]:
        owners = [(outer, qual) for outer, qual in locations if _contains(outer, node)]
        owners.sort(key=lambda item: (item[0]["range"]["end"]["line"] -
                                       item[0]["range"]["start"]["line"],
                                       item[0]["range"]["end"]["column"] -
                                       item[0]["range"]["start"]["column"]))
        source = owners[0][1] if owners else ""
        call = node["text"].split("(", 1)[0].strip()
        if not _NAME.fullmatch(call):
            unknowns.append({"line": _line(node), "reason": "dynamic or member call unresolved"})
            continue
        owner = declarations.get(source)
        params = _PARAMS.search(owner["text"]) if owner else None
        if params and re.search(rf"\b{re.escape(call)}\b", params.group(1)):
            unknowns.append({"line": _line(node), "reason": "shadowed parameter call unresolved"})
            continue
        shadowed = any(
            re.match(rf"\s*(?:const|let|var)\s+{re.escape(call)}\b", item["text"])
            and (not owner or _contains(owner, item))
            for item in nodes["lexical_declaration"]
        )
        if shadowed:
            unknowns.append({"line": _line(node), "reason": "shadowed variable call unresolved"})
            continue
        candidates = [item["qual"] for item in functions if item["name"] == call
                      and (item["qual"] == call or item["qual"] == f"{source}.{call}")]
        if call in bindings and candidates:
            unknowns.append({"line": _line(node), "reason": "ambiguous call binding"})
            continue
        if call in bindings:
            targets = bindings[call]
            reason = "relative named import binding"
        elif len(candidates) == 1:
            targets = [f"{path}::{candidates[0]}"]
            reason = "local declaration binding"
        else:
            unknowns.append({"line": _line(node), "reason": "dynamic or unknown call binding"})
            continue
        refs.append({"source": source, "targets": targets, "kind": "call",
                     "line": _line(node), "reason": reason})


def extract(path: str, text: str) -> dict:
    """Return evidence without executing code or target configuration."""
    result = {"defs": [], "refs": [], "unknowns": [], "failed": False}
    executable = _ast_grep()
    if not executable:
        result["failed"] = True
        result["unknowns"].append({"line": 1, "reason": "ast-grep unavailable"})
        return result
    try:
        with tempfile.TemporaryDirectory(prefix="architecture-ts-") as directory:
            file = Path(directory) / ("input.tsx" if path.endswith(".tsx") else "input.ts")
            file.write_text(text, encoding="utf-8")
            nodes = {kind: _nodes(executable, file, kind) for kind in _KINDS}
        if nodes["ERROR"]:
            result["failed"] = True
            result["unknowns"].extend({"line": _line(node), "reason": "TypeScript parse error"}
                                      for node in nodes["ERROR"])
            return result
        defs, locations = _definitions(path, nodes)
        result["defs"] = defs
        bindings = _imports(path, nodes["import_statement"], result["refs"], result["unknowns"])
        _calls(path, nodes, defs, locations, bindings, result["refs"], result["unknowns"])
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        result["failed"] = True
        result["unknowns"].append({"line": 1, "reason": f"TypeScript parser failure: {error}"})
    return result
