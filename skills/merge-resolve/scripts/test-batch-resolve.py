#!/usr/bin/env python3
"""Tests for batch-resolve.py.

Creates temporary git repos with real merge conflicts, then verifies that
batch-resolve correctly identifies and resolves them using mergiraf.

The key challenge: mergiraf runs as a git merge driver (globally configured),
so it resolves many conflicts at merge time. Tests that need conflicts to
survive to the working copy use scenarios where even mergiraf-as-driver leaves
conflict markers (same-position additions that mergiraf can still improve via
`mergiraf solve` on the working copy, or truly unresolvable same-line edits).
"""

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BATCH_RESOLVE = os.path.join(SCRIPT_DIR, "batch-resolve.py")


def run(cmd, cwd=None, env=None, check=True):
    result = subprocess.run(
        cmd, capture_output=True, text=True, cwd=cwd, timeout=30, env=env,
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, result.stdout, result.stderr
        )
    return result


def has_mergiraf():
    try:
        run(["mergiraf", "languages"])
        return True
    except FileNotFoundError:
        return False


def git(args, cwd):
    return run(["git"] + args, cwd=cwd)


def create_repo(tmpdir):
    git(["init", "-b", "main"], tmpdir)
    git(["config", "user.email", "test@test.com"], tmpdir)
    git(["config", "user.name", "Test"], tmpdir)
    git(["config", "merge.mergiraf.name", "mergiraf"], tmpdir)
    git(["config", "merge.mergiraf.driver",
         'mergiraf merge --git "%O" "%A" "%B" -s "%S" -x "%X" -y "%Y" -p "%P"'], tmpdir)

    attrs = os.path.join(tmpdir, ".gitattributes")
    with open(attrs, "w") as f:
        f.write("*.py merge=mergiraf\n*.json merge=mergiraf\n*.rs merge=mergiraf\n")

    git(["add", ".gitattributes"], tmpdir)
    git(["commit", "-m", "init"], tmpdir)
    return tmpdir


def create_conflict_same_line(repo):
    base_py = os.path.join(repo, "config.py")
    with open(base_py, "w") as f:
        f.write("VERSION = '1.0.0'\n")
    git(["add", "config.py"], repo)
    git(["commit", "-m", "base config"], repo)

    git(["checkout", "-b", "bump-a"], repo)
    with open(base_py, "w") as f:
        f.write("VERSION = '2.0.0'\n")
    git(["add", "config.py"], repo)
    git(["commit", "-m", "bump to 2.0"], repo)

    git(["checkout", "main"], repo)
    git(["checkout", "-b", "bump-b"], repo)
    with open(base_py, "w") as f:
        f.write("VERSION = '3.0.0'\n")
    git(["add", "config.py"], repo)
    git(["commit", "-m", "bump to 3.0"], repo)

    git(["checkout", "main"], repo)
    git(["merge", "bump-a"], repo)
    result = run(["git", "merge", "bump-b"], cwd=repo, check=False)
    return result.returncode != 0


def get_conflicted_count(repo):
    result = git(["diff", "--name-only", "--diff-filter=U"], repo)
    return len([f for f in result.stdout.strip().splitlines() if f])


def _setup_shell_conflict(repo):
    sh_file = os.path.join(repo, "setup.sh")
    with open(sh_file, "w") as f:
        f.write("echo 'hello'\n")
    git(["add", "setup.sh"], repo)
    git(["commit", "-m", "add script"], repo)

    git(["checkout", "-b", "sh-a"], repo)
    with open(sh_file, "w") as f:
        f.write("echo 'hello from a'\n")
    git(["add", "setup.sh"], repo)
    git(["commit", "-m", "modify a"], repo)

    git(["checkout", "main"], repo)
    git(["checkout", "-b", "sh-b"], repo)
    with open(sh_file, "w") as f:
        f.write("echo 'hello from b'\n")
    git(["add", "setup.sh"], repo)
    git(["commit", "-m", "modify b"], repo)

    git(["checkout", "main"], repo)
    git(["merge", "sh-a"], repo)
    result = run(["git", "merge", "sh-b"], cwd=repo, check=False)
    return result.returncode != 0


def _setup_two_file_conflict(repo):
    app_py = os.path.join(repo, "app.py")
    cfg_py = os.path.join(repo, "config.py")
    with open(app_py, "w") as f:
        f.write("import os\nimport sys\n\n\ndef main():\n    pass\n\n\ndef helper():\n    pass\n")
    with open(cfg_py, "w") as f:
        f.write("VERSION = '1.0.0'\n")
    git(["add", "app.py", "config.py"], repo)
    git(["commit", "-m", "base both files"], repo)

    git(["checkout", "-b", "branch-a"], repo)
    with open(app_py, "w") as f:
        f.write("import os\nimport sys\nimport json\n\n\ndef main():\n    pass\n\n\ndef helper():\n    pass\n")
    with open(cfg_py, "w") as f:
        f.write("VERSION = '2.0.0'\n")
    git(["add", "app.py", "config.py"], repo)
    git(["commit", "-m", "branch-a changes"], repo)

    git(["checkout", "main"], repo)
    git(["checkout", "-b", "branch-b"], repo)
    with open(app_py, "w") as f:
        f.write("import os\nimport sys\n\n\ndef main():\n    pass\n\n\ndef helper():\n    pass\n\n\ndef extra():\n    return 42\n")
    with open(cfg_py, "w") as f:
        f.write("VERSION = '3.0.0'\n")
    git(["add", "app.py", "config.py"], repo)
    git(["commit", "-m", "branch-b changes"], repo)

    git(["checkout", "main"], repo)
    git(["merge", "branch-a"], repo)
    result = run(["git", "merge", "branch-b"], cwd=repo, check=False)
    return result.returncode != 0


@unittest.skipUnless(has_mergiraf(), "mergiraf not installed")
class TestBatchResolve(unittest.TestCase):
    def _run_batch(self, cwd, *extra_args):
        return run(
            [sys.executable, BATCH_RESOLVE] + list(extra_args),
            cwd=cwd, check=False,
        )

    def test_no_conflicts(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            result = self._run_batch(tmpdir, "--dry-run")
            self.assertEqual(result.returncode, 0)
            self.assertIn("No conflicted files", result.stdout)

    def test_unresolvable_conflict_reported(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            had_conflict = create_conflict_same_line(tmpdir)
            if not had_conflict:
                self.skipTest("no conflict produced")

            result = self._run_batch(tmpdir, "--dry-run")
            self.assertIn("CONFLICT", result.stdout)
            self.assertIn("Unresolved:", result.stdout)
            self.assertEqual(result.returncode, 1)

    def test_dry_run_does_not_modify_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            had_conflict = create_conflict_same_line(tmpdir)
            if not had_conflict:
                self.skipTest("no conflict produced")

            before_count = get_conflicted_count(tmpdir)
            self._run_batch(tmpdir, "--dry-run")
            after_count = get_conflicted_count(tmpdir)
            self.assertEqual(before_count, after_count)

    def test_verbose_flag_accepted(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            had_conflict = create_conflict_same_line(tmpdir)
            if not had_conflict:
                self.skipTest("no conflict produced")

            result = self._run_batch(tmpdir, "--dry-run", "--verbose")
            self.assertIn("CONFLICT", result.stdout)

    def test_unsupported_file_skipped(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            had_conflict = _setup_shell_conflict(tmpdir)
            if not had_conflict:
                self.skipTest("no conflict produced")

            result = self._run_batch(tmpdir, "--dry-run")
            self.assertIn("unsupported", result.stdout)

    def test_mixed_resolvable_and_unresolvable(self):
        """Multiple conflicted files — some resolve, some don't."""
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            had_conflicts = _setup_two_file_conflict(tmpdir)
            if not had_conflicts:
                self.skipTest("no conflicts produced")

            result = self._run_batch(tmpdir, "--dry-run")
            self.assertIn("CONFLICT", result.stdout)
            self.assertIn("config.py", result.stdout)
            self.assertEqual(result.returncode, 1)

    def test_apply_on_unresolvable_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            had_conflict = create_conflict_same_line(tmpdir)
            if not had_conflict:
                self.skipTest("no conflict produced")

            result = self._run_batch(tmpdir, "--apply")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Unresolved:", result.stdout)

    def test_summary_line_format(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            create_repo(tmpdir)
            had_conflict = create_conflict_same_line(tmpdir)
            if not had_conflict:
                self.skipTest("no conflict produced")

            result = self._run_batch(tmpdir, "--dry-run")
            self.assertIn("Resolved:", result.stdout)
            self.assertIn("Unresolved:", result.stdout)
            self.assertIn("Unsupported:", result.stdout)
            self.assertIn("Total:", result.stdout)


class TestHelpers(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, SCRIPT_DIR)
        from git_utils import has_conflict_markers
        self._has_conflict_markers = has_conflict_markers

    def test_has_conflict_markers_true(self):
        self.assertTrue(self._has_conflict_markers("<<<<<<< HEAD\nfoo\n=======\nbar\n>>>>>>>"))

    def test_has_conflict_markers_false(self):
        self.assertFalse(self._has_conflict_markers("def foo():\n    pass\n"))


if __name__ == "__main__":
    unittest.main()
