"""Behavior tests for the Rust syntax adapter."""

import importlib.util
from pathlib import Path
import shutil
import unittest


ADAPTER = Path(__file__).resolve().parents[2] / "skills/architecture-review/scripts/evidence/rust_adapter.py"
SPEC = importlib.util.spec_from_file_location("rust_adapter", ADAPTER)
assert SPEC and SPEC.loader
rust_adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rust_adapter)
GRAPH = ADAPTER.with_name("graph.py")
GRAPH_SPEC = importlib.util.spec_from_file_location("architecture_graph", GRAPH)
assert GRAPH_SPEC and GRAPH_SPEC.loader
architecture_graph = importlib.util.module_from_spec(GRAPH_SPEC)
GRAPH_SPEC.loader.exec_module(architecture_graph)


@unittest.skipUnless(shutil.which("ast-grep"), "ast-grep is not installed")
class RustAdapterTests(unittest.TestCase):
    def test_local_items_calls_and_unknown_boundaries(self):
        source = """pub mod api {
    pub fn run() { helper(); crate::api::helper(); x.work(); panic!(\"stop\"); }
    fn helper() {}
}
use crate::api::run;
mod external;
"""
        result = rust_adapter.extract("src/lib.rs", source)
        self.assertFalse(result["failed"])
        defs = {item["qual"]: item for item in result["defs"]}
        self.assertEqual(set(defs), {"api", "api::run", "api::helper", "external"})
        self.assertTrue(defs["api"]["public"])
        self.assertFalse(defs["api::helper"]["public"])
        refs = result["refs"]
        self.assertIn("src/lib.rs::api::helper", [target for ref in refs for target in ref["targets"]])
        self.assertIn("src/lib.rs::api::run", [target for ref in refs for target in ref["targets"]])
        reasons = " ".join(item["reason"] for item in result["unknowns"])
        self.assertIn("method", reasons)
        self.assertIn("macro", reasons)
        self.assertIn("external", reasons)

    def test_restricted_visibility_and_methods_are_not_overclaimed(self):
        source = "pub(crate) struct Thing; impl Thing { pub fn act(&self) {} }\n"
        result = rust_adapter.extract("src/lib.rs", source)
        defs = {item["qual"]: item for item in result["defs"]}
        self.assertFalse(defs["Thing"]["public"])
        self.assertNotIn("act", defs)
        self.assertIn("method identity", " ".join(item["reason"] for item in result["unknowns"]))

    def test_shadowed_function_calls_are_unknown(self):
        source = "fn target() {}\nfn run(target: fn()) { target(); }\nfn local() { let target = || {}; target(); }\nfn destructure() { let (target, _) = (|| {}, 0); target(); }\n"
        result = rust_adapter.extract("src/lib.rs", source)
        self.assertFalse(any(ref["kind"] == "call" and "src/lib.rs::target" in ref["targets"] for ref in result["refs"]))
        self.assertTrue(any("shadow" in item["reason"] for item in result["unknowns"]))

    def test_external_module_candidates_resolve_by_graph_inventory(self):
        source = "mod foo;\nuse crate::foo::target;\nfn run() { crate::foo::target(); }\n"
        result = rust_adapter.extract("src/lib.rs", source)
        targets = [target for ref in result["refs"] for target in ref["targets"]]
        self.assertIn("src/foo.rs", targets)
        self.assertIn("src/foo/mod.rs", targets)
        self.assertIn("src/foo.rs::target", targets)
        self.assertIn("src/foo/mod.rs::target", targets)
        foo = rust_adapter.extract("src/foo.rs", "pub fn target() {}\n")
        files = {"src/lib.rs": {"blob": "lib", "language": "Rust", "text": source},
                 "src/foo.rs": {"blob": "foo", "language": "Rust", "text": "pub fn target() {}\n"}}
        graph = architecture_graph.assemble("test", files, {"src/lib.rs": result, "src/foo.rs": foo}, [])
        edges = [edge for edge in graph["edges"] if edge["target"] == "src/foo.rs::target"]
        self.assertEqual({"use", "call"}, {edge["kind"] for edge in edges})
        self.assertTrue(any(edge["kind"] == "module" and edge["target"] == "src/foo.rs" for edge in graph["edges"]))

    def test_external_module_attributes_remain_unknown(self):
        result = rust_adapter.extract("src/lib.rs", "#[cfg(feature = \"x\")]\nmod foo;\n")
        self.assertFalse(any(ref["kind"] == "module" for ref in result["refs"]))
        self.assertTrue(any("attributes" in item["reason"] for item in result["unknowns"]))

    def test_invalid_syntax_is_not_reported_as_complete(self):
        result = rust_adapter.extract("src/lib.rs", "fn broken( {\n")
        self.assertTrue(result["failed"])
        self.assertIn("syntax error", result["unknowns"][0]["reason"])

    def test_missing_parser_reports_failure(self):
        original = rust_adapter.shutil.which
        rust_adapter.shutil.which = lambda _name: None
        try:
            result = rust_adapter.extract("src/lib.rs", "fn main() {}")
        finally:
            rust_adapter.shutil.which = original
        self.assertTrue(result["failed"])
        self.assertIn("ast-grep", result["unknowns"][0]["reason"])


if __name__ == "__main__":
    unittest.main()
