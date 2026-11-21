"""Exercise the packaged entrypoint against committed repositories."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CLI = Path(__file__).resolve().parents[2] / "skills/architecture-review/scripts/review.py"


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def repository(root: Path, name: str) -> tuple[Path, str, str]:
    repo = root / name
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "user.email", "test@example.org")
    source = repo / "app.py"
    source.write_text("def run():\n    return 1\n", encoding="utf-8")
    git(repo, "add", "app.py")
    git(repo, "commit", "-qm", "base")
    base = git(repo, "rev-parse", "HEAD")
    source.write_text("def run():\n    return 2\n", encoding="utf-8")
    git(repo, "commit", "-qam", "head")
    return repo, base, git(repo, "rev-parse", "HEAD")


def run(*args: object, cli: Path = CLI, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(cli), *(str(arg) for arg in args)],
                          text=True, capture_output=True, check=False, env=env)


class CliTests(unittest.TestCase):
    def test_cold_repeat_and_second_repository(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, base, head = repository(root, "one")
            out = root / "review-one"
            cache = root / "cache"
            args = (repo, "--base", base, "--head", head, "--out", out, "--cache", cache)
            first = run(*args)
            self.assertEqual(first.returncode, 0, first.stderr)
            summary = json.loads(first.stdout)
            self.assertEqual(summary["head"], head)
            self.assertEqual(summary["base"], base)
            self.assertTrue(Path(summary["viewer"]).is_file())
            self.assertIn("Architecture review", Path(summary["viewer"]).read_text())
            self.assertEqual(summary["worker_status"], "unavailable")
            self.assertEqual(summary["tasks"], [])
            repeat = run(*args)
            self.assertEqual(repeat.returncode, 0, repeat.stderr)
            self.assertEqual(json.loads(repeat.stdout)["head"], head)
            other, _, other_head = repository(root, "two")
            copied_skill = root / "copied-architecture-review"
            shutil.copytree(CLI.parents[1], copied_skill)
            bytecode_before = set(copied_skill.rglob("*.pyc"))
            second = run(other, "--out", root / "review-two", "--cache", cache,
                         cli=copied_skill / "scripts/review.py")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(json.loads(second.stdout)["head"], other_head)
            self.assertEqual(set(copied_skill.rglob("*.pyc")), bytecode_before)

    def test_tasks_are_durable_and_replies_use_original_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, base, head = repository(root, "source")
            out, cache = root / "review", root / "cache"
            args = (repo, "--base", base, "--head", head, "--model", "available-test-model",
                    "--out", out, "--cache", cache)
            first = run(*args)
            self.assertEqual(first.returncode, 0, first.stderr)
            summary = json.loads(first.stdout)
            self.assertEqual(summary["worker_status"], "pending")
            self.assertEqual(len(summary["tasks"]), 2)
            tasks = [json.loads(Path(path).read_text()) for path in summary["tasks"]]
            self.assertEqual(json.loads((out / "tasks.json").read_text()), summary["tasks"])
            replies = [{"schema": task["schema"], "id": task["id"],
                        "focus": task["focus"], "revision": task["revision"],
                        "claims": [], "unknowns": ["Evidence is insufficient"]} for task in tasks]
            reply_path = root / "replies.json"
            reply_path.write_text(json.dumps(replies), encoding="utf-8")
            ingested = run(*args, "--replies", reply_path)
            self.assertEqual(ingested.returncode, 0, ingested.stderr)
            self.assertEqual(json.loads(ingested.stdout)["tasks"], [])
            self.assertEqual(json.loads((out / "tasks.json").read_text()), summary["tasks"])
            warm = run(*args)
            self.assertEqual(warm.returncode, 0, warm.stderr)
            self.assertEqual(json.loads(warm.stdout)["worker_status"], "cached")
            self.assertEqual(json.loads(warm.stdout)["tasks"], [])

    def test_default_cache_reuses_assessments_and_respects_xdg(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, base, head = repository(root, "source")
            cache_home = root / "xdg"
            env = {**os.environ, "XDG_CACHE_HOME": str(cache_home)}
            args = (repo, "--base", base, "--head", head, "--model", "test-model")
            first = run(*args, env=env)
            self.assertEqual(first.returncode, 0, first.stderr)
            summary = json.loads(first.stdout)
            self.assertEqual(summary["worker_status"], "pending")
            self.assertEqual(len(summary["tasks"]), 2)
            cache_dirs = list((cache_home / "architecture-review").iterdir())
            self.assertEqual(len(cache_dirs), 1)
            self.assertEqual(cache_dirs[0].stat().st_mode & 0o077, 0)
            tasks = [json.loads(Path(path).read_text()) for path in summary["tasks"]]
            replies = [{"schema": task["schema"], "id": task["id"],
                        "focus": task["focus"], "revision": task["revision"],
                        "claims": [], "unknowns": ["Evidence is insufficient"]} for task in tasks]
            reply_path = root / "replies.json"
            reply_path.write_text(json.dumps(replies), encoding="utf-8")
            ingested = run(*args, "--replies", reply_path, env=env)
            self.assertEqual(ingested.returncode, 0, ingested.stderr)
            repeat = run(*args, env=env)
            self.assertEqual(repeat.returncode, 0, repeat.stderr)
            self.assertEqual(json.loads(repeat.stdout)["worker_status"], "cached")
            self.assertEqual(json.loads(repeat.stdout)["tasks"], [])

    def test_secure_existing_directories_and_no_change_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, _, head = repository(root, "source")
            out, cache = root / "review", root / "cache"
            out.mkdir(mode=0o700)
            cache.mkdir(mode=0o700)
            result = run(repo, "--base", head, "--head", head, "--model", "test-model",
                         "--out", out, "--cache", cache)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["worker_status"], "no-change")
            self.assertEqual(json.loads(result.stdout)["tasks"], [])
            self.assertEqual(out.stat().st_mode & 0o777, 0o700)
            self.assertEqual(cache.stat().st_mode & 0o777, 0o700)

    def test_rejects_public_cache_and_invalid_ref_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, _, _ = repository(root, "source")
            cache = root / "public"
            cache.mkdir(mode=0o755)
            result = run(repo, "--cache", cache)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("Traceback", result.stderr)
            self.assertEqual(cache.stat().st_mode & 0o777, 0o755)
            result = run(repo, "--rev", "missing-ref", "--cache", root / "private")
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("Traceback", result.stderr)
            env = {**os.environ, "XDG_CACHE_HOME": "relative-cache"}
            result = run(repo, env=env)
            self.assertEqual(result.returncode, 2)
            self.assertIn("XDG_CACHE_HOME", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_rejects_bad_input_and_unmanaged_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, base, head = repository(root, "source")
            bad = run(repo, "--base", base, "--out", root / "out")
            self.assertNotEqual(bad.returncode, 0)
            unmanaged = root / "out"
            unmanaged.mkdir()
            (unmanaged / "index.html").write_text("keep", encoding="utf-8")
            result = run(repo, "--base", base, "--head", head, "--out", unmanaged)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((unmanaged / "index.html").read_text(), "keep")
            link = root / "link"
            link.symlink_to(unmanaged, target_is_directory=True)
            result = run(repo, "--out", link)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
