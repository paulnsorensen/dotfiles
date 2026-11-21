"""Contract tests for the offline architecture viewer."""

import importlib.util
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
VIEWER = ROOT / "skills/architecture-review/scripts/viewer.py"
spec = importlib.util.spec_from_file_location("architecture_viewer", VIEWER)
viewer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(viewer)


class ViewerTests(unittest.TestCase):
    def setUp(self):
        self.doc = {
            "schema": 1,
            "base": "a" * 40,
            "head": "b" * 40,
            "focus": "app",
            "groups": [
                {"id": "app", "label": "Application", "basis": "manifest", "changed": True},
                {"id": "core", "label": "Core", "basis": "source layout", "changed": False},
            ],
            "snapshots": {
                "head": {
                    "revision": "b" * 40,
                    "nodes": [{"id": "app/main.py::start", "label": "start", "kind": "function", "path": "app/main.py", "group": "app", "language": "python", "line": 1, "end": 2, "blob": "c" * 40, "public": True}],
                    "edges": [{"id": "e1", "source": "app/main.py::start", "target": "app/main.py::run", "kind": "call", "line": 2, "path": "app/main.py", "blob": "c" * 40, "sites": [2]}],
                    "unknowns": [{"path": "app/main.py", "line": 3, "reason": "dynamic dispatch"}],
                    "files": {"app/main.py": {"blob": "c" * 40, "text": "def start():\n    run()\n"}},
                    "coverage": {},
                },
                "base": {"revision": "a" * 40, "nodes": [], "edges": [], "unknowns": [], "files": {}, "coverage": {}},
            },
            "changes": {"nodes": {"app/main.py::start": "added"}, "edges": {"e1": "added"}},
        }

    def test_render_is_standalone_and_executable(self):
        html = viewer.render(self.doc)
        self.assertIn("<svg", html)
        self.assertIn('id="architecture-data"', html)
        self.assertIn('id="architecture-app"', html)
        self.assertIn("Content-Security-Policy", html)
        self.assertNotIn("<script src=", html)
        self.assertNotIn("<link", html)
        self.assertIn("aria-label=\"Search groups and entities\"", html)
        self.assertIn("Back", html)
        self.assertIn("Compare revisions", html)
        self.assertIn("Change", html)
        self.assertIn("Source", html)
        self.assertIn("viewer.js", html)

    def test_untrusted_data_cannot_break_script_or_markup(self):
        self.doc["groups"][0]["label"] = '</script><img src=x onerror=alert(1)>'
        self.doc["snapshots"]["head"]["files"]["app/main.py"]["text"] = '<script>alert(1)</script>'
        html = viewer.render(self.doc)
        self.assertNotIn('</script><img', html)
        self.assertNotIn('<script>alert(1)</script>', html)
        payload = re.search(r'<script id="architecture-data" type="application/json">(.*?)</script>', html, re.S).group(1)
        self.assertEqual(json.loads(payload), self.doc)

    def test_schema_guard(self):
        self.doc["schema"] = 2
        with self.assertRaises(ValueError):
            viewer.render(self.doc)


if __name__ == "__main__":
    unittest.main()
