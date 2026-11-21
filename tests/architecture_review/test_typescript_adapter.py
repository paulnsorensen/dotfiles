import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[2] / "skills/architecture-review/scripts/evidence/typescript_adapter.py"
SPEC = importlib.util.spec_from_file_location("typescript_adapter", MODULE)
assert SPEC and SPEC.loader
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


class TypeScriptAdapterTests(unittest.TestCase):
    def test_value_type_and_local_calls(self):
        source = """import type { Shape } from './shape';
import { read as fetch } from './reader';
export interface Contract { value: Shape }
export function run(item: Contract) {
  const data = fetch();
  return helper(data);
}
function helper(value: unknown) { return value; }
"""
        result = adapter.extract("src/main.ts", source)
        self.assertFalse(result["failed"], result)
        definitions = {item["qual"]: item for item in result["defs"]}
        self.assertTrue(definitions["Contract"]["public"])
        self.assertTrue(definitions["run"]["public"])
        self.assertFalse(definitions["helper"]["public"])
        refs = result["refs"]
        self.assertTrue(any(ref["kind"] == "type_import" and "src/shape.ts::Shape" in ref["targets"] for ref in refs))
        self.assertTrue(any(ref["kind"] == "import" and "src/reader.ts::read" in ref["targets"] for ref in refs))
        self.assertTrue(any(ref["kind"] == "call" and ref["source"] == "run" and ref["targets"] == ["src/main.ts::helper"] for ref in refs))
        self.assertTrue(any(ref["kind"] == "call" and ref["source"] == "run" and "src/reader.ts::read" in ref["targets"] for ref in refs))

    def test_tsx_and_dynamic_or_shadowed_are_unknown(self):
        source = """export function View({handler}: {handler: () => void}) {
  function local() { return 1; }
  const localAlias = local;
  handler();
  localAlias();
  local();
  return <button onClick={handler}>OK</button>;
}
"""
        result = adapter.extract("src/view.tsx", source)
        self.assertFalse(result["failed"], result)
        self.assertTrue(any(d["qual"] == "View" and d["public"] for d in result["defs"]))
        self.assertEqual(1, sum(r["kind"] == "call" and r["targets"] == ["src/view.tsx::View.local"] for r in result["refs"]))
        self.assertTrue(any("shadowed" in u["reason"] for u in result["unknowns"]), result)

    def test_same_name_in_sibling_scope_does_not_create_a_call_edge(self):
        source = """function first() { function work() {} work(); }
function second() { function work() {} work(); }
export function entry() { work(); }
"""
        result = adapter.extract("src/scopes.ts", source)
        calls = [ref for ref in result["refs"] if ref["kind"] == "call"]
        self.assertTrue(any(ref["source"] == "first" and ref["targets"] == ["src/scopes.ts::first.work"] for ref in calls))
        self.assertTrue(any(ref["source"] == "second" and ref["targets"] == ["src/scopes.ts::second.work"] for ref in calls))
        self.assertFalse(any(ref["source"] == "entry" for ref in calls))
        self.assertTrue(any("unknown" in item["reason"] for item in result["unknowns"]))

    def test_variable_shadows_import_binding(self):
        source = """import { load } from './loader';
function run() { const load = get(); load(); }
"""
        result = adapter.extract("src/main.ts", source)
        self.assertFalse(any(ref["kind"] == "call" and "src/loader.ts::load" in ref["targets"]
                             for ref in result["refs"]))
        self.assertTrue(any("shadowed" in item["reason"] for item in result["unknowns"]))

    def test_named_export_marks_declared_entity_public(self):
        result = adapter.extract("src/api.ts", "function serve() {}\nexport { serve };\n")
        self.assertFalse(result["failed"], result)
        self.assertTrue(next(item for item in result["defs"] if item["qual"] == "serve")["public"])

    def test_side_effect_import_targets_file_identity(self):
        result = adapter.extract("src/main.ts", "import './setup.ts';")
        self.assertFalse(result["failed"], result)
        self.assertTrue(any(ref["kind"] == "import" and ref["targets"] == ["src/setup.ts"]
                            for ref in result["refs"]))

    def test_missing_parser_is_failed_not_empty(self):
        with patch.object(adapter, "_ast_grep", return_value=None):
            result = adapter.extract("x.ts", "export function start() {}")
        self.assertTrue(result["failed"])
        self.assertTrue(result["unknowns"])

    def test_parse_error_is_failed(self):
        result = adapter.extract("x.ts", "export function broken( {")
        self.assertTrue(result["failed"])
        self.assertTrue(result["unknowns"])


if __name__ == "__main__":
    unittest.main()
