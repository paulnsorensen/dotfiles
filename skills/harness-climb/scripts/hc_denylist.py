"""The leakage denylist: user prompts and project names from the session database."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

import hc_policy
import hc_stats
from hc_db import IN_SCOPE, duck, resolve_db

# Codex injects these as user messages; they are harness text, not prompts.
CODEX_INJECTED = ("<", "# AGENTS.md instructions")


def flatten_content(raw: Any) -> str:
    """Prompt text from message content: a string, or the text blocks of an array."""
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        return "\n".join(
            block["text"]
            for block in raw
            if isinstance(block, dict)
            and block.get("type") in ("text", "input_text")
            and isinstance(block.get("text"), str)
        )
    return ""


def codex_sessions_root() -> Path:
    home = os.environ.get("CODEX_HOME") or "~/.codex"
    return Path(os.path.abspath(os.path.expanduser(home))) / "sessions"


def _rollout_prompt(line: str) -> str | None:
    """The user prompt in one rollout line, or None for any other line."""
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    payload = entry.get("payload") if isinstance(entry, dict) else None
    if (
        entry.get("type") != "response_item"
        or not isinstance(payload, dict)
        or payload.get("type") != "message"
        or payload.get("role") != "user"
    ):
        return None
    text = flatten_content(payload.get("content"))
    if text.strip() and not text.lstrip().startswith(CODEX_INJECTED):
        return text
    return None


def codex_prompts(root: Path) -> list[str]:
    """User prompt text from Codex rollouts, read-only. Unreadable lines are skipped."""
    prompts: list[str] = []
    if not root.is_dir():
        return prompts
    for path in sorted(root.rglob("*.jsonl")):
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            continue
        prompts += [text for text in map(_rollout_prompt, lines) if text is not None]
    return prompts


def _db_prompts(db: Path) -> dict[str, list[str]]:
    """User prompt text per harness. Codex falls back to its rollout files."""
    rows = duck(
        db,
        "SELECT harness, CAST(json_extract(message, '$.content') AS VARCHAR) AS c "
        f"FROM raw_entries WHERE {IN_SCOPE} AND type = 'user' AND message IS NOT NULL",
    )
    by_harness: dict[str, list[str]] = {name: [] for name in hc_stats.HARNESSES}
    for row in rows:
        try:
            text = flatten_content(json.loads(row["c"]) if row["c"] else None)
        except ValueError:
            continue
        if text:
            by_harness.setdefault(row["harness"], []).append(text)
    if not by_harness.get("codex"):
        by_harness["codex"] = codex_prompts(codex_sessions_root())
    return by_harness


def load_denylist(
    args: argparse.Namespace, repo: Path, notes: list[dict[str, Any]] | None = None
) -> dict[str, set[str]] | None:
    """The leakage denylist. A harness with no prompts adds a `denylist-partial` note."""
    own = [repo.name, "dotfiles"]
    if args.denylist:
        data = json.loads(Path(args.denylist).read_text())
        return hc_policy.build_denylist(
            data.get("prompts", []), data.get("projects", []), own
        )
    db = resolve_db()
    if not db.is_file():
        return None
    by_harness = _db_prompts(db)
    if notes is not None:
        notes += [
            {"check": "leakage", "category": "denylist-partial", "harness": name}
            for name, texts in sorted(by_harness.items())
            if not texts
        ]
    projects = duck(db, f"SELECT DISTINCT project FROM sessions WHERE {IN_SCOPE}")
    return hc_policy.build_denylist(
        [t for texts in by_harness.values() for t in texts],
        [r["project"] for r in projects],
        own,
    )
