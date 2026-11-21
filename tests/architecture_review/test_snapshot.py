"""Revision evidence tests use committed trees, not the checkout."""

from __future__ import annotations

import importlib
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "skills/architecture-review/scripts"))
build = importlib.import_module("evidence").build


class SnapshotTests(unittest.TestCase):
    def __init__(self, methodName: str = "runTest") -> None:
        super().__init__(methodName)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.cache = Path(self.temp.name) / "cache"

    def setUp(self) -> None:
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")

    def git(self, *args: str) -> str:
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def commit(self, files: dict[str, str]) -> str:
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_semantic_edges_survive_line_move_and_source_is_historic(self) -> None:
        base = self.commit({"pkg/a.py": "from pkg.b import target\n\ndef use():\n    return target()\n",
                            "pkg/b.py": "def target():\n    return 1\n"})
        head = self.commit({"pkg/a.py": "\n\nfrom pkg.b import target\n\ndef use():\n    return target()\n",
                            "pkg/b.py": "def target():\n    return 2\n"})
        (self.repo / "pkg/a.py").write_text("def dirty():\n    pass\n")
        result = build(self.repo, base, head, self.cache)
        self.assertEqual(result["base"], base)
        self.assertEqual(result["head"], head)
        self.assertEqual(result["snapshots"]["base"]["files"]["pkg/b.py"]["text"], "def target():\n    return 1\n")
        self.assertEqual(result["snapshots"]["head"]["files"]["pkg/b.py"]["text"], "def target():\n    return 2\n")
        self.assertEqual(result["changes"]["edges"], {})
        self.assertEqual(result["changes"]["nodes"]["pkg/b.py::target"], "modified")
        self.assertTrue(any(edge["target"] == "pkg/b.py::target" for edge in result["snapshots"]["head"]["edges"]))
        self.assertNotIn("pkg/a.py::dirty", {node["id"] for node in result["snapshots"]["head"]["nodes"]})

    def test_parse_gap_does_not_claim_removed_edge(self) -> None:
        base = self.commit({"a.py": "from b import target\ntarget()\n", "b.py": "def target():\n    pass\n"})
        head = self.commit({"a.py": "def broken(:\n", "b.py": "def target():\n    pass\n"})
        result = build(self.repo, base, head, self.cache)
        self.assertFalse(any(change == "removed" for change in result["changes"]["edges"].values()))
        self.assertTrue(any(item["path"] == "a.py" for item in result["snapshots"]["head"]["unknowns"]))
        self.assertEqual(result, build(self.repo, base, head, self.cache))


    def test_failed_target_parse_does_not_remove_edge(self) -> None:
        base = self.commit({"a.py": "from b import target\ntarget()\n", "b.py": "def target():\n    pass\n"})
        head = self.commit({"a.py": "from b import target\ntarget()\n", "b.py": "def broken(:\n"})
        result = build(self.repo, base, head, self.cache)
        self.assertEqual(result["changes"]["edges"], {})
        self.assertTrue(any(item["path"] == "b.py" and item["reason"].startswith("parse failed")
                            for item in result["snapshots"]["head"]["unknowns"]))

    def test_valid_target_deletion_removes_edge(self) -> None:
        base = self.commit({"a.py": "from b import target\ntarget()\n", "b.py": "def target():\n    pass\n"})
        head = self.commit({"a.py": "from b import target\ntarget()\n", "b.py": "def other():\n    pass\n"})
        result = build(self.repo, base, head, self.cache)
        self.assertIn("removed", result["changes"]["edges"].values())

    def test_repeated_definition_is_ambiguous(self) -> None:
        revision = self.commit({"a.py": "def target():\n    pass\ndef target():\n    pass\ntarget()\n"})
        result = build(self.repo, None, revision, self.cache)
        current = result["snapshots"]["head"]
        self.assertFalse(current["edges"])
        self.assertTrue(any(item["reason"] == "ambiguous target" for item in current["unknowns"]))

    def test_repeated_source_is_ambiguous(self) -> None:
        revision = self.commit({"a.py": "def target():\n    pass\ndef use():\n    target()\ndef use():\n    target()\n"})
        current = build(self.repo, None, revision, self.cache)["snapshots"]["head"]
        self.assertFalse(current["edges"])
        self.assertTrue(any(item["reason"] == "ambiguous source" for item in current["unknowns"]))

    def test_file_only_group_changes_and_fixture_does_not_win_focus(self) -> None:
        base = self.commit({"prod/a.py": "def run():\n    return 1\n",
                            "docs/readme.md": "old\n",
                            "tests/test_a.py": "def one():\n    return 1\ndef two():\n    return 1\n"})
        head = self.commit({"prod/a.py": "def run():\n    return 2\n",
                            "docs/readme.md": "new\n",
                            "tests/test_a.py": "def one():\n    return 2\ndef two():\n    return 2\n"})
        result = build(self.repo, base, head, self.cache)
        self.assertEqual(result["focus"], "prod")
        self.assertEqual({group["id"] for group in result["groups"] if group["changed"]},
                         {"prod", "docs", "tests"})
        adapters = result["snapshots"]["head"]["coverage"]["adapters"]
        self.assertIn("version", adapters["supported"][".py"])
        self.assertIn("extensions", adapters["unsupported"])

    def test_invalid_utf8_source_does_not_crash(self) -> None:
        path = self.repo / "a.py"
        path.write_bytes(b"def run():\n    return '\\xff'\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        result = build(self.repo, None, self.git("rev-parse", "HEAD"), self.cache)
        self.assertEqual(result["snapshots"]["head"]["coverage"]["files"], 1)

    def test_large_target_does_not_remove_edge(self) -> None:
        base = self.commit({"a.py": "from b import target\ntarget()\n", "b.py": "def target():\n    pass\n"})
        head = self.commit({"a.py": "from b import target\ntarget()\n", "b.py": "#" * 1_000_001})
        result = build(self.repo, base, head, self.cache)
        self.assertEqual(result["changes"]["edges"], {})
        self.assertTrue(any(item["path"] == "b.py" and item["reason"] == "large file skipped"
                            for item in result["snapshots"]["head"]["unknowns"]))

    def test_corrupt_cache_recovers_with_private_atomic_file(self) -> None:
        revision = self.commit({"a.py": "def run():\n    pass\n"})
        expected = build(self.repo, None, revision, self.cache)
        cached = next(self.cache.iterdir())
        self.assertEqual(stat.S_IMODE(cached.stat().st_mode), 0o600)
        cached.write_text("{broken")
        self.assertEqual(build(self.repo, None, revision, self.cache), expected)
        self.assertEqual(stat.S_IMODE(cached.stat().st_mode), 0o600)

    def test_transient_parser_failure_is_not_cached(self) -> None:
        revision = self.commit({"a.py": "def run():\n    pass\n"})
        adapter = importlib.import_module("evidence.python_adapter")
        with patch.object(adapter, "extract", side_effect=subprocess.TimeoutExpired("parser", 1)):
            failed = build(self.repo, None, revision, self.cache)
        self.assertTrue(any(item["reason"] == "parse failed: TimeoutExpired"
                            for item in failed["snapshots"]["head"]["unknowns"]))
        self.assertEqual(list(self.cache.glob("*.json")), [])
        recovered = build(self.repo, None, revision, self.cache)
        self.assertTrue(any(node["id"] == "a.py::run" for node in recovered["snapshots"]["head"]["nodes"]))

    def test_repeated_sites_and_inventory_limits(self) -> None:
        revision = self.commit({"package.json": "{}\n", "src/a.py": "def target():\n    pass\n\ntarget()\ntarget()\n", "notes.txt": "not source\n"})
        (self.repo / "link.py").symlink_to("src/a.py")
        self.git("add", "link.py")
        self.git("commit", "-qm", "symlink")
        head = self.git("rev-parse", "HEAD")
        result = build(self.repo, revision, head, self.cache)
        edges = [edge for edge in result["snapshots"]["head"]["edges"] if edge["kind"] == "call"]
        self.assertEqual(len(edges), 1)
        self.assertEqual(edges[0]["sites"], [4, 5])
        self.assertTrue(any(item["path"] == "link.py" for item in result["snapshots"]["head"]["unknowns"]))
        self.assertTrue(any(item["path"] == "notes.txt" for item in result["snapshots"]["head"]["unknowns"]))
        self.assertEqual(result["groups"][0]["basis"], "manifest: package.json")
        self.assertNotIn("text", result["snapshots"]["head"]["files"]["link.py"])


if __name__ == "__main__":
    unittest.main()
