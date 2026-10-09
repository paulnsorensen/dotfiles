"""The append-only round ledger: lines, verdict checks, pending rounds, and the command."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any

import hc_gate
import hc_git
import hc_stats
from hc_core import InputError, emit, repo_root, state_root, stopped

LEDGER_KEYS = ("round", "change", "pr", "lab", "claude", "codex", "candidate", "merge")
LEDGER_VERDICTS = (*hc_stats.VERDICTS, "pending", "rejected", "n/a")


def _clean(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value).replace(" | ", " / ")).strip()


def parse_ledger_line(line: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in line.split(" | ") if "=" in part)


def ledger_path(root: Path, thread: str) -> Path:
    return root / thread / "ledger.md"


def read_ledger(root: Path, thread: str) -> list[dict[str, str]]:
    """Every ledger line of the thread, parsed, in file order."""
    path = ledger_path(root, thread)
    if not path.is_file():
        return []
    return [parse_ledger_line(line) for line in path.read_text().splitlines()]


def verify_merge_tree(repo: Path, merge: str, thread: str, rnd: int) -> None:
    """A keep line must name a merge commit whose tree holds the edit and its gate file."""
    gate = hc_gate.gate_path(thread, rnd)
    if (
        hc_git.git(repo, "cat-file", "-e", f"{merge}:{gate}", check=False).returncode
        != 0
    ):
        raise InputError(f"merge {merge} does not hold {gate}")
    parents = hc_git.git_out(repo, "rev-list", "--parents", "-n", "1", merge).split()[
        1:
    ]
    base = [f"{merge}^1"] if parents else []
    names = hc_git.git_out(
        repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", *base, merge
    ).splitlines()
    if not [n for n in names if n and n != gate]:
        raise InputError(f"merge {merge} changes nothing besides {gate}")


def ledger_append(
    repo: Path, root: Path, thread: str, fields: dict[str, Any]
) -> dict[str, Any]:
    missing = [k for k in LEDGER_KEYS if fields.get(k) in (None, "")]
    if missing:
        raise InputError(f"ledger line lacks {', '.join(missing)}")
    for key in ("claude", "codex", "candidate"):
        if fields[key] not in LEDGER_VERDICTS:
            raise InputError(
                f"ledger {key} must be one of {', '.join(LEDGER_VERDICTS)}"
            )
    if fields["candidate"] in (hc_stats.KEEP, hc_stats.KEEP_CHEAPER):
        verify_merge_tree(repo, str(fields["merge"]), thread, int(fields["round"]))
    line = " | ".join(f"{k}={_clean(fields[k])}" for k in LEDGER_KEYS)
    path = ledger_path(root, thread)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as fh:
        fh.write(line + "\n")
    return {"status": "appended", "ledger": str(path), "line": line}


def append_note(
    repo: Path, root: Path, thread: str, rnd: int, change: str, candidate: str
) -> None:
    """Record a round that never reached the field gate."""
    fields = dict.fromkeys(("lab", "claude", "codex"), "n/a")
    fields.update(pr="none", merge="none", change=change, candidate=candidate)
    ledger_append(repo, root, thread, {**fields, "round": rnd})


def pending_rounds(root: Path, thread: str) -> list[dict[str, str]]:
    """Rounds whose latest ledger line is `pending`. The ledger is append-only: the last line wins."""
    latest: dict[str, dict[str, str]] = {}
    for fields in read_ledger(root, thread):
        if fields.get("round", "").isdigit():
            latest[fields["round"]] = fields
    return [
        fields
        for _, fields in sorted(latest.items(), key=lambda item: int(item[0]))
        if fields.get("candidate") == "pending"
    ]


def measured_rounds(root: Path, thread: str) -> set[str]:
    """Round numbers, as written, that hold a field verdict in the ledger."""
    return {
        fields["round"]
        for fields in read_ledger(root, thread)
        if "round" in fields and fields.get("candidate") in hc_stats.VERDICTS
    }


def is_measured(root: Path, thread: str, rnd: int) -> bool:
    """True when the ledger holds a field verdict for this gate round."""
    return str(rnd) in measured_rounds(root, thread)


def resolve_merge(repo: Path, main_ref: str, thread: str, rnd: int) -> str | None:
    """The first-parent commit on `main_ref` that brought the round's gate file in.

    Only history reachable from `main_ref` counts, so an unmerged branch commit never resolves.
    """
    gate = hc_gate.gate_path(thread, rnd)
    added = hc_git.git_out(
        repo, "log", "--diff-filter=A", "--format=%H", main_ref, "--", gate
    ).split()
    if not added:
        return None
    commit = added[-1]
    first_parent = hc_git.git_out(repo, "rev-list", "--first-parent", main_ref).split()
    if commit in first_parent:
        return commit
    path = hc_git.git_out(
        repo,
        "rev-list",
        "--first-parent",
        "--ancestry-path",
        "--reverse",
        f"{commit}..{main_ref}",
    ).split()
    return path[0] if path else None


def _pending_payload(
    repo: Path, root: Path, args: argparse.Namespace
) -> dict[str, Any]:
    rounds = []
    for fields in pending_rounds(root, args.thread):
        rnd = int(fields["round"])
        rounds.append(
            {
                "round": rnd,
                "change": fields.get("change", ""),
                "gate": hc_gate.gate_path(args.thread, rnd),
                "merge": resolve_merge(repo, args.main_ref, args.thread, rnd),
            }
        )
    return {"status": "ok", "pending": rounds}


def cmd_ledger(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    root = state_root(args, repo)
    if args.action == "tail":
        path = ledger_path(root, args.thread)
        lines = path.read_text().splitlines()[-args.last :] if path.is_file() else []
        emit({"status": "ok", "lines": lines})
        return 0
    if args.action == "pending":
        emit(_pending_payload(repo, root, args))
        return 0
    fields = {k: getattr(args, k) for k in LEDGER_KEYS}
    try:
        emit(ledger_append(repo, root, args.thread, fields))
    except (InputError, hc_git.GitError) as exc:
        emit({"status": "refused", "error": str(exc)})
        return 1
    return 0
