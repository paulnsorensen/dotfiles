import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "architecture_analysis", ROOT / "skills/architecture-review/scripts/analysis.py"
)


def load():
    module = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(module)
    return module


def document(head="a" * 40, blob="b" * 40):
    node = {
        "id": "src/api.py::run", "label": "run", "kind": "function",
        "path": "src/api.py", "group": "api", "language": "python",
        "line": 1, "end": 3, "blob": blob, "public": True,
    }
    caller = {
        "id": "src/cli.py::main", "label": "main", "kind": "function",
        "path": "src/cli.py", "group": "api", "language": "python",
        "line": 1, "end": 2, "blob": "c" * 40, "public": False,
    }
    edge = {
        "id": "src/cli.py::main->src/api.py::run", "source": caller["id"],
        "target": node["id"], "kind": "call", "path": "src/cli.py",
        "line": 2, "blob": "c" * 40, "sites": [2],
    }
    return {
        "base": None, "head": head, "focus": "api",
        "groups": [{"id": "api", "label": "API", "basis": "manifest", "changed": True}],
        "snapshots": {"head": {
            "revision": head, "nodes": [node, caller], "edges": [edge],
            "unknowns": [], "files": {
                "src/api.py": {"blob": blob, "text": "def run(x):\n    return x\n"},
                "src/cli.py": {"blob": "c" * 40, "text": "from api import run\nrun(1)\n"},
            }, "coverage": {},
        }},
        "changes": {"nodes": {node["id"]: "added"}, "edges": {edge["id"]: "added"}},
    }


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name)
        self.analysis = load()

    def tearDown(self):
        self.tmp.cleanup()

    def reply(self, task, claim="Callers pass x"):
        return {
            "schema": task["schema"], "id": task["id"],
            "focus": task["focus"], "revision": task["revision"],
            "claims": [{
                "kind": "interface", "claim": claim,
                "reasoning": "The caller passes a value.",
                "evidence_ids": [task["evidence"][0]["id"]],
            }],
            "unknowns": [],
        }

    def test_prepare_limits_questions_and_evidence(self):
        tasks, annotations = self.analysis.prepare(document(), "small", self.cache)
        self.assertEqual(len(tasks), 2)
        self.assertEqual(annotations["claims"], [])
        self.assertTrue(all(len(task["evidence"]) <= 12 for task in tasks))
        self.assertEqual({task["question"] for task in tasks}, {
            "What must callers know about the public interface, and what does the implementation hide?",
            "What changed at this boundary, and what possible impact follows from cited caller evidence?",
        })
        self.assertTrue(all(task["budget"]["timeout_seconds"] == 120 for task in tasks))

    def test_rejects_stale_foreign_and_expired_replies(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        foreign = self.reply(tasks[0])
        foreign["claims"][0]["evidence_ids"] = ["not-offered"]
        self.assertEqual(self.analysis.accept(doc, "small", self.cache, [foreign])["claims"], [])
        stale = copy.deepcopy(doc)
        stale["snapshots"]["head"]["files"]["src/api.py"]["text"] = "different\n"
        self.assertEqual(self.analysis.accept(stale, "small", self.cache, [self.reply(tasks[0])])["claims"], [])
        with patch.object(self.analysis.time, "time", return_value=tasks[1]["expires_at"] + 1):
            self.assertEqual(
                self.analysis.accept(doc, "small", self.cache, [self.reply(tasks[1])])["claims"], []
            )

    def test_cache_reuses_unchanged_scope_across_head_revision(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        result = self.analysis.accept(doc, "small", self.cache, [self.reply(task) for task in tasks])
        self.assertEqual(len(result["claims"]), 1)
        moved = document(head="d" * 40)
        tasks, annotations = self.analysis.prepare(moved, "small", self.cache)
        self.assertEqual(tasks, [])
        self.assertEqual(len(annotations["claims"]), 1)

    def test_distinct_claims_are_possible_differences(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        replies = [self.reply(tasks[0], "Callers must pass x"), self.reply(tasks[1], "Callers need no arguments")]
        out = self.analysis.accept(doc, "small", self.cache, replies)
        self.assertEqual(len(out["claims"]), 2)
        self.assertEqual(out["conflicts"][0]["status"], "possible_difference")
        self.assertNotIn("edges", out)

    def test_complementary_claims_do_not_create_differences(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        replies = [self.reply(tasks[0], "Callers pass x"), self.reply(tasks[1], "The implementation returns x")]
        out = self.analysis.accept(doc, "small", self.cache, replies)
        self.assertEqual(out["conflicts"], [])

    def test_citations_resolve_to_current_source(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        out = self.analysis.accept(doc, "small", self.cache, [self.reply(tasks[0])])
        cited = out["claims"][0]["evidence_ids"][0]
        self.assertEqual(out["citations"][cited], {
            key: value for key, value in tasks[0]["evidence"][0].items() if key != "id"
        })
        moved = document(head="d" * 40)
        _, reused = self.analysis.prepare(moved, "small", self.cache)
        self.assertEqual(reused["citations"][cited], out["citations"][cited])

    def test_rejects_reply_for_different_revision_with_same_scope(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        moved = document(head="d" * 40)
        out = self.analysis.accept(moved, "small", self.cache, [self.reply(tasks[0])])
        self.assertEqual(out["claims"], [])

    def test_bad_payload_is_not_cached(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        too_many = self.reply(tasks[0])
        too_many["claims"] *= 13
        self.assertEqual(self.analysis.accept(doc, "small", self.cache, [too_many])["claims"], [])
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        self.assertEqual(len(tasks), 2)

    def test_scope_change_and_model_change_invalidate_cache(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        self.analysis.accept(doc, "small", self.cache, [self.reply(task) for task in tasks])
        changed = document(blob="e" * 40)
        changed["snapshots"]["head"]["files"]["src/api.py"]["blob"] = "e" * 40
        self.assertEqual(len(self.analysis.prepare(changed, "small", self.cache)[0]), 2)
        self.assertEqual(len(self.analysis.prepare(doc, "other-model", self.cache)[0]), 2)

    def test_rejects_oversize_and_unoffered_revision(self):
        doc = document()
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        oversized = self.reply(tasks[0])
        oversized["unknowns"] = ["x" * 16000]
        wrong_revision = self.reply(tasks[1])
        wrong_revision["revision"] = {"base": None, "head": "f" * 40}
        result = self.analysis.accept(doc, "small", self.cache, [oversized, wrong_revision])
        self.assertEqual(result["claims"], [])

    def test_caller_evidence_survives_large_interface(self):
        doc = document()
        original = doc["snapshots"]["head"]["nodes"][0]
        for index in range(20):
            node = dict(original, id=f"src/api.py::f{index}", label=f"f{index}")
            doc["snapshots"]["head"]["nodes"].append(node)
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        self.assertTrue(any(item["type"] == "edge" for item in tasks[0]["evidence"]))
        self.assertLessEqual(len(tasks[0]["evidence"]), 12)

    def test_changed_public_pair_survives_sorted_prefix(self):
        doc = document()
        head = doc["snapshots"]["head"]
        old = copy.deepcopy(head)
        old["revision"] = "f" * 40
        old["nodes"][0]["blob"] = "e" * 40
        old["files"]["src/api.py"] = {"blob": "e" * 40, "text": "def run(x):\n    return None\n"}
        doc["base"] = old["revision"]
        doc["snapshots"]["base"] = old
        doc["changes"]["nodes"]["src/api.py::run"] = "changed"
        for index in range(30):
            node = dict(head["nodes"][0], id=f"aaa/f{index}.py::f", path=f"aaa/f{index}.py", public=False)
            head["nodes"].append(node)
            old["nodes"].append(dict(node))
            source = {"blob": node["blob"], "text": "def f():\n    pass\n"}
            head["files"][node["path"]] = source
            old["files"][node["path"]] = source
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        evidence = tasks[0]["evidence"]
        pair = [item for item in evidence if item["entity"] == "src/api.py::run"]
        self.assertEqual({item["side"] for item in pair}, {"base", "head"})
        self.assertTrue(all(item["status"] == "changed" for item in pair))
        self.assertTrue(any(item["type"] == "edge" for item in evidence))
        self.assertTrue(all(item["text"] for item in evidence))

    def test_changed_interface_does_not_crowd_out_caller(self):
        doc = document()
        head = doc["snapshots"]["head"]
        original = head["nodes"][0]
        for index in range(20):
            node = dict(original, id=f"aaa/f{index}.py::f", path=f"aaa/f{index}.py")
            head["nodes"].append(node)
            head["files"][node["path"]] = {"blob": node["blob"], "text": "def f():\n    pass\n"}
            doc["changes"]["nodes"][node["id"]] = "added"
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        self.assertTrue(any(item["type"] == "edge" for item in tasks[0]["evidence"]))

    def test_empty_or_mismatched_source_is_not_offered(self):
        doc = document()
        doc["snapshots"]["head"]["files"]["src/api.py"]["text"] = ""
        doc["snapshots"]["head"]["files"]["src/cli.py"]["blob"] = "f" * 40
        tasks, _ = self.analysis.prepare(doc, "small", self.cache)
        self.assertEqual(tasks[0]["evidence"], [])


if __name__ == "__main__":
    unittest.main()
