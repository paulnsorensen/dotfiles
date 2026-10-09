"""Git, gate-file, and sync-history helpers for harness-climb."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

GATE_DIR = "harness-climb/gates"
SYNC_LINE = re.compile(r"^(\d+) ([0-9a-f]{40})$")


class GitError(RuntimeError):
    """A git command failed or returned unusable output."""


def git(
    repo: str | Path, *args: str, check: bool = True
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if check and proc.returncode != 0:
        raise GitError(
            f"git {' '.join(args)}: {proc.stderr.strip() or proc.returncode}"
        )
    return proc


def git_out(repo: str | Path, *args: str) -> str:
    return git(repo, *args).stdout.strip()


def changed_files(repo: str | Path, span: str) -> list[tuple[str, str]]:
    """(new mode, path) per changed file. NUL-separated output keeps paths unquoted."""
    out = git(repo, "diff", "--raw", "-z", "--no-renames", span).stdout
    fields = out.split("\0")
    files = []
    for meta, path in zip(fields[0::2], fields[1::2], strict=False):
        files.append((meta.split()[1], path))
    return files


def gate_path(thread: str, rnd: int) -> str:
    return f"{GATE_DIR}/{thread}-r{rnd}.json"


def read_gate_at(repo: str | Path, rev: str, path: str) -> dict[str, Any]:
    """Read a gate file from a commit tree, never from the working tree."""
    proc = git(repo, "show", f"{rev}:{path}", check=False)
    if proc.returncode != 0:
        raise GitError(f"gate file {path} not found in {rev}")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise GitError(f"gate file {path} in {rev} is not JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise GitError(f"gate file {path} in {rev} is not an object")
    return data


def commit_time(repo: str | Path, rev: str) -> int:
    return int(git_out(repo, "show", "-s", "--format=%ct", rev))


def is_ancestor(repo: str | Path, ancestor: str, descendant: str) -> bool:
    """True only when git proves ancestry; an unknown commit counts as False."""
    return (
        git(
            repo, "merge-base", "--is-ancestor", ancestor, descendant, check=False
        ).returncode
        == 0
    )


def default_history_path(env: dict[str, str] | None = None) -> Path:
    env = os.environ if env is None else env
    state = env.get("DOTFILES_STATE_DIR") or str(
        Path(env.get("HOME", "~")).expanduser() / ".local/state/dotfiles"
    )
    return Path(state) / "sync-history.log"


def parse_sync_history(text: str) -> list[tuple[int, str]]:
    entries = []
    for line in text.splitlines():
        match = SYNC_LINE.match(line.strip())
        if match:
            entries.append((int(match.group(1)), match.group(2)))
    return entries


def first_sync_containing(
    repo: str | Path, merge: str, history: list[tuple[int, str]]
) -> tuple[int, str] | None:
    """First history line whose sha has the merge commit as an ancestor."""
    merge_sha = git_out(repo, "rev-parse", "--verify", f"{merge}^{{commit}}")
    for epoch, sha in history:
        if is_ancestor(repo, merge_sha, sha):
            return epoch, sha
    return None
