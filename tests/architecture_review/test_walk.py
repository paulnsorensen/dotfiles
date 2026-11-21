"""Contract tests for the static call walk."""

import importlib.util
import unittest
from pathlib import Path


WALK = Path(__file__).resolve().parents[2] / "skills/architecture-review/scripts/walk.py"
spec = importlib.util.spec_from_file_location("architecture_walk", WALK)
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)

CLI = '''from . import build as build_module


def main(argv=None):
    args = list(argv or [])
    sub = args[0] if args else "help"
    if sub == "build":
        return build_module.build(args[1:])
    if sub == "clean":
        return build_module.clean()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''
BUILD_BASE = '''from .render import Plain, render_all


def build(args):
    """Build every target."""
    render_all(Plain())
    return _write(len(args))


def clean():
    return 0


def _write(count):
    return count
'''
BUILD_HEAD = BUILD_BASE.replace("def _write(count):\n", "def _write(count):\n    if count < 0:\n        raise ValueError(\"negative\")\n")
RENDER_BASE = '''from typing import Protocol


class Renderer(Protocol):
    def render(self) -> str: ...


class Plain:
    def render(self) -> str:
        return "plain"


class Fancy:
    def render(self) -> str:
        return "fancy"


def render_all(renderer: Renderer) -> str:
    return renderer.render()
'''
RENDER_HEAD = RENDER_BASE.replace('return "fancy"', 'return "fancy!"')
TESTS = '''from pkg.build import _write, clean
from pkg.cli import main


def run(argv):
    return main(argv)


def test_build_command():
    assert run(["build", "one"]) == 1


def test_write_rejects_nothing():
    assert _write(1) == 1


def test_clean_handler():
    assert clean() == 0
'''


def files(sources):
    return {path: {"blob": "0" * 40, "text": text} for path, text in sources.items()}


class WalkTests(unittest.TestCase):
    def setUp(self):
        common = {"pkg/__init__.py": "", "pkg/cli.py": CLI, "README.md": "# not Python\n",
                  "pkg/unused.py": "def unused():\n    return 0\n"}
        base = files({**common, "pkg/build.py": BUILD_BASE, "pkg/render.py": RENDER_BASE})
        head = files({**common, "pkg/build.py": BUILD_HEAD, "pkg/render.py": RENDER_HEAD,
                      "pkg/extra.py": "def added_alone():\n    return 1\n", "tests/test_cli.py": TESTS})
        self.doc = {"schema": 1, "base": "a" * 40, "head": "b" * 40,
                    "snapshots": {"base": {"files": base}, "head": {"files": head}}}
        self.walk = walk.build_walk(self.doc)
        self.nodes = self.walk["nodes"]

    def test_command_branches_become_entry_points(self):
        entries = {entry["id"]: entry for entry in self.walk["entries"]}
        build = entries["pkg/cli.py::main[build]"]
        self.assertEqual(build["label"], "cli build")
        self.assertIn("pkg/cli.py::main[clean]", entries)
        calls = [call["to"] for call in self.nodes["pkg/cli.py::main[build]"]["calls"]]
        self.assertEqual(calls, ["pkg/build.py::build"])

    def test_private_change_is_reachable_but_not_public(self):
        helper = self.nodes["pkg/build.py::_write"]
        self.assertEqual(helper["change"], "body")
        self.assertFalse(helper["public"])
        self.assertEqual(self.nodes["pkg/build.py::build"]["change"], "")
        guard = BUILD_HEAD.splitlines().index("    if count < 0:") + 1
        self.assertIn(guard, self.walk["added"]["pkg/build.py"])

    def test_call_on_an_object_dispatches_through_the_protocol(self):
        calls = self.nodes["pkg/render.py::render_all"]["calls"]
        self.assertEqual([(call["to"], call["how"]) for call in calls], [("pkg/render.py::Renderer.render", "dynamic")])
        self.assertEqual(sorted(self.nodes["pkg/render.py::Renderer.render"]["overrides"]),
                         ["pkg/render.py::Fancy.render", "pkg/render.py::Plain.render"])
        self.assertEqual(self.nodes["pkg/render.py::Fancy.render"]["change"], "body")

    def test_command_tests_are_end_to_end_and_unit_tests_are_not(self):
        command = self.nodes["tests/test_cli.py::test_build_command"]
        self.assertTrue(command["e2e"])
        self.assertIn({"to": "pkg/cli.py::main[build]", "line": 10, "how": "command"}, command["calls"])
        self.assertFalse(self.nodes["tests/test_cli.py::test_write_rejects_nothing"]["e2e"])
        self.assertTrue(self.nodes["tests/test_cli.py::test_clean_handler"]["e2e"])
        callers = {caller["from"] for caller in self.nodes["pkg/build.py::_write"]["callers"]}
        self.assertEqual(callers, {"pkg/build.py::build", "tests/test_cli.py::test_write_rejects_nothing"})

    def test_change_without_an_entry_point_gets_its_own_start(self):
        orphans = [entry["id"] for entry in self.walk["entries"] if entry.get("orphan")]
        self.assertEqual(orphans, ["pkg/extra.py::added_alone"])

    def test_unchanged_code_that_leads_nowhere_is_pruned(self):
        self.assertIn("pkg/build.py::clean", self.nodes)
        self.assertNotIn("pkg/unused.py::unused", self.nodes)

    def test_single_revision_has_no_walk(self):
        self.assertIsNone(walk.build_walk({"base": None, "snapshots": {"head": self.doc["snapshots"]["head"]}}))

    def test_syntax_error_is_reported_not_raised(self):
        self.doc["snapshots"]["head"]["files"]["pkg/broken.py"] = {"blob": "1" * 40, "text": "def broken(:\n"}
        self.assertEqual(walk.build_walk(self.doc)["unparsed"], ["pkg/broken.py"])


if __name__ == "__main__":
    unittest.main()
