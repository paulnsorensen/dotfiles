"""Exercise the real, standalone Bash behavior gate without model calls."""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
skill = root / "skills/bash-shortening"
with tempfile.TemporaryDirectory(prefix="bash-shortening-regression-") as tmp:
    workspace = Path(tmp)
    originals = workspace / "evals/files"
    candidates = workspace / "output/evals/files"
    shutil.copytree(skill / "evals/files", originals)
    shutil.copytree(originals, candidates)

    def grade():
        result = subprocess.run(
            [sys.executable, str(skill / "evals/gates/behavior.py")],
            cwd=workspace,
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
        )
        return json.loads(result.stdout), result.stderr

    unchanged, _ = grade()
    assert unchanged["score"] == 0, unchanged
    assert len(unchanged["failed"]) == len(list(originals.glob("*.sh"))), unchanged
    assert all(item.endswith(":unchanged") for item in unchanged["failed"]), unchanged
    for candidate in candidates.glob("*.sh"):
        candidate.write_text(
            candidate.read_text() + "\n# Behavior-preserving candidate.\n"
        )
    preserved, diagnostic = grade()
    assert preserved == {"score": 1, "failed": []}, (preserved, diagnostic)

    deploy = candidates / "deploy-url.sh"
    deploy.write_text(
        deploy.read_text().replace("unknown environment:", "WRONG ERROR:")
    )
    work = workspace / "work"
    work.mkdir()
    for script, message in (
        (originals / deploy.name, b"unknown environment: Prod\n"),
        (deploy, b"WRONG ERROR: Prod\n"),
    ):
        result = subprocess.run(
            ["bash", str(script), "Prod"], cwd=work, capture_output=True, check=False
        )
        assert (result.returncode, result.stdout, result.stderr) == (
            64,
            b"",
            message,
        ), result
        assert list(work.iterdir()) == [], "deploy changes the file tree"
    changed, diagnostic = grade()
    assert changed["score"] == 0 and changed["failed"], changed
    assert all(item.startswith("deploy-url.sh:run-") for item in changed["failed"]), (
        changed
    )
    assert "stderr: original" in diagnostic and "WRONG ERROR:" in diagnostic, diagnostic
    print(
        f"{len(list(originals.glob('*.sh')))} unchanged rejected; comment candidates accepted; changed stderr rejected"
    )
