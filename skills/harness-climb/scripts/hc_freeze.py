"""The freeze: refuse or commit the gate file for a critic-approved round."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import hc_gate
import hc_git
import hc_policy
import hc_stats
from hc_core import (
    InputError,
    emit,
    read_json,
    repo_root,
    round_dir,
    state_root,
)
from hc_db import DbError, duck, resolve_db
from hc_denylist import load_denylist
from hc_ledger import append_note, measured_rounds


def touched_skills(repo: Path, base: str) -> set[str]:
    """Names of the skills that the diff from `base` to HEAD touches."""
    names = set()
    for _, path in hc_git.changed_files(repo, f"{base}...HEAD"):
        parts = path.split("/")
        if parts[0] == "skills" and len(parts) > 2:
            names.add(parts[1])
    return names


def has_contract(repo: Path, base: str, names: set[str]) -> bool:
    """True when any touched skill has `evals/autoimprove.json` at `base`."""
    return any(
        hc_git.git(
            repo,
            "cat-file",
            "-e",
            f"{base}:skills/{name}/evals/autoimprove.json",
            check=False,
        ).returncode
        == 0
        for name in names
    )


def leakage_problem(query: str, repo: Path) -> str | None:
    """Why the targeted query cannot go to the public repo, or None. It never echoes the query."""
    try:
        deny, _ = load_denylist(None, repo)
    except DbError as exc:
        return f"session database unavailable: {exc}"
    if deny is None:
        return "leakage denylist unavailable"
    added = {"targeted_query": list(enumerate(query.splitlines(), 1))}
    hits = hc_policy.check_leakage(added, deny)
    if not hits:
        return None
    return "targeted query leaks denylisted text: " + ", ".join(
        sorted({hit["category"] for hit in hits})
    )


def query_problem(query: str) -> str | None:
    """Why the targeted query cannot freeze, or None. It dry-runs against the session database."""
    if ";" in query:
        return "targeted query must not contain ';'"
    try:
        duck(
            resolve_db(),
            f"SELECT harness, sessionId, value FROM ({query}) AS q LIMIT 0",
        )
    except DbError as exc:
        return f"session database unavailable: {exc}"
    except InputError as exc:
        return f"targeted query failed the dry run on harness, sessionId, value: {exc}"
    return None


def lab_result(component: str, contract: bool, verdict: str | None) -> dict[str, str]:
    if component == "skill" and contract:
        if verdict != "promote":
            raise InputError(f"autoimprove verdict {verdict!r} is not promote")
        return {"verdict": "promote"}
    reason = "no-contract" if component == "skill" else "isolation-preflight"
    return {"verdict": "held", "reason": reason}


def in_flight(
    repo: Path, root: Path, base: str, component: str, thread: str, rnd: int
) -> list[str]:
    """Merged gate files of this component that have no field verdict yet."""
    names = hc_git.git(
        repo, "ls-tree", "-r", "--name-only", base, "--", hc_gate.GATE_DIR, check=False
    ).stdout.split()
    measured: dict[str, set[str]] = {}
    pending = []
    for name in names:
        parsed = hc_gate.parse_gate_path(name)
        if not parsed or parsed == (thread, rnd):
            continue
        gate_thread, gate_round = parsed[0], str(parsed[1])
        if gate_thread not in measured:
            measured[gate_thread] = measured_rounds(root, gate_thread)
        gate = hc_gate.read_gate_at(repo, base, name)
        if (
            gate.get("component") == component
            and gate_round not in measured[gate_thread]
        ):
            pending.append(name)
    return pending


def _refusal(
    args: argparse.Namespace, repo: Path, root: Path
) -> tuple[str | None, dict[str, str]]:
    """Why the freeze must refuse, or None, with the lab result when it may go on."""
    state = read_json(round_dir(root, args.thread, args.round) / "critic.json", {})
    if not state.get("passed") or state.get("head") != hc_git.git_out(
        repo, "rev-parse", "HEAD"
    ):
        return "no passing critic verdict for this HEAD", {}
    if state.get("components") != [args.component]:
        return (
            f"critic tags {state.get('components')} do not match component {args.component}",
            {},
        )
    pending = in_flight(repo, root, args.base, args.component, args.thread, args.round)
    if pending:
        return (
            f"component {args.component} has a merged unmeasured candidate: {', '.join(pending)}",
            {},
        )
    names = touched_skills(repo, args.base)
    if args.component == "skill" and len(names) > 1:
        return (
            f"a skill round must touch one skill, not {len(names)}: {', '.join(sorted(names))}",
            {},
        )
    contract = has_contract(repo, args.base, names)
    try:
        return None, lab_result(args.component, contract, args.autoimprove_verdict)
    except InputError as exc:
        return str(exc), {}


def _gate_from_args(args: argparse.Namespace, query: str) -> dict[str, Any]:
    return hc_gate.normalize_gate(
        {
            "thread": args.thread,
            "round": args.round,
            "component": args.component,
            "targeted_query": query,
            "direction": args.direction,
            "guard_composite_version": hc_stats.GUARD_COMPOSITE_VERSION,
            "min_sessions": args.min_sessions,
            "soak_days": args.soak_days,
            "sync_grace_days": args.sync_grace_days,
            "token_per_gain": args.token_per_gain,
        }
    )


def cmd_freeze(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    root = state_root(args, repo)
    refusal, lab = _refusal(args, repo, root)
    query = ""
    if not refusal:
        query = (
            Path(args.targeted_query_file).read_text()
            if args.targeted_query_file
            else args.targeted_query
        )
        query = query.strip()
        if not query:
            raise InputError("freeze needs a targeted query")
        refusal = leakage_problem(query, repo) or query_problem(query)
    if refusal:
        append_note(
            repo, root, args.thread, args.round, f"freeze refused: {refusal}", "n/a"
        )
        emit({"status": "refused", "reason": refusal})
        return 1
    gate = _gate_from_args(args, query)
    rel = hc_gate.write_gate(repo, gate)
    hc_git.git(repo, "add", "--", rel)
    message = f"chore(harness-climb): freeze gate {args.thread}-r{args.round}"
    hc_git.git(repo, "commit", "-m", message, "--", rel)
    commit = hc_git.git_out(repo, "rev-parse", "HEAD")
    emit(
        {
            "status": "frozen",
            "gate_file": rel,
            "commit": commit,
            "lab": lab,
            "gate": gate,
        }
    )
    return 0
