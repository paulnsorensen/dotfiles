"""Shared helpers for the harness-climb unittest suites."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "skills" / "harness-climb" / "scripts"
CLI_PATH = SCRIPTS / "harness_climb.py"

sys.path.insert(0, str(SCRIPTS))

import hc_critic
import hc_db
import hc_denylist
import hc_field_gate
import hc_gate
import hc_git
import hc_ledger
import hc_policy
import hc_stats
import soak_check

_spec = importlib.util.spec_from_file_location("harness_climb_cli", CLI_PATH)
assert _spec and _spec.loader
cli = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cli)

HAVE_DUCKDB = shutil.which("duckdb") is not None
DAY = 86400
T0 = 1_800_000_000  # a fixed epoch for synthetic history

__all__ = [
    "DAY",
    "HAVE_DUCKDB",
    "ROOT",
    "T0",
    "cli",
    "hc_critic",
    "hc_db",
    "hc_denylist",
    "hc_field_gate",
    "hc_gate",
    "hc_git",
    "hc_ledger",
    "hc_policy",
    "hc_stats",
    "make_db",
    "soak_check",
]


def run_cli(
    *argv: str, cwd: Path | None = None, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CLI_PATH), *argv],
        capture_output=True,
        text=True,
        check=False,
        cwd=cwd,
        env={**os.environ, **(env or {})},
    )


class RepoCase(unittest.TestCase):
    """A temp git repo on `main`, with a temp state root."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.repo = self.dir / "repo"
        self.repo.mkdir()
        self.state = self.dir / "state"
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "T")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args: str, date: int | None = None) -> str:
        env = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
        }
        if date is not None:
            env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = f"{date} +0000"
        proc = subprocess.run(
            ["git", "-C", str(self.repo), *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        if proc.returncode != 0:
            raise AssertionError(f"git {args}: {proc.stderr}")
        return proc.stdout.strip()

    def commit(
        self, files: dict[str, str], message: str = "c", date: int | None = None
    ) -> str:
        for rel, text in files.items():
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            self.git("add", "--", rel)
        self.git("commit", "-q", "-m", message, date=date)
        return self.git("rev-parse", "HEAD")

    def write_json(self, name: str, data: Any) -> Path:
        path = self.dir / name
        path.write_text(json.dumps(data))
        return path

    def out(self, proc: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        self.assertTrue(proc.stdout.strip(), f"no stdout; stderr={proc.stderr}")
        return json.loads(proc.stdout)


def gate_json(
    thread: str = "t1", rnd: int = 1, component: str = "skill", **over: Any
) -> dict[str, Any]:
    gate = {
        "thread": thread,
        "round": rnd,
        "component": component,
        "targeted_query": "SELECT harness, sessionId, 1.0 AS value FROM sessions",
        "direction": "lower",
        "guard_composite_version": 1,
        "min_sessions": 4,
        "soak_days": 7,
        "sync_grace_days": 2,
        "token_per_gain": 1.0,
    }
    gate.update(over)
    return gate


def spread(mean: float, delta: float, n: int) -> list[float]:
    """Deterministic values with the given mean and a sample variance set by `delta`."""
    return [mean + delta * (1 if i % 2 else -1) for i in range(n)]


def make_rows(
    harness: str,
    start: float,
    n: int,
    version: str | None = "1.0",
    **metrics: list[float] | float | None,
) -> list[dict[str, Any]]:
    """`n` sessions an hour apart; each metric is a list (one per row) or a constant."""
    rows = []
    for i in range(n):
        row: dict[str, Any] = {
            "harness": harness,
            "session": f"{harness}-{start}-{i}",
            "start": start + i * 3600,
            "version": version,
        }
        for key in (
            "target",
            "tool_error_rate",
            "permission_denials",
            "stop_hook_blocks",
            "tokens_per_turn",
        ):
            val = metrics.get(key)
            row[key] = val[i] if isinstance(val, list) else val
        rows.append(row)
    return rows


def make_db(path: Path, *statements: str) -> Path:
    """A duckdb file built from SQL statements. Callers gate on HAVE_DUCKDB."""
    proc = subprocess.run(
        ["duckdb", "-init", os.devnull, str(path), "-c", ";\n".join(statements)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise AssertionError(f"duckdb: {proc.stderr}")
    return path


def call(*argv: str) -> tuple[int, dict[str, Any]]:
    """Run the CLI in-process and parse its JSON."""
    import contextlib
    import io

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = cli.main(list(argv))
    text = buf.getvalue().strip()
    return rc, (json.loads(text) if text else {})
