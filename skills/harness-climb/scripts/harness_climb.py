#!/usr/bin/env python3
"""Deterministic steps of the harness-climb loop. Every subcommand prints JSON.

The skill (SKILL.md) drives one round per invocation. This script holds the
checks that must not depend on model judgment: analysis validation, the
critic, the freeze, the field gate, the ledger, and the soak hold.
Stdlib only; the duckdb CLI runs through subprocess.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hc_critic
import hc_field_gate
import hc_freeze
import hc_gate
import hc_git
import hc_ledger
import hc_policy
import hc_stats
import soak_check
from hc_core import emit, repo_root, stopped
from hc_db import IN_SCOPE, duck, resolve_db

HARNESS_FILTER = re.compile(
    r"harness\s+IN\s*\(\s*'claude'\s*,\s*'codex'\s*\)", re.IGNORECASE
)


# --- analyze ---------------------------------------------------------------


def _failure_mode_errors(i: int, fm: dict[str, Any]) -> list[str]:
    tag = f"failure_modes[{i}]"
    errors = []
    query = fm.get("query")
    counts = fm.get("counts")
    if not isinstance(query, str) or not query.strip():
        errors.append(f"{tag} lacks query")
    elif not HARNESS_FILTER.search(query):
        errors.append(f"{tag} query must filter {IN_SCOPE}")
    if (
        not isinstance(counts, dict)
        or not counts
        or not all(isinstance(v, int) for v in counts.values())
    ):
        errors.append(f"{tag} lacks integer counts")
    if fm.get("component") not in hc_policy.COMPONENTS:
        errors.append(
            f"{tag} lacks a blamed component from {', '.join(hc_policy.COMPONENTS)}"
        )
    return errors


def validate_findings(data: dict[str, Any]) -> list[str]:
    """Reject a failure mode without query, counts, or component, and a habit without a session count."""
    errors = []
    for i, fm in enumerate(data.get("failure_modes", [])):
        errors += _failure_mode_errors(i, fm)
    for i, habit in enumerate(data.get("success_habits", [])):
        count = habit.get("sessions")
        if not isinstance(count, int) or isinstance(count, bool) or count < 1:
            errors.append(f"success_habits[{i}] lacks a session count")
    return errors


def _usage(db: Path, days: int) -> dict[str, Any]:
    since = f"now() - INTERVAL '{int(days)}' DAY"
    return {
        "sessions": duck(
            db,
            "SELECT harness, count(DISTINCT sessionId) AS sessions FROM sessions "
            f"WHERE {IN_SCOPE} AND CAST(first_seen AS TIMESTAMPTZ) >= {since} "
            "GROUP BY harness ORDER BY harness",
        ),
        "tool_results": duck(
            db,
            "SELECT harness, count(*) AS results, sum(CASE WHEN is_error = 'true' THEN 1 ELSE 0 END) AS errors "
            f"FROM tool_results WHERE {IN_SCOPE} AND CAST(timestamp AS TIMESTAMPTZ) >= {since} "
            "GROUP BY harness ORDER BY harness",
        ),
    }


def cmd_analyze(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    findings: dict[str, Any] = (
        json.loads(Path(args.findings).read_text()) if args.findings else {}
    )
    errors = validate_findings(findings)
    out: dict[str, Any] = {
        "status": "ok",
        "harnesses": list(hc_stats.HARNESSES),
        "window_days": args.days,
    }
    if errors:
        emit({**out, "status": "invalid", "errors": errors})
        return 2
    db = resolve_db()
    out["db"] = str(db)
    if not db.is_file():
        emit({**out, "status": "no-db"})
        return 1
    out.update(_usage(db, args.days))
    out["failure_modes"] = findings.get("failure_modes", [])
    out["success_habits"] = findings.get("success_habits", [])
    emit(out)
    return 0


# --- cli -------------------------------------------------------------------


def _subcommand(
    sub: Any, name: str, handler: Any, thread: bool = True
) -> argparse.ArgumentParser:
    p = sub.add_parser(name)
    p.set_defaults(handler=handler)
    p.add_argument("--repo", help="repository root (default: git toplevel of the cwd)")
    if thread:
        p.add_argument(
            "--state-dir", help="state root (default: <repo>/.harness-climb)"
        )
        p.add_argument("--thread", required=True)
    return p


def _add_analyze(sub: Any) -> None:
    p = _subcommand(sub, "analyze", cmd_analyze)
    p.add_argument("--days", type=int, default=14)
    p.add_argument("--findings", help="analyst findings JSON to validate")


def _add_critic(sub: Any) -> None:
    p = _subcommand(sub, "critic", hc_critic.cmd_critic)
    p.add_argument("--round", type=int, required=True)
    p.add_argument("--base", default="origin/main")
    p.add_argument("--tags", help="JSON map of changed path to component tag")
    p.add_argument(
        "--denylist", help="JSON {prompts, projects} instead of the session database"
    )
    p.add_argument("--budget-cmd", default=hc_critic.DEFAULT_BUDGET_CMD)


def _add_freeze(sub: Any) -> None:
    defaults = hc_gate.GATE_DEFAULTS
    p = _subcommand(sub, "freeze", hc_freeze.cmd_freeze)
    p.add_argument("--round", type=int, required=True)
    p.add_argument("--component", required=True, choices=hc_policy.COMPONENTS)
    p.add_argument("--base", default="origin/main")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--targeted-query")
    group.add_argument("--targeted-query-file")
    p.add_argument("--direction", choices=("lower", "higher"), default="lower")
    p.add_argument("--min-sessions", type=int, default=defaults["min_sessions"])
    for flag in ("soak-days", "sync-grace-days", "token-per-gain"):
        p.add_argument(
            f"--{flag}", type=float, default=defaults[flag.replace("-", "_")]
        )
    p.add_argument("--autoimprove-verdict")


def _add_field_gate(sub: Any) -> None:
    p = _subcommand(sub, "field-gate", hc_field_gate.cmd_field_gate)
    p.add_argument("--round", type=int, required=True)
    p.add_argument(
        "--merge", required=True, help="merge commit that holds the gate file"
    )
    p.add_argument(
        "--history",
        help="sync-history.log (default: $DOTFILES_STATE_DIR/sync-history.log)",
    )
    p.add_argument(
        "--rows", help="per-session rows JSON instead of the session database"
    )
    p.add_argument("--now", type=float)


def _add_ledger(sub: Any) -> None:
    p = _subcommand(sub, "ledger", hc_ledger.cmd_ledger)
    p.add_argument("action", choices=("append", "tail", "pending"))
    p.add_argument("--last", type=int, default=5)
    p.add_argument(
        "--main-ref",
        default="origin/main",
        help="branch that holds merged rounds (pending)",
    )
    for key in hc_ledger.LEDGER_KEYS:
        p.add_argument(f"--{key}")


def _add_soak_check(sub: Any) -> None:
    p = _subcommand(sub, "soak-check", soak_check.run, thread=False)
    p.add_argument(
        "--base", default="", help="PR base commit; empty means no pull request"
    )
    p.add_argument("--head", default="HEAD")
    p.add_argument("--main-ref", default="origin/main")
    p.add_argument("--labels", default="", help="comma-separated PR labels")
    p.add_argument("--now", type=float)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="harness_climb.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for add in (
        _add_analyze,
        _add_critic,
        _add_freeze,
        _add_field_gate,
        _add_ledger,
        _add_soak_check,
    ):
        add(sub)
    return parser


def _resolve_refs(args: argparse.Namespace) -> None:
    """Fall back to the local `main` when `origin/main` does not exist."""
    if args.command in ("critic", "freeze"):
        args.base = hc_git.resolve_main(repo_root(args.repo), args.base)
    elif args.command == "ledger" and args.action == "pending":
        args.main_ref = hc_git.resolve_main(repo_root(args.repo), args.main_ref)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        _resolve_refs(args)
        return args.handler(args)
    except (hc_git.GitError, ValueError, OSError) as exc:
        emit({"status": "error", "error": str(exc)})
        return 2


if __name__ == "__main__":
    sys.exit(main())
