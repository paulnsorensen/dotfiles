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
DOTTED = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+")
FOREIGN = ("", "")  # a value whose type lives outside the repository
BUILTIN_TYPES = {"str", "int", "float", "bool", "bytes", "bytearray", "complex", "list", "dict", "set",
                 "frozenset", "tuple", "range", "type"}
BUILTIN_CALLS = BUILTIN_TYPES | {"open", "sorted", "reversed", "enumerate", "zip", "map", "filter", "iter",
                                 "len", "repr", "format", "vars", "dir", "print", "input"}
CONTAINERS = {"list", "List", "set", "Set", "frozenset", "FrozenSet", "tuple", "Tuple", "Sequence",
              "MutableSequence", "Collection", "Iterable", "Iterator", "Generator", "AbstractSet",
              "AsyncIterable", "AsyncIterator", "dict", "Dict", "Mapping", "MutableMapping", "defaultdict",
              "DefaultDict", "OrderedDict"}
MAPPINGS = {"dict", "Dict", "Mapping", "MutableMapping", "defaultdict", "DefaultDict", "OrderedDict"}
GETTERS = {"get", "pop", "setdefault"}
WRAPPERS = {"Optional", "Annotated", "ClassVar", "Final", "Required", "NotRequired"}
UNKNOWN_TYPES = {"Any", "object"}
LITERALS = (ast.Constant, ast.JoinedStr, ast.List, ast.Dict, ast.Set, ast.Tuple, ast.ListComp, ast.DictComp,
            ast.SetComp, ast.GeneratorExp)
COMMAND_DECORATORS = {"command", "callback", "group"}
PROCESS_MODULES = ("subprocess", "runpy", "pexpect")
LIMITS = [
    "Python only; other languages stay in the subsystem map.",
    "Calls are resolved from source text, not observed at run time.",
    "A call on an object resolves through self, a type annotation, or a local binding. Otherwise it falls back to a public method name that one class hierarchy or Protocol owns, when the calling module imports that owner.",
    "Calls on standard-library and third-party values are not followed.",
    "A function passed as an argument, or listed in a module-level table, counts as a call.",
    "Tests link through resolved calls, command lists, and script paths that a subprocess runs.",
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
        self.external: set[str] = set()
        self.tables: dict[str, list[ast.expr]] = {}
        self.strings: dict[str, list[ast.Constant]] = {}
        for item in self.tree.body:
            target = item.targets[0] if isinstance(item, ast.Assign) and len(item.targets) == 1 else (
                item.target if isinstance(item, ast.AnnAssign) else None)
            if not isinstance(target, ast.Name) or item.value is None:
                continue
            if isinstance(item.value, (ast.Dict, ast.List, ast.Tuple, ast.Set)):
                values = item.value.values if isinstance(item.value, ast.Dict) else item.value.elts
                self.tables[target.id] = [value for value in values if isinstance(value, (ast.Name, ast.Attribute))]
            self.strings[target.id] = [value for value in ast.walk(item.value)
                                       if isinstance(value, ast.Constant) and isinstance(value.value, str)]


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
        self._fields: dict[tuple[str, str], dict[str, tuple[Any, Module, ast.expr | None]]] = {}
        self._visible: dict[str, set[str]] = {}
        self.roots: dict[str, list[str]] = {}  # dispatched method -> its implementations
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
                    else:
                        module.external.add(bound)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    target = self.module(module.path, alias.name, 0)
                    if target:
                        module.modules[alias.asname or alias.name] = target
                    else:
                        module.external.add(alias.asname or alias.name.split(".")[0])

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

    def function_id(self, module: Module, name: str) -> str | None:
        """Return the identity of a function that a bare name refers to, or None."""
        if name in module.funcs:
            return f"{module.path}::{name}"
        symbol = self.symbol(*module.names[name]) if name in module.names else None
        return f"{symbol[0]}::{symbol[1]}" if symbol and symbol[1] in self.modules[symbol[0]].funcs else None

    def returns(self, identity: str | None) -> tuple[str, str] | None:
        """Return the value kind that a function's return annotation names."""
        path, _, qual = (identity or "").partition("::")
        module = self.modules.get(path)
        function = module.funcs.get(qual) if module else None
        return self.annotation(module, function.returns) if module and function and function.returns else None

    def external_root(self, module: Module, expr: ast.expr) -> bool:
        while isinstance(expr, (ast.Attribute, ast.Subscript, ast.Call)):
            expr = expr.func if isinstance(expr, ast.Call) else expr.value
        return isinstance(expr, ast.Name) and expr.id in module.external

    def annotation(self, module: Module, ann: ast.expr | None, element: bool = False,
                   values: bool = False) -> tuple[str, str] | None:
        """Return the class an annotation names, FOREIGN for an outside type, or None when unknown.

        With element set, return the kind of one item that iterating the annotated value yields.
        With values set, return the kind that indexing it gives: a mapping value or a sequence item.
        """
        if isinstance(ann, ast.Constant) and isinstance(ann.value, str):
            try:
                ann = ast.parse(ann.value, mode="eval").body
            except SyntaxError:
                return None
        if isinstance(ann, ast.BinOp) and isinstance(ann.op, ast.BitOr):
            options = {self.annotation(module, side, element, values) for side in (ann.left, ann.right)} - {None}
            return options.pop() if len(options) == 1 else None
        if isinstance(ann, ast.Subscript):
            outer = ann.value.attr if isinstance(ann.value, ast.Attribute) else getattr(ann.value, "id", "")
            inner = list(ann.slice.elts) if isinstance(ann.slice, ast.Tuple) else [ann.slice]
            if outer in WRAPPERS:
                return self.annotation(module, inner[0], element, values)
            if outer == "Union":
                options = {self.annotation(module, item, element, values) for item in inner} - {None}
                return options.pop() if len(options) == 1 else None
            if values and outer in MAPPINGS and len(inner) > 1:
                return self.annotation(module, inner[1])
            if element or values:
                return self.annotation(module, inner[0]) if outer in CONTAINERS else None
            if outer in CONTAINERS or outer in BUILTIN_TYPES:
                return FOREIGN
            return self.class_of(module, ann.value) or (FOREIGN if self.external_root(module, ann) else None)
        if element or values or not isinstance(ann, (ast.Name, ast.Attribute)):
            return None
        if isinstance(ann, ast.Name) and ann.id in UNKNOWN_TYPES:
            return None
        if isinstance(ann, ast.Name) and ann.id in BUILTIN_TYPES:
            return FOREIGN
        return self.class_of(module, ann) or (FOREIGN if self.external_root(module, ann) else None)

    def parameters(self, module: Module, function: ast.FunctionDef | ast.AsyncFunctionDef
                   ) -> tuple[dict[str, tuple[str, str]], dict[str, ast.expr]]:
        kinds: dict[str, tuple[str, str]] = {}
        annotations: dict[str, ast.expr] = {}
        arguments = function.args
        for argument in (*arguments.posonlyargs, *arguments.args, *arguments.kwonlyargs):
            if argument.annotation is not None:
                annotations[argument.arg] = argument.annotation
                kind = self.annotation(module, argument.annotation)
                if kind:
                    kinds[argument.arg] = kind
        return kinds, annotations

    def fields(self, path: str, name: str) -> dict[str, tuple[Any, Module, ast.expr | None]]:
        """Return attribute kinds of a class from class annotations and self assignments."""
        key = (path, name)
        if key in self._fields:
            return self._fields[key]
        self._fields[key] = {}
        module = self.modules[path]
        table: dict[str, tuple[Any, Module, ast.expr | None]] = {}
        for item in module.classes[name].body:
            if isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name):
                table[item.target.id] = (self.annotation(module, item.annotation), module, item.annotation)
        for member in module.classes[name].body:
            if not isinstance(member, FUNCTIONS):
                continue
            kinds, annotations = self.parameters(module, member)
            for item in ast.walk(member):
                target = item.target if isinstance(item, ast.AnnAssign) else (
                    item.targets[0] if isinstance(item, ast.Assign) and len(item.targets) == 1 else None)
                if not (isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name)
                        and target.value.id == "self") or target.attr in table:
                    continue
                if isinstance(item, ast.AnnAssign):
                    table[target.attr] = (self.annotation(module, item.annotation), module, item.annotation)
                elif item.value is not None:
                    kind = self.kind_of(module, item.value, kinds, name, annotations)
                    source = annotations.get(item.value.id) if isinstance(item.value, ast.Name) else None
                    if kind or source is not None:
                        table[target.attr] = (kind, module, source)
        for base in self.bases(path, name):
            for attr, value in self.fields(*base).items():
                table.setdefault(attr, value)
        self._fields[key] = table
        return table

    def container(self, module: Module, expr: ast.expr, annotations: dict[str, ast.expr] | None,
                  owner: str | None) -> tuple[Module, ast.expr] | None:
        """Return the module and annotation of a local or self attribute that holds a container."""
        if isinstance(expr, ast.Name) and annotations and expr.id in annotations:
            return module, annotations[expr.id]
        if (isinstance(expr, ast.Attribute) and isinstance(expr.value, ast.Name) and expr.value.id == "self"
                and owner in module.classes):
            field = self.fields(module.path, owner).get(expr.attr)
            return (field[1], field[2]) if field and field[2] is not None else None
        return None

    def kind_of(self, module: Module, expr: ast.expr, kinds: dict[str, tuple[str, str]],
                owner: str | None, annotations: dict[str, ast.expr] | None = None) -> tuple[str, str] | None:
        """Return the class of a value, FOREIGN for an outside value, or None when unknown."""
        if isinstance(expr, ast.Await):
            expr = expr.value
        if isinstance(expr, ast.Subscript):
            found = self.container(module, expr.value, annotations, owner)
            return self.annotation(*found, values=True) if found else None
        if isinstance(expr, ast.Name):
            return kinds.get(expr.id) or (FOREIGN if expr.id in module.external else None)
        if isinstance(expr, ast.Attribute):
            if (isinstance(expr.value, ast.Name) and expr.value.id in ("self", "cls")
                    and owner in module.classes):
                return self.fields(module.path, owner).get(expr.attr, (None,))[0]
            return FOREIGN if self.external_root(module, expr) else None
        if isinstance(expr, ast.Call):
            return self.result(module, expr.func, kinds, owner, annotations)
        return FOREIGN if isinstance(expr, LITERALS) else None

    def result(self, module: Module, func: ast.expr, kinds: dict[str, tuple[str, str]],
               owner: str | None, annotations: dict[str, ast.expr] | None = None) -> tuple[str, str] | None:
        """Return the kind of value that calling func gives."""
        found = self.class_of(module, func)
        if found:
            return found
        if isinstance(func, ast.Name):
            if func.id in kinds:
                return None
            identity = self.function_id(module, func.id)
            if identity:
                return self.returns(identity)
            return FOREIGN if func.id in BUILTIN_CALLS or func.id in module.external else None
        if not isinstance(func, ast.Attribute):
            return None
        value = func.value
        dotted = ast.unparse(value) if isinstance(value, (ast.Name, ast.Attribute)) else ""
        if dotted in module.modules:
            symbol = self.symbol(module.modules[dotted], func.attr)
            return self.returns(f"{symbol[0]}::{symbol[1]}") if symbol else None
        if isinstance(value, ast.Name) and value.id in ("self", "cls") and owner in module.classes:
            return self.returns(self.method(module.path, owner, func.attr))
        found = self.container(module, value, annotations, owner) if func.attr in GETTERS else None
        if found:
            return self.annotation(*found, values=True)
        receiver = self.kind_of(module, value, kinds, owner, annotations)
        if receiver == FOREIGN:
            return FOREIGN
        return self.returns(self.method(*receiver, func.attr)) if receiver else None

    def element_of(self, module: Module, iterable: ast.expr, kinds: dict[str, tuple[str, str]],
                   annotations: dict[str, ast.expr], owner: str | None) -> tuple[str, str] | None:
        """Return the kind of one item that a for loop or comprehension takes from iterable."""
        if (isinstance(iterable, ast.Call) and isinstance(iterable.func, ast.Name) and iterable.args
                and iterable.func.id in ("sorted", "reversed", "list", "tuple", "set")):
            return self.element_of(module, iterable.args[0], kinds, annotations, owner)
        found = self.container(module, iterable, annotations, owner)
        if found:
            return self.annotation(*found, element=True)
        if (isinstance(iterable, (ast.List, ast.Tuple, ast.Set)) and iterable.elts
                and all(isinstance(item, ast.Constant) for item in iterable.elts)):
            return FOREIGN
        return None

    def visible(self, module: Module, identity: str) -> bool:
        """Return True when the calling module defines or imports the public owner of identity."""
        path, _, qual = identity.partition("::")
        if not is_public(qual):
            return False
        if module.path not in self._visible:
            reach = {module.path, *module.modules.values()}
            for target, name in module.names.values():
                reach.add(target)
                symbol = self.symbol(target, name)
                if symbol:
                    reach.add(symbol[0])
            self._visible[module.path] = reach
        return path in self._visible[module.path]

    def reference(self, module: Module, value: ast.expr, owner: str | None,
                  kinds: dict[str, tuple[str, str]]) -> str | None:
        """Return the function that a value passed as data refers to, or None."""
        if isinstance(value, ast.Name):
            return None if value.id in kinds else self.function_id(module, value.id)
        if not isinstance(value, ast.Attribute):
            return None
        if isinstance(value.value, ast.Name) and value.value.id == "self" and owner in module.classes:
            return self.method(module.path, owner, value.attr)
        dotted = ast.unparse(value.value) if isinstance(value.value, (ast.Name, ast.Attribute)) else ""
        symbol = self.symbol(module.modules[dotted], value.attr) if dotted in module.modules else None
        return f"{symbol[0]}::{symbol[1]}" if symbol and symbol[1] in self.modules[symbol[0]].funcs else None

    def call_target(self, module: Module, function: ast.expr, kinds: dict[str, tuple[str, str]],
                    owner: str | None, table: dict[str, tuple[str, list[str]]],
                    annotations: dict[str, ast.expr] | None = None) -> tuple[str | None, str]:
        """Return the identity a call resolves to and how it resolved."""
        if isinstance(function, ast.Name):
            if function.id in kinds:
                return None, "direct"
            target = self.function_id(module, function.id)
            found = None if target else self.class_of(module, function)
            return target or (self.method(*found, "__init__") if found else None), "direct"
        if not isinstance(function, ast.Attribute):
            return None, "direct"
        value, attr = function.value, function.attr
        dotted = ast.unparse(value) if isinstance(value, (ast.Name, ast.Attribute)) else ""
        if dotted in module.modules:
            symbol = self.symbol(module.modules[dotted], attr)
            if symbol and symbol[1] in self.modules[symbol[0]].funcs:
                return f"{symbol[0]}::{symbol[1]}", "direct"
            return (self.method(*symbol, "__init__") if symbol else None), "direct"
        if isinstance(value, ast.Name) and value.id in ("self", "cls") and owner in module.classes:
            return self.method(module.path, owner, attr), "self"
        if (isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == "super"
                and owner in module.classes):
            target = next(filter(None, (self.method(*base, attr) for base in self.bases(module.path, owner))), None)
            return target, "direct"
        found = self.class_of(module, value)
        if found:
            return self.method(*found, attr), "direct"
        receiver = self.kind_of(module, value, kinds, owner, annotations)
        if receiver == FOREIGN:
            return None, "direct"
        if receiver:
            target = self.method(*receiver, attr)
            return target, "dynamic" if target in self.roots else "direct"
        entry = table.get(attr)
        if entry and not attr.startswith("_") and self.visible(module, entry[0]):
            return entry[0], "dynamic"
        return None, "direct"


def dispatch_table(program: Program) -> dict[str, tuple[str, list[str]]]:
    """Map a method name to its base method and overrides when one hierarchy owns it.

    Every Protocol method and hierarchy root also goes into program.roots with its implementations,
    so a call that resolves to one by type still dispatches.
    """
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
                program.roots[table[method][0]] = table[method][1]
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
            program.roots[table[method][0]] = table[method][1]
    return table


def local_scope(program: Program, module: Module, node: ast.AST, owner: str | None
                ) -> tuple[dict[str, tuple[str, str]], dict[str, ast.expr]]:
    """Return value kinds and annotations of the names that node binds, in source order."""
    kinds, annotations = program.parameters(module, node) if isinstance(node, FUNCTIONS) else ({}, {})
    bindings = [item for item in ast.walk(node) if isinstance(item, (
        ast.Assign, ast.AnnAssign, ast.With, ast.AsyncWith, ast.For, ast.AsyncFor, ast.comprehension))]
    bindings.sort(key=lambda item: getattr(item, "lineno", None) or item.target.lineno)

    def bind(name: str, kind: tuple[str, str] | None) -> None:
        if kind:
            kinds[name] = kind
        else:
            kinds.pop(name, None)

    for item in bindings:
        if isinstance(item, ast.Assign):
            if len(item.targets) == 1 and isinstance(item.targets[0], ast.Name):
                bind(item.targets[0].id, program.kind_of(module, item.value, kinds, owner, annotations))
        elif isinstance(item, ast.AnnAssign):
            if isinstance(item.target, ast.Name):
                annotations[item.target.id] = item.annotation
                bind(item.target.id, program.annotation(module, item.annotation))
        elif isinstance(item, (ast.With, ast.AsyncWith)):
            for part in item.items:
                if isinstance(part.optional_vars, ast.Name):
                    bind(part.optional_vars.id, program.kind_of(module, part.context_expr, kinds, owner, annotations))
        elif isinstance(item.target, ast.Name):
            bind(item.target.id, program.element_of(module, item.iter, kinds, annotations, owner))
    return kinds, annotations


def calls_in(program: Program, module: Module, node: ast.AST, owner: str | None,
             table: dict[str, tuple[str, list[str]]], lines: set[int] | None = None) -> list[dict[str, Any]]:
    """Return static calls inside node, optionally limited to a line set.

    A function passed as an argument, or read from a module-level table, counts as a call ("ref").
    """
    kinds, annotations = local_scope(program, module, node, owner)
    found_calls = []
    for item in ast.walk(node):
        line = getattr(item, "lineno", 0)
        if lines is not None and line not in lines:
            continue
        if (isinstance(item, ast.Name) and isinstance(item.ctx, ast.Load) and item.id in module.tables
                and item.id not in kinds):
            found_calls += [{"to": target, "line": line, "how": "ref"} for value in module.tables[item.id]
                            if (target := program.reference(module, value, owner, kinds))]
            continue
        if not isinstance(item, ast.Call):
            continue
        target, how = program.call_target(module, item.func, kinds, owner, table, annotations)
        if target:
            found_calls.append({"to": target, "line": line, "how": how})
        for argument in (*item.args, *(keyword.value for keyword in item.keywords)):
            values = (argument.elts if isinstance(argument, (ast.List, ast.Tuple, ast.Set))
                      else argument.values if isinstance(argument, ast.Dict) else [argument])
            found_calls += [{"to": target, "line": line, "how": "ref"} for value in values
                            if value is not None and (target := program.reference(module, value, owner, kinds))]
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


def decorated_commands(module: Module) -> list[tuple[str, str]]:
    """Return (function, command) pairs that a CLI decorator such as @app.command() registers."""
    found = []
    for name, function in module.funcs.items():
        if "." in name:
            continue
        for decorator in function.decorator_list:
            call = decorator if isinstance(decorator, ast.Call) else None
            target = call.func if call else decorator
            if not (isinstance(target, ast.Attribute) and target.attr in COMMAND_DECORATORS):
                continue
            given = [argument.value for argument in (call.args if call else [])
                     if isinstance(argument, ast.Constant) and isinstance(argument.value, str)]
            given += [keyword.value.value for keyword in (call.keywords if call else [])
                      if keyword.arg == "name" and isinstance(keyword.value, ast.Constant)
                      and isinstance(keyword.value.value, str)]
            default = "" if target.attr == "callback" else name.replace("_", "-")
            found.append((name, given[0] if given else default))
            break
    return found


def module_stem(path: str) -> str:
    stem = PurePosixPath(path)
    return (stem.parent.name or stem.stem) if stem.stem == "__init__" else stem.stem


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
            if module.test:
                # A test links to code only through calls that resolve to one target.
                node["calls"] = [call for call in node["calls"] if call["how"] != "dynamic"]
            node["e2e"] = bool(module.test and E2E_PATH.search(path))
            nodes[node["id"]] = node
    for root, overrides in head.roots.items():
        if root in nodes:
            # A dispatched method is a step even on a private Protocol: its implementations follow it.
            nodes[root]["overrides"] = [item for item in overrides if item in nodes]
            nodes[root]["public"] = True

    entries: list[dict[str, Any]] = []
    commands: dict[str, dict[str, str]] = {}
    named: dict[str, list[str]] = {}  # command name -> decorated command functions
    scripts: dict[str, list[tuple[str, str | None]]] = {}  # module path -> (entry, command) pairs
    for path, module in head.modules.items():
        if module.test:
            continue
        old = base.modules.get(path)
        stem = module_stem(path)
        mains = entry_functions(module)
        for name in mains:
            function_id = f"{path}::{name}"
            routes = branches(module.funcs[name])
            if not routes:
                entries.append({"id": function_id, "label": f"{stem}.{name}", "path": path})
                scripts.setdefault(path, []).append((function_id, None))
                continue
            old_routes = {command for command, _ in branches(old.funcs[name])} if old and name in old.funcs else set()
            additions = set(added_lines(old.text if old else None, module.text))
            for command, branch in routes:
                end = branch.body[-1].end_lineno or branch.lineno
                lines = set(range(branch.lineno, end + 1))
                identity = f"{function_id}[{command}]"
                commands.setdefault(function_id, {})[command] = identity
                nodes[identity] = {
                    "id": identity, "path": path, "qual": command, "label": f"{stem} {command}",
                    "kind": "entry", "public": True, "line": branch.lineno, "end": end, "sigEnd": branch.lineno,
                    "doc": None, "summary": "", "sig": module.lines[branch.lineno - 1].strip().rstrip(":"),
                    "was": None, "e2e": False,
                    "change": "added" if command not in old_routes else ("body" if lines & additions else ""),
                    "calls": calls_in(head, module, branch, None, table, lines),
                }
                entries.append({"id": identity, "label": f"{stem} {command}", "path": path})
                scripts.setdefault(path, []).append((identity, command))
        for name, command in decorated_commands(module):
            if name in mains:
                continue
            identity = f"{path}::{name}"
            entries.append({"id": identity, "label": f"{stem} {command}".strip(), "path": path})
            if command:
                named.setdefault(command, []).append(identity)

    # Tests that pass ["command", ...] to an entry function, or to a helper that calls one, drive that command.
    # A test that runs a script or module with an entry point in a subprocess drives that entry point.
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
        spawns = any(name in module.external for name in PROCESS_MODULES)
        for qual, function in module.funcs.items():
            node = nodes.get(f"{path}::{qual}")
            if node is None:
                continue
            for item in ast.walk(function):
                if not isinstance(item, ast.Call):
                    continue
                callee = item.func.id if isinstance(item.func, ast.Name) else (
                    item.func.attr if isinstance(item.func, ast.Attribute) else "")
                for argument in item.args:
                    first = argument.elts[0] if isinstance(argument, (ast.List, ast.Tuple)) and argument.elts else None
                    if not (isinstance(first, ast.Constant) and isinstance(first.value, str)):
                        continue
                    target = commands.get(runners.get(callee, ""), {}).get(first.value)
                    if not target and len(named.get(first.value, [])) == 1:
                        target = named[first.value][0]
                    if target:
                        node["calls"].append({"to": target, "line": item.lineno, "how": "command"})
            if not spawns:
                continue
            strings = [(item, item.lineno) for item in ast.walk(function)
                       if isinstance(item, ast.Constant) and isinstance(item.value, str)]
            strings += [(constant, item.lineno) for item in ast.walk(function)
                        if isinstance(item, ast.Name) and item.id in module.strings
                        for constant in module.strings[item.id]]
            words = {constant.value for constant, _ in strings}
            for constant, line in strings:
                text = constant.value
                if DOTTED.fullmatch(text):
                    found = head.module(path, text, 0)
                    matches = [found] if found else []
                elif text.endswith(".py"):
                    matches = [script for script in scripts if script == text or script.endswith("/" + text)]
                else:
                    continue
                if len(matches) != 1 or matches[0] not in scripts:
                    continue
                for identity, command in scripts[matches[0]]:
                    if command is None or command in words:
                        node["calls"].append({"to": identity, "line": line, "how": "command"})

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
    if not any(node["change"] and node["kind"] != "test" for node in nodes.values()):
        return None

    # Changed code that no entry point reaches gets its own start, so no change stays hidden.
    # A private helper starts at its public callers, because the walk shows it folded inside them.
    callers: dict[str, set[str]] = {}
    for identity, node in nodes.items():
        if node["kind"] != "test":
            for call in node["calls"]:
                callers.setdefault(call["to"], set()).add(identity)

    def public_callers(identity: str) -> list[str]:
        found, seen, stack = set(), {identity}, [identity]
        while stack:
            for caller in callers.get(stack.pop(), ()):
                if caller not in seen:
                    seen.add(caller)
                    (found.add if nodes[caller]["public"] else stack.append)(caller)
        return sorted(found)

    reached = reachable(nodes, [entry["id"] for entry in entries])
    starts: list[str] = []
    for identity, node in nodes.items():
        if not node["change"] or node["kind"] == "test" or identity in reached:
            continue
        tops = [] if node["public"] else public_callers(identity)
        starts += tops if 0 < len(tops) <= 3 else [identity]
    starts = sorted(dict.fromkeys(starts), key=lambda identity: (-len(reachable(nodes, [identity])), identity))
    covered: set[str] = set()
    for identity in starts:
        if identity in covered:
            continue
        covered |= reachable(nodes, [identity])
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
