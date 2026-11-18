"""Extract conservative Rust evidence from ast-grep syntax nodes."""

import json
import re
import shutil
import subprocess
import tempfile
from pathlib import PurePosixPath


VERSION = "2"
_ITEM_KINDS = (
    "mod_item,function_item,struct_item,enum_item,trait_item,type_item,"
    "const_item,static_item,impl_item,use_declaration,call_expression,"
    "macro_invocation"
)
_NAMES = {
    "mod_item": "mod",
    "function_item": "fn",
    "struct_item": "struct",
    "enum_item": "enum",
    "trait_item": "trait",
    "type_item": "type",
    "const_item": "const",
    "static_item": "static",
}
_ITEM = re.compile(
    r"^(?:#\[[^\n]*\]\s*)*(pub(?:\([^)]*\))?\s+)?"
    r"(?:(?:async|unsafe|default|const)\s+)*(mod|fn|struct|enum|trait|type|const|static)\s+"
    r"([A-Za-z_][A-Za-z_0-9]*)"
)
_PATH = re.compile(r"(?:crate|self|super|[A-Za-z_][A-Za-z_0-9]*)"
                   r"(?:::[A-Za-z_][A-Za-z_0-9]*)*")


def _site(node):
    span = node["range"]
    return span["byteOffset"]["start"], span["byteOffset"]["end"], span["start"]["line"] + 1


def _container(node, parents):
    start, end, _ = _site(node)
    matches = [parent for parent in parents
               if _site(parent)[0] < start and end <= _site(parent)[1]]
    return min(matches, key=lambda item: _site(item)[1] - _site(item)[0], default=None)


def _scope(node, scopes):
    parts = []
    parent = _container(node, scopes)
    while parent is not None:
        if parent.get("_name"):
            parts.append(parent["_name"])
        parent = _container(parent, scopes)
    return "::".join(reversed(parts))


def _candidate(path, name, source, defs, external):
    if name.startswith("crate::"):
        qual = name.removeprefix("crate::")
    elif name.startswith("self::"):
        qual = "::".join(filter(None, (source.rpartition("::")[0], name.removeprefix("self::"))))
    elif name.startswith("super::"):
        qual = "::".join(filter(None, (source.rpartition("::")[0].rpartition("::")[0], name.removeprefix("super::"))))
    elif "::" in name:
        qual = name
    else:
        scope = source.rpartition("::")[0]
        while True:
            qual = "::".join(filter(None, (scope, name)))
            if qual in defs:
                break
            if not scope:
                return None
            scope = scope.rpartition("::")[0]
    if qual in defs:
        return [f"{path}::{qual}"]
    for prefix in sorted(external, key=len, reverse=True):
        if qual.startswith(f"{prefix}::"):
            remainder = qual[len(prefix) + 2:]
            return [f"{candidate}::{remainder}" for candidate in external[prefix]]
    return None


def extract(path: str, text: str) -> dict:
    """Return local Rust declarations and only locally supported relations."""
    result = {"defs": [], "refs": [], "unknowns": [], "failed": False}
    tool = shutil.which("ast-grep")
    if tool is None:
        result["failed"] = True
        result["unknowns"].append({"line": 1, "reason": "ast-grep is unavailable"})
        return result
    command = [tool, "run", "--kind", _ITEM_KINDS, "--lang", "rust", "--stdin", "--json=compact"]
    try:
        with tempfile.TemporaryDirectory(prefix="rust-adapter-") as trusted_cwd:
            proc = subprocess.run(command, input=text, text=True, capture_output=True,
                                  cwd=trusted_cwd, timeout=15, check=False)
            errors = subprocess.run([tool, "run", "--kind", "ERROR", "--lang", "rust",
                                     "--stdin", "--json=compact"], input=text, text=True,
                                    capture_output=True, cwd=trusted_cwd, timeout=15, check=False)
        if proc.returncode not in (0, 1) or errors.returncode not in (0, 1):
            raise ValueError(proc.stderr.strip() or errors.stderr.strip() or "ast-grep failed")
        nodes = json.loads(proc.stdout)
        syntax_errors = json.loads(errors.stdout)
        if not isinstance(nodes, list) or not isinstance(syntax_errors, list):
            raise ValueError("ast-grep returned non-list JSON")
    except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError) as exc:
        result["failed"] = True
        result["unknowns"].append({"line": 1, "reason": f"Rust parser failed: {exc}"})
        return result

    items = []
    scopes = []
    impls = [node for node in nodes if node["text"].lstrip().startswith("impl ")]
    traits = [node for node in nodes if node["text"].lstrip().startswith("trait ")]
    for node in nodes:
        code = node["text"].lstrip()
        match = _ITEM.match(code)
        if not match or not code.startswith(match.group(0)):
            continue
        kind = match.group(2)
        if kind not in _NAMES.values():
            continue
        if kind == "fn" and (_container(node, impls) or _container(node, traits)):
            result["unknowns"].append({"line": _site(node)[2],
                                       "reason": "impl or trait method identity is unresolved"})
            continue
        node["_name"] = match.group(3)
        node["_kind"] = kind
        items.append(node)
        if kind in ("mod", "fn"):
            scopes.append(node)

    defs = set()
    external = {}
    for node in items:
        name = node["_name"]
        scope = _scope(node, scopes)
        qual = "::".join(filter(None, (scope, name)))
        start, end, line = _site(node)
        visibility = _ITEM.match(node["text"].lstrip()).group(1)
        result["defs"].append({"qual": qual, "name": name, "line": line,
                               "end": node["range"]["end"]["line"] + 1,
                               "kind": node["_kind"], "public": visibility == "pub "})
        defs.add(qual)
        if node["_kind"] == "mod" and node["text"].rstrip().endswith(";"):
            if (node["text"].lstrip().startswith("#[") or re.search(r"#\[[^\]]*\]\s*$", text.encode()[:start].decode("utf-8", "ignore"))
                    or _container(node, [item for item in scopes if item["_kind"] == "fn"])):
                result["unknowns"].append({"line": line, "reason": "external module attributes or function scope are unresolved"})
                continue
            source_path = PurePosixPath(path)
            directory = source_path.parent if source_path.stem in {"lib", "main", "mod"} else source_path.with_suffix("")
            for part in scope.split("::") if scope else []:
                directory /= part
            module_path = directory / name
            candidates = [f"{module_path}.rs", str(module_path / "mod.rs")]
            external[qual] = candidates
            result["refs"].append({"source": qual, "targets": candidates, "kind": "module",
                                   "line": line, "reason": "external module candidate"})
            result["unknowns"].append({"line": line, "reason": "external module body is not in this file"})

    macros = [item for item in nodes if "!(" in item["text"] and item["text"].strip().endswith(")")]
    functions = [item for item in items if item["_kind"] == "fn"]
    for node in nodes:
        code = node["text"].strip()
        start, end, line = _site(node)
        source = _scope(node, scopes)
        if code.startswith("use ") or code.startswith("pub use "):
            name = code.removeprefix("pub ").removeprefix("use ").removesuffix(";").strip()
            if not _PATH.fullmatch(name):
                result["unknowns"].append({"line": line, "reason": "use alias, group, or glob is unresolved"})
                continue
            target = _candidate(path, name, source, defs, external)
            if target:
                result["refs"].append({"source": source, "targets": target, "kind": "use",
                                       "line": line, "reason": "local syntax path"})
            else:
                result["unknowns"].append({"line": line, "reason": "external use path is unresolved"})
        elif code.endswith("()") or ("(" in code and code.endswith(")")):
            callee = code.split("(", 1)[0].strip()
            if "." in callee:
                result["unknowns"].append({"line": line, "reason": "method or trait dispatch is unresolved"})
            elif _PATH.fullmatch(callee):
                function = _container(node, functions)
                shadowed = False
                if function and "::" not in callee:
                    before = function["text"].encode()[:start - _site(function)[0]].decode("utf-8", "ignore")
                    header = before.split("{", 1)[0]
                    params = header.partition("(")[2].rpartition(")")[0]
                    shadowed = bool(re.search(rf"\b{re.escape(callee)}\b", params))
                    shadowed |= any(re.search(rf"\b{re.escape(callee)}\b", match.group(1))
                                    for match in re.finditer(r"\blet\s+([^=;]+)=", before))
                if shadowed or _container(node, macros) or _container(node, impls) or _container(node, traits):
                    result["unknowns"].append({"line": line, "reason": "shadowed or generated call is unresolved"})
                else:
                    target = _candidate(path, callee, source, defs, external)
                    if target:
                        result["refs"].append({"source": source, "targets": target, "kind": "call",
                                               "line": line, "reason": "direct syntax path"})
                    else:
                        result["unknowns"].append({"line": line, "reason": "external or dynamic call is unresolved"})
        if "!(" in code and not code.startswith(("fn ", "pub fn ")):
            result["unknowns"].append({"line": line, "reason": "macro expansion is unresolved"})
    for error in syntax_errors:
        result["failed"] = True
        result["unknowns"].append({"line": _site(error)[2], "reason": "Rust syntax error"})
    return result
