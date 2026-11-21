import importlib.util
import unittest
from pathlib import Path
from typing import Protocol, TypedDict, cast


class Ref(TypedDict):
    kind: str
    targets: list[str]


class Unknown(TypedDict):
    line: int


class Evidence(TypedDict):
    refs: list[Ref]
    unknowns: list[Unknown]
    failed: bool


class Adapter(Protocol):
    def extract(self, path: str, text: str) -> Evidence: ...


MODULE = Path(__file__).resolve().parents[2] / "skills/architecture-review/scripts/evidence/python_adapter.py"
SPEC = importlib.util.spec_from_file_location("python_adapter", MODULE)
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
adapter = cast(Adapter, cast(object, module))


class PythonAdapterTest(unittest.TestCase):
    def test_real_compile_target_calls_resolve_to_two_validators(self):
        path = "agent-profile/agent_profile/compile_target_presence.py"
        text = (Path(__file__).resolve().parents[2] / path).read_text()
        result = adapter.extract(path, text)
        targets = {target for ref in result["refs"] for target in ref["targets"] if ref["kind"] == "call"}
        self.assertIn("agent-profile/agent_profile/compile_target_validation.py::validate_compile_targets", targets)
        self.assertIn("agent-profile/agent_profile/harness_field_coverage.py::validate_harness_field_coverage", targets)
        self.assertFalse(result["failed"])

    def test_shadowed_import_and_dynamic_attribute_are_unknown(self):
        text = "from pkg.validator import check\n\ndef run(check, obj):\n    check()\n    obj.check()\n"
        result = adapter.extract("pkg/main.py", text)
        self.assertFalse(any(ref["kind"] == "call" for ref in result["refs"]))
        self.assertEqual(2, len(result["unknowns"]))

    def test_relative_import_and_local_call(self):
        text = "from .validator import check as verify\n\ndef run():\n    verify()\n    local()\n\ndef local():\n    pass\n"
        result = adapter.extract("pkg/main.py", text)
        refs = [ref for ref in result["refs"] if ref["kind"] == "call"]
        targets = {target for ref in refs for target in ref["targets"]}
        self.assertIn("pkg/validator.py::check", targets)
        self.assertIn("pkg/main.py::local", targets)

    def test_module_rebinding_does_not_resolve_import(self):
        text = "from pkg.validator import check\ncheck = lambda: None\ncheck()\n"
        result = adapter.extract("pkg/main.py", text)
        self.assertFalse(any(ref["kind"] == "call" for ref in result["refs"]))
        self.assertTrue(any(item["line"] == 3 for item in result["unknowns"]))

    def test_closure_parameter_shadows_module_definition(self):
        text = "def target():\n    pass\n\ndef outer(target):\n    def inner():\n        target()\n"
        result = adapter.extract("pkg/main.py", text)
        self.assertFalse(any(ref["kind"] == "call" and "pkg/main.py::target" in ref["targets"] for ref in result["refs"]))
        self.assertTrue(any(item["line"] == 6 for item in result["unknowns"]))

    def test_syntax_error_marks_failed(self):
        result = adapter.extract("bad.py", "def broken(:\n")
        self.assertTrue(result["failed"])
        self.assertTrue(result["unknowns"])


if __name__ == "__main__":
    _ = unittest.main()
