"""Tests for the affected-change selector behind `just check`."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import affected

TOPS = frozenset({"bin", "skills", "claude", "agents", "docs", "tests", "justfile"})

FIXTURE = {
    "justfile": "check:\n\t./tests/check-affected.sh\n",
    "notes.txt": "unrelated\n",
    "bin/mytool": '#!/usr/bin/env bash\nsource "${0%/*}/lib/common.sh"\n',
    "bin/lib/common.sh": "common() { :; }\n",
    "agents/hooks/sync.sh": '#!/usr/bin/env bash\n. "$DIR/lib.sh"\n',
    "agents/hooks/lib.sh": "hook_lib() { :; }\n",
    "agents/other/lib.sh": "other_lib() { :; }\n",
    "skills/foo/SKILL.md": "# Foo\n",
    "docs/guide.md": "# Guide\n",
    "docs/other.md": "# Other\n",
    "packages/sync.sh": 'PIN="v1"\n',
    "skills/bar/scripts/main.py": "from helper import value\n",
    "skills/bar/scripts/helper.py": "value = 1\n",
    "tests/bar.bats": '@test "bar" {\n    run python3 "$DOTFILES_DIR/skills/bar/scripts/main.py"\n}\n',
    "claude/workflows/a.js": "export default 1\n",
    "claude/workflows/b.js": "export default 2\n",
    "tests/test_helper.bash": (
        'export PATH="$REAL_DOTFILES_DIR/bin:$PATH"\n'
        "pin_version() {\n"
        '    sed -n p "$REAL_DOTFILES_DIR/packages/sync.sh"\n'
        "}\n"
    ),
    "tests/tool.bats": '@test "tool" {\n    run mytool --help\n}\n',
    "tests/hooks.bats": '@test "hooks" {\n    run "$DOTFILES_DIR/agents/hooks/sync.sh"\n}\n',
    "tests/skills.bats": (
        '@test "skills" {\n    for f in "$DOTFILES_DIR"/skills/*/SKILL.md; do :; done\n}\n'
    ),
    "tests/pin.bats": '@test "pin" {\n    [[ "$(pin_version)" == v1 ]]\n}\n',
    "tests/docs.bats": '@test "docs" {\n    grep -q Guide "$DOTFILES_DIR/docs/guide.md"\n}\n',
    "bin/inner": "#!/usr/bin/env bash\necho inner\n",
    "bin/outer": '#!/usr/bin/env bash\nexec "${0%/*}/inner"\n',
    "tests/outer.bats": '@test "outer" {\n    run outer\n}\n',
    "chezmoi/.chezmoitemplates/frag": "fragment\n",
    "chezmoi/page.tmpl": '{{ includeTemplate "frag" . }}\n',
    "tests/page.bats": '@test "page" {\n    run render chezmoi/page.tmpl\n}\n',
    "pkg/baz/util.py": "x = 1\n",
    "pkg/qux/util.py": "x = 2\n",
    "pkg/use.py": "from baz.util import x\n",
    "tests/use.bats": '@test "use" {\n    run python3 pkg/use.py\n}\n',
    "bin/leaf": "#!/usr/bin/env bash\necho leaf\n",
    "data/weights.tsv": "leaf\t3\n",
    "bin/viaweights": "#!/usr/bin/env bash\ncat data/weights.tsv\n",
    "tests/leaf.bats": '@test "leaf" {\n    run leaf\n}\n',
    "tests/viaweights.bats": '@test "via" {\n    run viaweights\n}\n',
    "tests/workflows/harness.mjs": "export const run = () => 0\n",
    "tests/workflows/a.test.mjs": (
        "const path = resolve(import.meta.dirname, '../../claude/workflows/a.js')\n"
    ),
    "tests/workflows/b.test.mjs": (
        "const path = resolve(import.meta.dirname, '../../claude/workflows/b.js')\n"
    ),
}


def sh(root: Path, *args: str) -> None:
    subprocess.run(args, cwd=root, check=True, capture_output=True)


class FixtureRepo(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        for name, text in FIXTURE.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        sh(self.root, "git", "init", "-q")
        sh(self.root, "git", "add", ".")
        sh(
            self.root,
            "git",
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "fixture",
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def plan(self, *changed: str) -> dict[str, set[str] | None]:
        return affected.build_plan(self.root, list(changed)).files


class PathTokenTest(unittest.TestCase):
    def test_variables_become_globs_and_prefixes_drop(self) -> None:
        text = (
            'for f in "$DOTFILES_DIR"/skills/*/SKILL.md\n'
            'run "${BATS_TEST_DIRNAME}/../claude/workflows/a.js"\n'
            'export PATH="$DOTFILES_DIR/bin:$PATH"\n'
            'cat "$DOTFILES_DIR/skills/$name/SKILL.md"\n'
            "see https://github.com/owner/repo\n"
        )
        self.assertEqual(
            affected.path_tokens(text, TOPS),
            {"skills/*/SKILL.md", "claude/workflows/a.js", "bin"},
        )

    def test_unresolvable_variables_are_dropped(self) -> None:
        self.assertEqual(affected.path_tokens('cat "$1/bin/x"', TOPS), set())


class TokenMatchTest(unittest.TestCase):
    def test_exact_directory_glob_and_sibling_rules(self) -> None:
        cases = [
            ("bin/mytool", "bin/mytool", True),
            ("agents/hooks", "agents/hooks/lib.sh", True),
            ("skills/*/SKILL.md", "skills/foo/SKILL.md", True),
            ("skills/*/SKILL.md", "skills/foo/refs/x.md", False),
            # Siblings do not match: the source closure finds real users.
            ("agents/hooks/sync.sh", "agents/hooks/lib.sh", False),
            # One-segment tokens match only exactly: `$DIR/bin` on PATH is common.
            ("bin", "bin/mytool", False),
            # Two-segment files have a one-segment directory: no sibling rule.
            ("bin/mytool", "bin/other", False),
        ]
        for token, path, expected in cases:
            with self.subTest(token=token, path=path):
                self.assertIs(affected.token_matches(token, path), expected)


class WordTest(unittest.TestCase):
    def test_word_boundaries(self) -> None:
        self.assertTrue(affected.has_word("run mytool --help", "mytool"))
        self.assertTrue(affected.has_word("mytool", "mytool"))
        self.assertFalse(affected.has_word("run mytools", "mytool"))
        self.assertFalse(affected.has_word("my_mytool", "mytool"))

    def test_needles_use_parent_for_shared_basenames(self) -> None:
        counts = affected.Counter({"lib.sh": 2, "util.py": 2, "mytool": 1})
        self.assertEqual(affected.needles("bin/mytool", counts), ["mytool"])
        self.assertEqual(
            affected.needles("agents/hooks/lib.sh", counts), ["hooks/lib.sh"]
        )
        self.assertEqual(
            affected.needles("pkg/baz/util.py", counts),
            ["baz/util.py", "baz/util", "baz.util"],
        )

    def test_needles_match_an_extensionless_cross_directory_require(self) -> None:
        counts = affected.Counter({"native.js": 1})
        words = affected.needles("agents/lib/tool-reroute/native.js", counts)
        self.assertIn("tool-reroute/native", words)
        self.assertTrue(
            any(affected.has_word("require('./tool-reroute/native')", w) for w in words)
        )


def _closure(changed: list[str], users: dict[str, set[str]]) -> dict[str, str]:
    return affected.source_closure(
        changed, [], affected.Counter(), lambda word: users.get(word, set())
    )


def _many(n: int) -> set[str]:
    return {f"bin/u{i}" for i in range(n)}


class ClosureHubTest(unittest.TestCase):
    def test_a_hub_joins_the_origin_but_passes_the_change_on_to_no_one(self) -> None:
        closure = _closure(["bin/a"], {"a": {"bin/b"}, "b": _many(11)})
        self.assertEqual(set(closure), {"bin/a", "bin/b"})

    def test_a_hub_own_test_is_selected(self) -> None:
        # A lib sourced by a hub: the hub's test exercises the lib through it.
        closure = _closure(["bin/a"], {"a": {"bin/b"}, "b": _many(11)})
        tests = {"tests/b.bats": "run b\n", "tests/other.bats": "run zzz\n"}
        selected, _ = affected.select_tests(
            tests, closure, TOPS, affected.Counter(), {}
        )
        self.assertEqual(selected, {"tests/b.bats"})

    def test_the_fan_in_boundary_is_ten_users(self) -> None:
        ten = _closure(["bin/a"], {"a": {"bin/b"}, "b": _many(10)})
        self.assertTrue(_many(10) <= set(ten))
        eleven = _closure(["bin/a"], {"a": {"bin/b"}, "b": _many(11)})
        self.assertFalse(_many(11) & set(eleven))

    def test_a_changed_hub_still_expands(self) -> None:
        closure = _closure(["bin/b"], {"b": _many(11)})
        self.assertTrue(_many(11) <= set(closure))

    def test_a_file_with_few_users_passes_the_change_on(self) -> None:
        closure = _closure(["bin/a"], {"a": {"bin/b"}, "b": {"bin/c"}})
        self.assertEqual(set(closure), {"bin/a", "bin/b", "bin/c"})

    def test_test_gate_and_data_files_never_join(self) -> None:
        excluded = {
            "tests/x.bats",
            "tests/workflows/x.test.mjs",
            "tests/helper.bash",
            "justfile",
            "tests/run-tests.sh",
            "data/w.tsv",
            "cfg/x.yaml",
        }
        closure = _closure(["bin/a"], {"a": excluded | {"bin/c"}})
        self.assertEqual(set(closure), {"bin/a", "bin/c"})


class BuildPlanTest(FixtureRepo):
    def test_markdown_only_change_lints_the_file_and_runs_its_readers(self) -> None:
        self.assertEqual(
            self.plan("docs/guide.md"),
            {"lint-markdown": {"docs/guide.md"}, "test": {"tests/docs.bats"}},
        )

    def test_unread_markdown_runs_markdown_lint_only(self) -> None:
        self.assertEqual(
            self.plan("docs/other.md"), {"lint-markdown": {"docs/other.md"}}
        )

    def test_sourced_library_selects_the_tests_of_its_callers(self) -> None:
        plan = self.plan("bin/lib/common.sh")
        self.assertEqual(plan["test"], {"tests/tool.bats"})
        self.assertIsNone(plan["lint-shell"])

    def test_same_directory_source_selects_tests_of_the_sourcing_file(self) -> None:
        plan = self.plan("agents/hooks/lib.sh")
        self.assertEqual(plan["test"], {"tests/hooks.bats"})
        self.assertIsNone(plan["test-python"])
        self.assertNotIn("test", self.plan("agents/other/lib.sh"))

    def test_python_import_selects_tests_of_the_importing_module(self) -> None:
        plan = self.plan("skills/bar/scripts/helper.py")
        self.assertEqual(plan["test"], {"tests/bar.bats"})
        self.assertIsNone(plan["lint-python"])

    def test_glob_token_selects_iterating_test(self) -> None:
        plan = self.plan("skills/foo/SKILL.md")
        self.assertEqual(plan["test"], {"tests/skills.bats"})

    def test_helper_function_paths_reach_calling_tests(self) -> None:
        plan = self.plan("packages/sync.sh")
        self.assertEqual(plan["test"], {"tests/pin.bats"})

    def test_workflow_source_selects_one_smoke_file(self) -> None:
        self.assertEqual(
            self.plan("claude/workflows/a.js"),
            {"smoke": {"tests/workflows/a.test.mjs"}},
        )

    def test_changed_test_file_selects_itself(self) -> None:
        self.assertEqual(self.plan("tests/tool.bats"), {"test": {"tests/tool.bats"}})

    def test_shared_test_infrastructure_runs_whole_suite(self) -> None:
        self.assertEqual(self.plan("tests/test_helper.bash")["test"], None)
        self.assertEqual(self.plan("tests/workflows/harness.mjs"), {"smoke": None})

    def test_gate_change_runs_every_leg(self) -> None:
        plan = self.plan("justfile")
        self.assertEqual(set(plan), set(affected.LEGS))
        self.assertTrue(all(files is None for files in plan.values()))

    def test_unobserved_change_is_reported_and_runs_the_whole_test_leg(self) -> None:
        plan = affected.build_plan(
            self.root, ["notes.txt", "docs/guide.md", "gone.txt"]
        )
        # gone.txt does not exist: a deletion that no test names needs no report.
        self.assertEqual(plan.unmatched, ["notes.txt"])
        self.assertIsNone(plan.files["test"])
        self.assertIn("notes.txt", plan.reason)

    def test_deleted_unnamed_path_runs_nothing(self) -> None:
        self.assertEqual(self.plan("gone.txt"), {})

    def test_script_run_by_path_selects_tests_of_the_caller(self) -> None:
        # bin/outer runs bin/inner by path; only outer.bats names `outer`.
        self.assertEqual(self.plan("bin/inner")["test"], {"tests/outer.bats"})

    def test_include_template_selects_tests_of_the_including_file(self) -> None:
        plan = self.plan("chezmoi/.chezmoitemplates/frag")
        self.assertEqual(plan["test"], {"tests/page.bats"})

    def test_dotted_python_import_of_a_shared_basename(self) -> None:
        plan = self.plan("pkg/baz/util.py")
        self.assertEqual(plan["test"], {"tests/use.bats"})

    def test_data_file_hub_does_not_fan_out(self) -> None:
        # weights.tsv names `leaf`; viaweights reads weights.tsv. The data
        # file is no bridge from bin/leaf to the tests of viaweights.
        self.assertEqual(self.plan("bin/leaf")["test"], {"tests/leaf.bats"})

    def test_mise_pin_change_runs_every_lint_leg(self) -> None:
        plan = self.plan("chezmoi/dot_config/mise/config.toml")
        for leg in affected.LINT_LEGS:
            with self.subTest(leg=leg):
                self.assertIsNone(plan[leg])

    def test_no_change_runs_nothing(self) -> None:
        self.assertEqual(self.plan(), {})


class ChangedPathsTest(FixtureRepo):
    def test_includes_committed_modified_and_untracked_paths(self) -> None:
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        (self.root / "docs/guide.md").write_text("# Guide v2\n")
        sh(self.root, "git", "add", "docs/guide.md")
        sh(
            self.root,
            "git",
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "x",
        )
        (self.root / "notes.txt").write_text("changed\n")
        (self.root / "docs/new.md").write_text("# New\n")
        self.assertEqual(
            affected.changed_paths(self.root, base),
            ["docs/guide.md", "docs/new.md", "notes.txt"],
        )


class SpecialPathTest(FixtureRepo):
    def test_quoted_git_paths_are_kept(self) -> None:
        name = "docs/café ü.md"
        (self.root / name).write_text("# Odd\n")
        self.assertEqual(affected.changed_paths(self.root, None), [name])
        self.assertEqual(self.plan(name), {"lint-markdown": {name}})


class CommandLinesTest(unittest.TestCase):
    def test_commands_are_ordered_quoted_and_relative_to_runners(self) -> None:
        plan = affected.Plan()
        plan.add_files("lint-markdown", {"docs/a b.md"})
        plan.add_files("test", {"tests/tool.bats", "tests/docs.bats"})
        plan.run_whole("lint-shell")
        self.assertEqual(
            affected.command_lines(plan),
            [
                "just test docs.bats tool.bats",
                "just lint-shell",
                "just lint-markdown 'docs/a b.md'",
            ],
        )

    def test_whole_leg_wins_over_file_selection(self) -> None:
        plan = affected.Plan()
        plan.run_whole("test")
        plan.add_files("test", {"tests/tool.bats"})
        self.assertEqual(affected.command_lines(plan), ["just test"])


if __name__ == "__main__":
    unittest.main()
