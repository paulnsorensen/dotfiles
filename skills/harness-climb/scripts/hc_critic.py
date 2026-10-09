"""The critic: scope, tag, leakage, and budget checks on one round's branch."""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
from pathlib import Path
from typing import Any

import hc_git
import hc_policy
from hc_core import emit, read_json, repo_root, round_dir, state_root, stopped
from hc_denylist import load_denylist
from hc_ledger import append_note

DEFAULT_BUDGET_CMD = "uv run --project agent-profile --frozen python tests/helpers/agent_instruction_budget.py agents/instruction-budgets.toml"
MAX_CRITIC_FAILURES = 3  # the first attempt plus two repairs


def _branch_violations(args: argparse.Namespace, repo: Path) -> list[dict[str, Any]]:
    expected = f"harness-climb/{args.thread}/r{args.round}"
    branch = hc_git.git_out(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if branch == expected:
        return []
    return [
        {
            "check": "branch",
            "category": "branch-name",
            "expected": expected,
            "actual": branch,
        }
    ]


def _leakage_violations(
    args: argparse.Namespace, repo: Path, span: str
) -> list[dict[str, Any]]:
    diff = hc_git.git_out(
        repo,
        "-c",
        "core.quotepath=false",
        "diff",
        "-U0",
        "--no-color",
        "--no-renames",
        span,
    )
    notes: list[dict[str, Any]] = []
    deny = load_denylist(args, repo, notes)
    if deny is None:
        return [{"check": "leakage", "category": "denylist-unavailable"}]
    return notes + hc_policy.check_leakage(hc_policy.parse_added_lines(diff), deny)


def _budget_violations(args: argparse.Namespace, repo: Path) -> list[dict[str, Any]]:
    budget = subprocess.run(
        shlex.split(args.budget_cmd),
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
    )
    if budget.returncode == 0:
        return []
    return [{"check": "budget", "category": "budget-exit", "exit": budget.returncode}]


def run_critic_checks(
    args: argparse.Namespace, repo: Path, tags: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[str]]:
    violations = _branch_violations(args, repo)
    span = f"{args.base}...HEAD"
    changed = hc_git.changed_files(repo, span)
    paths = [path for _, path in changed]
    if not paths:
        violations.append({"check": "diff", "category": "empty-diff"})
    registry = repo / "skills" / "_registry.yaml"
    vendored = (
        hc_policy.vendored_names(registry.read_text()) if registry.is_file() else set()
    )
    scope = hc_policy.check_scope(paths, vendored)
    violations += scope + hc_policy.check_tags(paths, tags)
    violations += [
        {"check": "scope", "category": "symlink", "path": path}
        for mode, path in changed
        if mode == "120000"
    ]
    violations += _leakage_violations(args, repo, span)
    if not scope:
        violations += _budget_violations(args, repo)
    return violations, paths


def _record_failure(
    args: argparse.Namespace,
    repo: Path,
    state: dict[str, Any],
    violations: list[dict[str, Any]],
) -> str:
    """Count the failure in `state`; the third one rejects the round. Returns the status."""
    state.update(failures=state["failures"] + 1, passed=False, violations=violations)
    if state["failures"] < MAX_CRITIC_FAILURES:
        return "fail"
    state["rejected"] = True
    append_note(
        repo,
        state_root(args, repo),
        args.thread,
        args.round,
        "rejected by critic",
        "rejected",
    )
    return "rejected"


def cmd_critic(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    rdir = round_dir(state_root(args, repo), args.thread, args.round)
    state_file = rdir / "critic.json"
    state = read_json(state_file, {"failures": 0})
    if state.get("rejected"):
        emit(
            {
                "status": "rejected",
                "attempt": state["failures"],
                "violations": state.get("violations", []),
            }
        )
        return 1
    tags = read_json(Path(args.tags) if args.tags else rdir / "tags.json", {})
    violations, paths = run_critic_checks(args, repo, tags)
    head = hc_git.git_out(repo, "rev-parse", "HEAD")
    rdir.mkdir(parents=True, exist_ok=True)
    if violations:
        status = _record_failure(args, repo, state, violations)
        state_file.write_text(json.dumps(state, indent=2))
        emit({"status": status, "attempt": state["failures"], "violations": violations})
        return 1
    components = sorted({hc_policy.tag_of(tags, p)[0] for p in paths})
    state.update(passed=True, head=head, components=components)
    state_file.write_text(json.dumps(state, indent=2))
    emit(
        {
            "status": "pass",
            "attempt": state["failures"] + 1,
            "head": head,
            "violations": [],
        }
    )
    return 0
