"""Static call walk over Python changes for the offline viewer.

The walk starts at entry points and follows public calls depth first, in
call order. Private helpers stay as folded call sites. The module reads only
the head and base source text that the snapshots already hold. It never runs
repository code.
"""

from __future__ import annotations

import ast
import difflib
import re
from pathlib import PurePosixPath
from typing import Any

FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)
E2E_PATH = re.compile(r"integration|e2e|end_to_end")
LIMITS = [
    "Python only; other languages stay in the subsystem map.",
    "Calls are resolved from source text, not observed at run time.",
    "A call on an object resolves only through self, a local SomeClass() binding, or a method name that one class hierarchy or Protocol owns.",
    "Removed functions are not walked; use Compare revisions in the subsystem map.",
]


def is_test_path(path: str) -> bool:
    parts = PurePosixPath(path)
    return (bool({"tests", "test"} & set(parts.parts[:-1])) or parts.name.startswith("test_")
            or parts.name.endswith("_test.py") or parts.name == "conftest.py")


def is_public(qual: str) -> bool:
    return all(not part.startswith("_") or (part.startswith("__") and part.endswith("__"))
               for part in qual.split("."))


def signature(lines: list[str], node: ast.FunctionDef | ast.AsyncFunctionDef) -> str:
    end = max(node.lineno, node.body[0].lineno - 1 if node.body else node.lineno)
    text = " ".join(line.strip() for line in lines[node.lineno - 1:end])
    text = re.sub(r"\s+", " ", text).rstrip(":")
    return text.replace("( ", "(").replace(" )", ")").replace(", )", ")")


def doc_range(node: ast.AST) -> list[int] | None:
    first = node.body[0] if getattr(node, "body", None) else None
    if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
            and isinstance(first.value.value, str)):
        return [first.lineno, first.end_lineno or first.lineno]
    return None


def added_lines(base: str | None, head: str) -> list[int]:
    """Return 1-based head lines that the base text does not hold."""
    new = head.splitlines()
    if base is None:
        return list(range(1, len(new) + 1))
    matcher = difflib.SequenceMatcher(None, base.splitlines(), new, autojunk=False)
    return [line + 1 for tag, _, _, start, end in matcher.get_opcodes()
            if tag in ("replace", "insert") for line in range(start, end)]


class Module:
    def __init__(self, path: str, text: str):
        self.path = path
        self.text = text
        self.lines = text.splitlines()
        self.tree = ast.parse(text)
        self.test = is_test_path(path)
        self.funcs: dict[str, ast.FunctionDef | ast.AsyncFunctionDef] = {}
        self.classes: dict[str, ast.ClassDef] = {}
        for item in self.tree.body:
            if isinstance(item, FUNCTIONS):
                self.funcs[item.name] = item
            elif isinstance(item, ast.ClassDef):
                self.classes[item.name] = item
                for member in item.body:
                    if isinstance(member, FUNCTIONS):
                        self.funcs[f"{item.name}.{member.name}"] = member
        self.names: dict[str, tuple[str, str]] = {}
        self.modules: dict[str, str] = {}


class Program:
    """Python modules of one revision with resolved imports."""

    def __init__(self, files: dict[str, Any]):
        self.modules: dict[str, Module] = {}
        self.failed: list[str] = []
        for path, info in sorted(files.items()):
            text = info.get("text") if isinstance(info, dict) else None
            if not path.endswith(".py") or not isinstance(text, str):
                continue
            try:
                self.modules[path] = Module(path, text)
            except (SyntaxError, ValueError):
                self.failed.append(path)
        self.suffix: dict[tuple[str, ...], list[str]] = {}
        for path in self.modules:
            parts = path[:-3].split("/")
            if parts[-1] == "__init__":
                parts = parts[:-1]
            for start in range(len(parts)):
                self.suffix.setdefault(tuple(parts[start:]), []).append(path)
        for module in self.modules.values():
            self._imports(module)

    def _exact(self, target: PurePosixPath) -> str | None:
        for candidate in (f"{target}.py", f"{target}/__init__.py"):
            candidate = candidate.removeprefix("./")
            if candidate in self.modules:
                return candidate
        return None

    def module(self, importer: str, name: str, level: int) -> str | None:
        """Resolve an import to a module path in this revision, or None."""
        if level:
            base = PurePosixPath(importer).parent
            for _ in range(level - 1):
                base = base.parent
            return self._exact(base.joinpath(*name.split(".")) if name else base)
        found = self.suffix.get(tuple(name.split(".")), [])
        if len(found) <= 1:
            return found[0] if found else None
        importer_parts = PurePosixPath(importer).parts

        def shared(path: str) -> int:
            count = 0
            for left, right in zip(PurePosixPath(path).parts, importer_parts):
                if left != right:
                    break
                count += 1
            return count

        ranked = sorted(found, key=shared, reverse=True)
        return ranked[0] if shared(ranked[0]) > shared(ranked[1]) else None

    def _imports(self, module: Module) -> None:
        for node in ast.walk(module.tree):
            if isinstance(node, ast.ImportFrom):
                prefix = node.module or ""
                target = self.module(module.path, prefix, node.level)
                for alias in node.names:
                    bound = alias.asname or alias.name
                    nested = self.module(module.path, f"{prefix}.{alias.name}".lstrip("."), node.level)
                    if nested:
                        module.modules[bound] = nested
                    elif target:
                        module.names[bound] = (target, alias.name)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    target = self.module(module.path, alias.name, 0)
                    if target:
                        module.modules[alias.asname or alias.name] = target

    def symbol(self, path: str, name: str, depth: int = 0) -> tuple[str, str] | None:
        """Return (module path, name) of a function or class, following re-exports."""
        module = self.modules.get(path)
        if module is None or depth > 4:
            return None
        if name in module.funcs or name in module.classes:
            return path, name
        if name in module.names:
            return self.symbol(*module.names[name], depth + 1)
        return None

    def class_of(self, module: Module, expr: ast.expr) -> tuple[str, str] | None:
        if isinstance(expr, ast.Name):
            if expr.id in module.classes:
                return module.path, expr.id
            if expr.id in module.names:
                found = self.symbol(*module.names[expr.id])
                if found and found[1] in self.modules[found[0]].classes:
                    return found
        elif isinstance(expr, ast.Attribute) and isinstance(expr.value, ast.Name):
            target = module.modules.get(expr.value.id)
            if target and expr.attr in self.modules[target].classes:
                return target, expr.attr
        return None

    def bases(self, path: str, name: str) -> list[tuple[str, str]]:
        module = self.modules[path]
        return [found for base in module.classes[name].bases
                if (found := self.class_of(module, base)) is not None]

    def method(self, path: str, name: str, method: str,
               seen: set[tuple[str, str]] | None = None) -> str | None:
        seen = seen if seen is not None else set()
        if (path, name) in seen:
            return None
        seen.add((path, name))
        if f"{name}.{method}" in self.modules[path].funcs:
            return f"{path}::{name}.{method}"
        for base_path, base_name in self.bases(path, name):
            found = self.method(base_path, base_name, method, seen)
            if found:
                return found
        return None


def dispatch_table(program: Program) -> dict[str, tuple[str, list[str]]]:
    """Map a method name to its base method and overrides when one hierarchy owns it."""
    production = {path: module for path, module in program.modules.items() if not module.test}
    table: dict[str, tuple[str, list[str]]] = {}
    for path, module in production.items():
        for name, node in module.classes.items():
            if not any(getattr(base, "id", None) == "Protocol" or getattr(base, "attr", None) == "Protocol"
                       for base in node.bases):
                continue
            methods = [qual.split(".", 1)[1] for qual in module.funcs
                       if qual.startswith(name + ".") and not qual.split(".", 1)[1].startswith("_")]
            implementers = [(other_path, other_name) for other_path, other in production.items()
                            for other_name in other.classes
                            if (other_path, other_name) != (path, name) and methods
                            and all(f"{other_name}.{method}" in other.funcs for method in methods)]
            for method in methods:
                table[method] = (f"{path}::{name}.{method}",
                                 [f"{other_path}::{other_name}.{method}" for other_path, other_name in implementers])
    owners: dict[str, list[tuple[str, str]]] = {}
    for path, module in production.items():
        for qual in module.funcs:
            if "." in qual:
                owner, method = qual.split(".", 1)
                owners.setdefault(method, []).append((path, owner))
    for method, classes in owners.items():
        if method in table or len(classes) < 2 or method.startswith("__"):
            continue
        roots = set()
        for current in classes:
            seen = {current}
            while True:
                ups = [base for base in program.bases(*current) if base in classes and base not in seen]
                if not ups:
                    break
                current = ups[0]
                seen.add(current)
            roots.add(current)
        if len(roots) == 1:
            root = roots.pop()
            table[method] = (f"{root[0]}::{root[1]}.{method}",
                             [f"{path}::{owner}.{method}" for path, owner in classes if (path, owner) != root])
    return table


def calls_in(program: Program, module: Module, node: ast.AST, owner: str | None,
             table: dict[str, tuple[str, list[str]]], lines: set[int] | None = None) -> list[dict[str, Any]]:
    """Return static calls inside node, optionally limited to a line set."""
    local_types: dict[str, tuple[str, str]] = {}
    for item in ast.walk(node):
        if (isinstance(item, ast.Assign) and len(item.targets) == 1 and isinstance(item.targets[0], ast.Name)
                and isinstance(item.value, ast.Call)):
            found = program.class_of(module, item.value.func)
            if found:
                local_types[item.targets[0].id] = found
    found_calls = []
    for item in ast.walk(node):
        if not isinstance(item, ast.Call) or (lines is not None and item.lineno not in lines):
            continue
        function, target, how = item.func, None, "direct"
        if isinstance(function, ast.Name):
            name = function.id
            if name in module.funcs:
                target = f"{module.path}::{name}"
            else:
                found = (module.path, name) if name in module.classes else (
                    program.symbol(*module.names[name]) if name in module.names else None)
                if found and found[1] in program.modules[found[0]].funcs:
                    target = f"{found[0]}::{found[1]}"
                elif found:
                    target = program.method(found[0], found[1], "__init__")
        elif isinstance(function, ast.Attribute):
            value = function.value
            dotted = ast.unparse(value) if isinstance(value, (ast.Name, ast.Attribute)) else ""
            if dotted in module.modules:
                found = program.symbol(module.modules[dotted], function.attr)
                if found and found[1] in program.modules[found[0]].funcs:
                    target = f"{found[0]}::{found[1]}"
                elif found:
                    target = program.method(found[0], found[1], "__init__")
            elif isinstance(value, ast.Name) and value.id in ("self", "cls") and owner:
                target, how = program.method(module.path, owner, function.attr), "self"
            elif isinstance(value, ast.Name) and value.id in local_types:
                target = program.method(*local_types[value.id], function.attr)
            else:
                found = program.class_of(module, value)
                if found:
                    target = program.method(*found, function.attr)
            if not target and function.attr in table and not function.attr.startswith("_"):
                target, how = table[function.attr][0], "dynamic"
        if target:
            found_calls.append({"to": target, "line": item.lineno, "how": how})
    seen: set[tuple[str, int]] = set()
    unique = []
    for call in sorted(found_calls, key=lambda call: (call["line"], call["to"])):
        if (call["to"], call["line"]) not in seen:
            seen.add((call["to"], call["line"]))
            unique.append(call)
    return unique


def entry_functions(module: Module) -> list[str]:
    """Return `main` and the functions that a `__main__` guard calls."""
    found = ["main"] if "main" in module.funcs else []
    for statement in module.tree.body:
        test = statement.test if isinstance(statement, ast.If) else None
        if not (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name) and test.left.id == "__name__"):
            continue
        for item in ast.walk(statement):
            if (isinstance(item, ast.Call) and isinstance(item.func, ast.Name)
                    and item.func.id in module.funcs and item.func.id not in found):
                found.append(item.func.id)
    return found


def branches(function: ast.AST) -> list[tuple[str, ast.If]]:
    """Return (command, branch) pairs when one variable selects two or more commands."""
    by_name: dict[str, list[tuple[str, ast.If]]] = {}
    for item in ast.walk(function):
        test = item.test if isinstance(item, ast.If) else None
        if not (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name) and len(test.ops) == 1
                and isinstance(test.ops[0], (ast.Eq, ast.In))):
            continue
        values = [value.value for value in ast.walk(test.comparators[0])
                  if isinstance(value, ast.Constant) and isinstance(value.value, str)]
        if values and not values[0].startswith("_"):
            by_name.setdefault(test.left.id, []).append((values[0], item))
    best = max(by_name.values(), key=len, default=[])
    return best if len(best) >= 2 else []


def function_node(module: Module, qual: str, function: ast.FunctionDef | ast.AsyncFunctionDef,
                  base: Module | None) -> dict[str, Any]:
    sig = signature(module.lines, function)
    old = base.funcs.get(qual) if base else None
    if old is None:
        change = "added"
    elif signature(base.lines, old) != sig:
        change = "signature"
    elif (base.lines[old.lineno - 1:old.end_lineno] != module.lines[function.lineno - 1:function.end_lineno]):
        change = "body"
    else:
        change = ""
    text = ast.get_docstring(function)
    return {
        "id": f"{module.path}::{qual}", "path": module.path, "qual": qual, "label": qual,
        "kind": "test" if module.test else ("method" if "." in qual else "function"),
        "public": is_public(qual), "line": function.lineno, "end": function.end_lineno or function.lineno,
        "sigEnd": max(function.lineno, function.body[0].lineno - 1 if function.body else function.lineno),
        "doc": doc_range(function), "summary": text.strip().split("\n")[0] if text else "",
        "sig": sig, "was": signature(base.lines, old) if change == "signature" and base and old else None,
        "change": change, "e2e": False,
    }


def reachable(nodes: dict[str, dict[str, Any]], starts: list[str]) -> set[str]:
    seen: set[str] = set()
    stack = list(starts)
    while stack:
        current = stack.pop()
        if current in seen or current not in nodes or nodes[current]["kind"] == "test":
            continue
        seen.add(current)
        stack.extend(call["to"] for call in nodes[current]["calls"])
        stack.extend(nodes[current].get("overrides", []))
    return seen


def build_walk(doc: dict[str, Any]) -> dict[str, Any] | None:
    """Return the call walk for a base and head comparison, or None without a base."""
    snapshots = doc.get("snapshots", {})
    if not doc.get("base") or "base" not in snapshots:
        return None
    head = Program(snapshots["head"].get("files", {}))
    base = Program(snapshots["base"].get("files", {}))
    table = dispatch_table(head)
    nodes: dict[str, dict[str, Any]] = {}
    for path, module in head.modules.items():
        old = base.modules.get(path)
        for qual, function in module.funcs.items():
            if module.test and not qual.split(".")[-1].startswith("test"):
                continue
            node = function_node(module, qual, function, old)
            node["calls"] = calls_in(head, module, function, qual.split(".")[0] if "." in qual else None, table)
            node["e2e"] = bool(module.test and E2E_PATH.search(path))
            nodes[node["id"]] = node
    for root, overrides in table.values():
        if root in nodes:
            nodes[root]["overrides"] = [item for item in overrides if item in nodes]

    entries: list[dict[str, Any]] = []
    commands: dict[str, dict[str, str]] = {}
    for path, module in head.modules.items():
        if module.test:
            continue
        old = base.modules.get(path)
        for name in entry_functions(module):
            function_id = f"{path}::{name}"
            routes = branches(module.funcs[name])
            if not routes:
                entries.append({"id": function_id, "label": f"{PurePosixPath(path).stem}.{name}", "path": path})
                continue
            old_routes = {command for command, _ in branches(old.funcs[name])} if old and name in old.funcs else set()
            additions = set(added_lines(old.text if old else None, module.text))
            for command, branch in routes:
                end = branch.body[-1].end_lineno or branch.lineno
                lines = set(range(branch.lineno, end + 1))
                identity = f"{function_id}[{command}]"
                commands.setdefault(function_id, {})[command] = identity
                nodes[identity] = {
                    "id": identity, "path": path, "qual": command, "label": f"{PurePosixPath(path).stem} {command}",
                    "kind": "entry", "public": True, "line": branch.lineno, "end": end, "sigEnd": branch.lineno,
                    "doc": None, "summary": "", "sig": module.lines[branch.lineno - 1].strip().rstrip(":"),
                    "was": None, "e2e": False,
                    "change": "added" if command not in old_routes else ("body" if lines & additions else ""),
                    "calls": calls_in(head, module, branch, None, table, lines),
                }
                entries.append({"id": identity, "label": f"{PurePosixPath(path).stem} {command}", "path": path})

    # Tests that pass ["command", ...] to an entry function, or to a helper that calls one, drive that command.
    for path, module in head.modules.items():
        if not module.test:
            continue
        runners: dict[str, str] = {}
        for alias, (target, name) in module.names.items():
            found = head.symbol(target, name)
            if found and f"{found[0]}::{found[1]}" in commands:
                runners[alias] = f"{found[0]}::{found[1]}"
        for qual, function in module.funcs.items():
            if "." in qual or qual.startswith("test"):
                continue
            for call in calls_in(head, module, function, None, table):
                if call["to"] in commands:
                    runners[qual] = call["to"]
        for qual, function in module.funcs.items():
            node = nodes.get(f"{path}::{qual}")
            if node is None:
                continue
            for item in ast.walk(function):
                if not (isinstance(item, ast.Call) and item.args and isinstance(item.args[0], (ast.List, ast.Tuple))
                        and item.args[0].elts and isinstance(item.args[0].elts[0], ast.Constant)):
                    continue
                callee = item.func.id if isinstance(item.func, ast.Name) else (
                    item.func.attr if isinstance(item.func, ast.Attribute) else "")
                target = commands.get(runners.get(callee, ""), {}).get(str(item.args[0].elts[0].value))
                if target:
                    node["calls"].append({"to": target, "line": item.lineno, "how": "command"})

    entry_ids = {entry["id"] for entry in entries}
    # A handler is a function that exactly one command branch calls; shared argument helpers are not handlers.
    branch_count: dict[str, int] = {}
    for identity in entry_ids:
        if nodes.get(identity, {}).get("kind") == "entry":
            for target in {call["to"] for call in nodes[identity]["calls"]}:
                branch_count[target] = branch_count.get(target, 0) + 1
    handlers = {target for target, count in branch_count.items() if count == 1}
    for node in nodes.values():
        if node["kind"] == "test" and any(call["to"] in entry_ids or call["to"] in handlers
                                          for call in node["calls"]):
            node["e2e"] = True

    # Changed code that no entry point reaches gets its own start, so no change stays hidden.
    reached = reachable(nodes, [entry["id"] for entry in entries])
    unreached = [identity for identity, node in nodes.items()
                 if node["change"] and node["kind"] != "test" and identity not in reached]
    covered: set[str] = set()
    for identity in unreached:
        covered |= reachable(nodes, [identity]) - {identity}
    for identity in unreached:
        if identity not in covered:
            entries.append({"id": identity, "label": nodes[identity]["qual"], "path": nodes[identity]["path"],
                            "orphan": True})

    keep = reachable(nodes, [entry["id"] for entry in entries])
    for identity, node in nodes.items():
        if node["kind"] == "test" and any(call["to"] in keep and (nodes[call["to"]]["change"] or call["to"] in entry_ids or call["to"] in handlers)
                                          for call in node["calls"]):
            keep.add(identity)
    nodes = {identity: node for identity, node in nodes.items() if identity in keep}
    for node in nodes.values():
        node["calls"] = [call for call in node["calls"] if call["to"] in nodes]
        node["callers"] = []
    for node in nodes.values():
        for call in node["calls"]:
            nodes[call["to"]]["callers"].append({"from": node["id"], "line": call["line"], "how": call["how"]})

    paths = {node["path"] for node in nodes.values()}
    added = {}
    for path in sorted(paths):
        old = base.modules.get(path)
        lines = added_lines(old.text if old else snapshots["base"].get("files", {}).get(path, {}).get("text"),
                            head.modules[path].text)
        if lines:
            added[path] = lines
    return {"version": 1, "language": "Python", "entries": entries, "nodes": nodes, "added": added,
            "limits": LIMITS, "unparsed": sorted(set(head.failed))}
