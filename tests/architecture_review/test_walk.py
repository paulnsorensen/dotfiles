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


PROTO = '''from typing import Protocol


class Runner(Protocol):
    def run(self) -> int: ...
    def wait(self) -> bool: ...


class Local:
    def run(self) -> int:
        return 1

    def wait(self) -> bool:
        return True
'''
TOOL = '''import subprocess
import threading
from dataclasses import dataclass, field

import fromargs

from .proto import Runner


@dataclass
class Skipped:
    path: str

    def to_json(self) -> dict:
        return {"path": self.path}


@dataclass
class Evidence:
    skipped: list[Skipped] = field(default_factory=list)

    def to_json(self) -> dict:
        return {"skipped": [item.to_json() for item in self.skipped]}


def handle(argv) -> int:
    return len(argv)


def build_app() -> fromargs.App:
    return fromargs.App("tool", default_command=handle)


def run_all(runners: dict[str, Runner]) -> int:
    runner = runners.get("local")
    return runner.run()


def main(argv=None) -> int:
    subprocess.run(["true"], check=False)
    done = threading.Event()
    done.wait(0)
    return build_app().run(argv)
'''
OTHER = '''class _Conn:
    def execute(self, sql):
        return sql


class _Wrapped(_Conn):
    def execute(self, sql):
        return sql


def poll(job, conn):
    conn.execute("PRAGMA x")
    return job.wait()
'''
ADAPTER = '''class ProcessAdapter:
    def start(self) -> int:
        return self._run_protected()

    def _run_protected(self) -> int:
        return 1
'''
TYPER_CLI = '''import typer

app = typer.Typer()


@app.command("add-node")
def add_node(name: str) -> None:
    print(name)


@app.command()
def list_nodes() -> None:
    print("nodes")
'''
APP_TESTS = '''import subprocess
import sys

from typer.testing import CliRunner

from app.cli import app
from app.proto import Local


def test_add_node():
    assert CliRunner().invoke(app, ["add-node", "x"]).exit_code == 0


def test_tool_module_runs():
    subprocess.run([sys.executable, "-m", "app.tool", "x"], check=True)


def test_event_is_not_the_runner():
    import threading
    released = threading.Event()
    assert not released.wait(0)


def test_local_runner():
    assert Local().run() == 1
'''


class ResolutionTests(unittest.TestCase):
    """Regressions from real repositories: foreign values, CLI frameworks, and hidden private changes."""

    def setUp(self):
        common = {"app/__init__.py": "", "app/proto.py": PROTO, "app/other.py": OTHER}
        base = files({**common, "app/tool.py": TOOL, "app/adapter.py": ADAPTER, "app/cli.py": TYPER_CLI})
        head = files({**common,
                      "app/tool.py": TOOL.replace("return len(argv)", "return len(argv) + 1")
                      .replace('{"path": self.path}', '{"path": self.path, "kind": "size"}')
                      .replace('{"skipped": [', '{"version": 2, "skipped": ['),
                      "app/adapter.py": ADAPTER.replace("return 1", "return 2"),
                      "app/cli.py": TYPER_CLI.replace("print(name)", "print(name.upper())"),
                      "tests/test_app.py": APP_TESTS})
        self.doc = {"schema": 1, "base": "a" * 40, "head": "b" * 40,
                    "snapshots": {"base": {"files": base}, "head": {"files": head}}}
        self.walk = walk.build_walk(self.doc)
        self.nodes = self.walk["nodes"]
        self.entries = {entry["id"]: entry for entry in self.walk["entries"]}

    def calls(self, identity):
        return {(call["to"], call["how"]) for call in self.nodes[identity]["calls"]}

    def test_standard_library_values_do_not_dispatch_to_repository_methods(self):
        targets = {target for target, _ in self.calls("app/tool.py::main")}
        self.assertNotIn("app/proto.py::Runner.run", targets)
        self.assertNotIn("app/proto.py::Runner.wait", targets)
        self.assertEqual(targets, {"app/tool.py::build_app"})
        self.assertNotIn("tests/test_app.py::test_event_is_not_the_runner", self.nodes)

    def test_method_names_do_not_dispatch_to_private_or_unimported_owners(self):
        self.assertNotIn("app/other.py::poll", self.nodes)
        poll = walk.calls_in(*self.program_parts("app/other.py", "poll"))
        self.assertEqual(poll, [])

    def program_parts(self, path, name):
        program = walk.Program(self.doc["snapshots"]["head"]["files"])
        module = program.modules[path]
        return program, module, module.funcs[name], None, walk.dispatch_table(program)

    def test_value_taken_from_an_annotated_mapping_dispatches_through_its_protocol(self):
        calls = walk.calls_in(*self.program_parts("app/tool.py", "run_all"))
        self.assertEqual([(call["to"], call["how"]) for call in calls], [("app/proto.py::Runner.run", "dynamic")])

    def test_function_passed_as_an_argument_is_a_call(self):
        self.assertIn(("app/tool.py::handle", "ref"), self.calls("app/tool.py::build_app"))
        self.assertEqual(self.nodes["app/tool.py::handle"]["change"], "body")
        self.assertNotIn("app/tool.py::handle", [entry for entry, item in self.entries.items() if item.get("orphan")])

    def test_cli_decorators_register_entry_points_and_drive_tests(self):
        self.assertEqual(self.entries["app/cli.py::add_node"]["label"], "cli add-node")
        self.assertEqual(self.entries["app/cli.py::list_nodes"]["label"], "cli list-nodes")
        test = self.nodes["tests/test_app.py::test_add_node"]
        self.assertTrue(test["e2e"])
        self.assertIn(("app/cli.py::add_node", "command"), self.calls(test["id"]))

    def test_subprocess_module_run_drives_the_entry_point(self):
        test = self.nodes["tests/test_app.py::test_tool_module_runs"]
        self.assertTrue(test["e2e"])
        self.assertIn(("app/tool.py::main", "command"), self.calls(test["id"]))

    def test_loop_item_type_comes_from_the_field_annotation(self):
        self.assertIn(("app/tool.py::Skipped.to_json", "direct"), self.calls("app/tool.py::Evidence.to_json"))
        orphans = [entry for entry, item in self.entries.items() if item.get("orphan")]
        self.assertIn("app/tool.py::Evidence.to_json", orphans)
        self.assertNotIn("app/tool.py::Skipped.to_json", orphans)

    def test_changed_private_helper_starts_at_its_public_caller(self):
        orphans = [entry for entry, item in self.entries.items() if item.get("orphan")]
        self.assertIn("app/adapter.py::ProcessAdapter.start", orphans)
        self.assertNotIn("app/adapter.py::ProcessAdapter._run_protected", orphans)

    def test_no_changed_python_code_has_no_walk(self):
        head = dict(self.doc["snapshots"]["base"]["files"])
        head["tests/test_app.py"] = {"blob": "0" * 40, "text": APP_TESTS}
        head["src/lib.rs"] = {"blob": "1" * 40, "text": "fn main() {}\n"}
        doc = {**self.doc, "snapshots": {"base": self.doc["snapshots"]["base"], "head": {"files": head}}}
        self.assertIsNone(walk.build_walk(doc))


if __name__ == "__main__":
    unittest.main()
