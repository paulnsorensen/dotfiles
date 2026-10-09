"""The leakage denylist: user prompts and project names from the session database."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

import hc_policy
import hc_stats
from hc_db import IN_SCOPE, duck, resolve_db

# Text that starts with one of these is harness text, not a user prompt.
INJECTED_PREFIXES = (
    "<",  # an XML-style tag: a system reminder, a command wrapper, or Codex context
    "# AGENTS.md instructions",  # the Codex project-instructions preamble
    "Base directory for this skill",  # a skill body that a harness loads
)
_CACHE_VERSION = 1
_TEXT_TYPES = ("text", "input_text")


def is_injected(text: str) -> bool:
    """True when a text block is harness text: a tag, a skill body, or a Codex preamble."""
    return text.lstrip().startswith(INJECTED_PREFIXES)


def text_blocks(raw: Any) -> list[str]:
    """The text of message content: one item for a string, one per text block of an array."""
    if isinstance(raw, str):
        return [raw]
    if isinstance(raw, list):
        return [
            block["text"]
            for block in raw
            if isinstance(block, dict)
            and block.get("type") in _TEXT_TYPES
            and isinstance(block.get("text"), str)
        ]
    return []


def prompt_blocks(raw: Any) -> list[str]:
    """The text blocks of message content that a user wrote."""
    return [b for b in text_blocks(raw) if b.strip() and not is_injected(b)]


def codex_sessions_root() -> Path:
    home = os.environ.get("CODEX_HOME") or "~/.codex"
    return Path(os.path.abspath(os.path.expanduser(home))) / "sessions"


def _rollout_prompt(line: str) -> str | None:
    """The user prompt in one rollout line, or None for any other line."""
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    if not isinstance(entry, dict):
        return None
    payload = entry.get("payload")
    if (
        entry.get("type") != "response_item"
        or not isinstance(payload, dict)
        or payload.get("type") != "message"
        or payload.get("role") != "user"
    ):
        return None
    blocks = prompt_blocks(payload.get("content"))
    return "\n".join(blocks) if blocks else None


def codex_prompts(root: Path) -> list[str]:
    """User prompt text from Codex rollouts, read-only. The reader skips unreadable lines."""
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


def prompt_query() -> str:
    """SQL for user prompt text blocks: text only, harness-injected blocks dropped.

    The query unnests array content and keeps `text` and `input_text` blocks,
    so tool results never leave the database.
    """
    types = ", ".join(f"'{t}'" for t in _TEXT_TYPES)
    starts = " OR ".join(
        f"starts_with(ltrim(t, E' \\t\\r\\n'), '{p}')" for p in INJECTED_PREFIXES
    )
    # Ingest writes no Codex prompt rows, so the scan reads Claude rows only.
    where = f"{IN_SCOPE} AND type = 'user' AND harness = 'claude'"
    content = "json_extract(message, '$.content')"
    return (
        "SELECT harness, t FROM ("
        f" SELECT harness, json_extract_string(message, '$.content') AS t"
        f" FROM raw_entries WHERE {where} AND json_type({content}) = 'VARCHAR'"
        " UNION ALL"
        " SELECT harness, json_extract_string(b, '$.text') AS t FROM ("
        f" SELECT harness, unnest(from_json({content}, '[\"JSON\"]')) AS b"
        f" FROM raw_entries WHERE {where} AND json_type({content}) = 'ARRAY')"
        f" WHERE json_extract_string(b, '$.type') IN ({types}))"
        f" WHERE t IS NOT NULL AND trim(t) <> '' AND NOT ({starts})"
    )


def _db_prompts(db: Path) -> dict[str, list[str]]:
    """User prompt text per harness. Codex falls back to its rollout files."""
    by_harness: dict[str, list[str]] = {name: [] for name in hc_stats.HARNESSES}
    for row in duck(db, prompt_query()):
        by_harness.setdefault(row["harness"], []).append(row["t"])
    if not by_harness.get("codex"):
        by_harness["codex"] = codex_prompts(codex_sessions_root())
    return by_harness


def _mtime(path: Path) -> int | None:
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return None


def _cache_file(db: Path, own: list[str]) -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or "~/.cache"
    ident = json.dumps([str(db), own, str(codex_sessions_root())])
    name = hashlib.sha256(ident.encode()).hexdigest()[:16]
    return Path(os.path.expanduser(base)) / "harness-climb" / f"denylist-{name}.json"


def _rollout_stamp(root: Path) -> tuple[int, int]:
    """The newest mtime and the count of the rollout files. Stat only: no file is read."""
    newest, count = 0, 0
    if root.is_dir():
        for path in root.rglob("*.jsonl"):
            stamp = _mtime(path)
            if stamp is not None:
                newest, count = max(newest, stamp), count + 1
    return newest, count


def _cache_key(db: Path) -> list[int | None]:
    return [_CACHE_VERSION, _mtime(db), *_rollout_stamp(codex_sessions_root())]


def _read_cache(
    file: Path, key: list[int | None]
) -> tuple[dict[str, set[str]], list[dict[str, Any]]] | None:
    try:
        data = json.loads(file.read_text())
        if data["key"] != key:
            return None
        return {k: set(v) for k, v in data["deny"].items()}, data["notes"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def _write_cache(
    file: Path,
    key: list[int | None],
    deny: dict[str, set[str]],
    notes: list[dict[str, Any]],
) -> None:
    """Store the denylist for the next critic run. The file holds prompt n-grams: owner-only."""
    payload = {"key": key, "deny": {k: sorted(v) for k, v in deny.items()}}
    payload["notes"] = notes
    try:
        file.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(payload, handle)
    except OSError:
        pass


def load_denylist(
    denylist_file: str | None, repo: Path
) -> tuple[dict[str, set[str]] | None, list[dict[str, Any]]]:
    """The leakage denylist and its notes.

    A harness with no prompts adds a `denylist-partial` note. The denylist is
    None when no source exists. The database build is cached by the mtime of
    the database and by the newest mtime and count of the Codex rollout files.
    """
    own = [repo.name, "dotfiles"]
    if denylist_file:
        data = json.loads(Path(denylist_file).read_text())
        deny = hc_policy.build_denylist(
            data.get("prompts", []), data.get("projects", []), own
        )
        return deny, []
    db = resolve_db()
    if not db.is_file():
        return None, []
    cache, key = _cache_file(db, own), _cache_key(db)
    cached = _read_cache(cache, key)
    if cached is not None:
        return cached
    by_harness = _db_prompts(db)
    notes = [
        {"check": "leakage", "category": "denylist-partial", "harness": name}
        for name, texts in sorted(by_harness.items())
        if not texts
    ]
    projects = duck(db, f"SELECT DISTINCT project FROM sessions WHERE {IN_SCOPE}")
    deny = hc_policy.build_denylist(
        [t for texts in by_harness.values() for t in texts],
        [r["project"] for r in projects],
        own,
    )
    _write_cache(cache, key, deny, notes)
    return deny, notes
