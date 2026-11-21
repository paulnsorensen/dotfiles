"""Static Python declarations and conservative direct-call evidence."""

from __future__ import annotations

import ast
from pathlib import PurePosixPath
from typing import TypedDict, override

VERSION = "2"


class Definition(TypedDict):
    qual: str
    name: str
    line: int
    end: int
    kind: str
    public: bool


class Reference(TypedDict):
    source: str
    targets: list[str]
    kind: str
    line: int
    reason: str


class Unknown(TypedDict):
    line: int
    reason: str


class Evidence(TypedDict):
    defs: list[Definition]
    refs: list[Reference]
    unknowns: list[Unknown]
    failed: bool


def _module_paths(path: str, module: str, level: int = 0) -> list[str]:
    source = PurePosixPath(path)
    if level:
        base = source.parent
        for _ in range(level - 1):
            base = base.parent
        roots = [base]
    else:
        parts = module.split(".")
        roots = [PurePosixPath(*source.parts[:i]) for i, part in enumerate(source.parts[:-1]) if part == parts[0]]
        roots.append(PurePosixPath())
    suffix = PurePosixPath(*module.split(".")) if module else PurePosixPath()
    paths: list[str] = []
    for root in roots:
        target = root / suffix
        for candidate in (f"{target}.py", str(target / "__init__.py")):
            if candidate not in paths:
                paths.append(candidate)
    return paths


def _bindings(body: list[ast.stmt]) -> set[str]:
    names: set[str] = set()
    for statement in body:
        if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(statement.name)
        elif isinstance(statement, (ast.Import, ast.ImportFrom)):
            for alias in statement.names:
                names.add(alias.asname or alias.name.split(".")[0])
        elif isinstance(statement, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.For, ast.AsyncFor)):
            targets = statement.targets if isinstance(statement, ast.Assign) else [statement.target]
            for target in targets:
                names.update(node.id for node in ast.walk(target) if isinstance(node, ast.Name))
    return names


def _parameters(node: ast.FunctionDef | ast.AsyncFunctionDef) -> set[str]:
    args = node.args
    return {arg.arg for arg in (*args.posonlyargs, *args.args, *args.kwonlyargs, *([args.vararg] if args.vararg else []), *([args.kwarg] if args.kwarg else []))}


def extract(path: str, text: str) -> Evidence:
    """Return revision-independent AST evidence for one source file."""
    result: Evidence = {"defs": [], "refs": [], "unknowns": [], "failed": False}
    try:
        tree = ast.parse(text, filename=path)
    except SyntaxError as exc:
        result["failed"] = True
        result["unknowns"].append({"line": exc.lineno or 1, "reason": f"syntax error: {exc.msg}"})
        return result

    result["defs"].append({"qual": "", "name": PurePosixPath(path).stem, "line": 1,
                           "end": max(1, len(text.splitlines())), "kind": "module", "public": True})
    module_defs = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))}
    imports: dict[str, tuple[str, int]] = {}
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports[alias.asname or alias.name.split(".")[0]] = (alias.name if alias.asname else alias.name.split(".")[0], 0)
        elif isinstance(node, ast.ImportFrom):
            if any(alias.name == "*" for alias in node.names):
                result["unknowns"].append({"line": node.lineno, "reason": "star import"})
            for alias in node.names:
                if alias.name != "*":
                    imports[alias.asname or alias.name] = (f"{node.module}.{alias.name}" if node.module else alias.name, node.level)

    rebound = _bindings([node for node in tree.body if isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.For, ast.AsyncFor))])

    class Visitor(ast.NodeVisitor):
        def __init__(self) -> None:
            self.scopes: list[tuple[str, set[str], set[str]]] = [("", set(), set())]

        @property
        def qual(self) -> str:
            return self.scopes[-1][0]

        def unknown(self, node: ast.expr | ast.stmt, reason: str) -> None:
            result["unknowns"].append({"line": node.lineno, "reason": reason})

        def ref(self, node: ast.expr | ast.stmt, candidates: list[str], kind: str, reason: str) -> None:
            result["refs"].append({"source": self.qual, "targets": candidates, "kind": kind,
                                   "line": node.lineno, "reason": reason})

        @override
        def visit_Import(self, node: ast.Import) -> None:
            for alias in node.names:
                self.ref(node, _module_paths(path, alias.name), "import", "explicit import")

        @override
        def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
            self.ref(node, _module_paths(path, node.module or "", node.level), "import", "explicit import")

        @override
        def visit_ClassDef(self, node: ast.ClassDef) -> None:
            self.declaration(node, "class")

        @override
        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            self.declaration(node, "function")

        @override
        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            self.declaration(node, "function")

        def declaration(self, node: ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef, kind: str) -> None:
            qual = f"{self.qual}.{node.name}" if self.qual else node.name
            result["defs"].append({"qual": qual, "name": node.name, "line": node.lineno,
                                   "end": node.end_lineno or node.lineno, "kind": kind,
                                   "public": not node.name.startswith("_")})
            params: set[str] = _parameters(node) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) else set()
            self.scopes.append((qual, _bindings(node.body) | params, params))
            for child in node.body:
                self.visit(child)
            _ = self.scopes.pop()

        @override
        def visit_Call(self, node: ast.Call) -> None:
            target = node.func
            candidates: list[str] = []
            reason = "direct call"
            if isinstance(target, ast.Name):
                name = target.id
                shadowed = any(name in bindings for _, bindings, _ in self.scopes[1:])
                if name in rebound or shadowed:
                    reason = "shadowed or local callable"
                elif name in imports:
                    module, level = imports[name]
                    base, symbol = module.rsplit(".", 1) if "." in module else ("", module)
                    candidates = [f"{p}::{symbol}" for p in _module_paths(path, base, level)]
                elif name in module_defs:
                    candidates = [f"{path}::{name}"]
                else:
                    reason = "unresolved name"
            elif isinstance(target, ast.Attribute):
                chain: list[str] = []
                cursor = target
                while isinstance(cursor, ast.Attribute):
                    chain.append(cursor.attr)
                    cursor = cursor.value
                if isinstance(cursor, ast.Name) and cursor.id == "self" and len(chain) == 1:
                    owner = self.qual.rsplit(".", 1)[0]
                    if owner and f"{owner}.{chain[0]}" in {item["qual"] for item in result["defs"]}:
                        candidates = [f"{path}::{owner}.{chain[0]}"]
                    else:
                        reason = "unresolved self method"
                elif isinstance(cursor, ast.Name) and cursor.id in imports and cursor.id not in rebound and cursor.id not in self.scopes[-1][1]:
                    module, level = imports[cursor.id]
                    chain.reverse()
                    full = ".".join([module, *chain])
                    base, symbol = full.rsplit(".", 1)
                    candidates = [f"{p}::{symbol}" for p in _module_paths(path, base, level)]
                else:
                    reason = "dynamic attribute call"
            else:
                reason = "dynamic call"
            if candidates:
                self.ref(node, candidates, "call", reason)
            else:
                self.unknown(node, reason)
            self.generic_visit(node)

    Visitor().visit(tree)
    return result
