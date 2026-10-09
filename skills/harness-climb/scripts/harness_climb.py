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
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hc_git
import hc_policy
import hc_stats
import soak_check

SKILLS_DIR = Path(__file__).resolve().parents[2]
DB_PATH_SH = SKILLS_DIR / "session-analytics" / "scripts" / "db-path.sh"
HARNESS_FILTER = re.compile(
    r"harness\s+IN\s*\(\s*'claude'\s*,\s*'codex'\s*\)", re.IGNORECASE
)
DEFAULT_BUDGET_CMD = "uv run --project agent-profile --frozen python tests/helpers/agent_instruction_budget.py agents/instruction-budgets.toml"
MAX_CRITIC_FAILURES = 3  # the first attempt plus two repairs
LEDGER_VERDICTS = (*hc_stats.VERDICTS, "pending", "rejected", "n/a")
IN_SCOPE = "harness IN ('claude','codex')"


class InputError(ValueError):
    """The caller gave input the contract rejects."""


# --- shared ----------------------------------------------------------------


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def repo_root(arg: str | None) -> Path:
    if arg:
        return Path(arg).resolve()
    return Path(hc_git.git_out(".", "rev-parse", "--show-toplevel"))


def state_root(args: argparse.Namespace, repo: Path) -> Path:
    return Path(args.state_dir).resolve() if args.state_dir else repo / ".harness-climb"


def stop_reason(root: Path, thread: str) -> str | None:
    stop = root / thread / "STOP"
    if not stop.is_file():
        return None
    lines = stop.read_text().splitlines()
    return lines[0] if lines else ""


def stopped(args: argparse.Namespace, repo: Path) -> bool:
    reason = stop_reason(state_root(args, repo), args.thread)
    if reason is None:
        return False
    emit({"status": "stopped", "reason": reason})
    return True


def resolve_db() -> Path:
    """The session database path, from the shared session-analytics resolver only."""
    proc = subprocess.run(
        ["bash", "-c", 'source "$1" && sessions_db_path', "_", str(DB_PATH_SH)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise InputError(f"cannot resolve the session database: {proc.stderr.strip()}")
    return Path(proc.stdout.strip())


def duck(db: Path, sql: str) -> list[dict[str, Any]]:
    limit = os.environ.get("SESSIONS_DUCKDB_MEMORY_LIMIT", "8GB")
    proc = subprocess.run(
        [
            "duckdb",
            "-init",
            "/dev/null",
            "-readonly",
            str(db),
            "-cmd",
            f"SET memory_limit='{limit}'",
            "-json",
            "-c",
            sql,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise InputError(f"duckdb failed: {proc.stderr.strip()[:300]}")
    text = proc.stdout.strip()
    return json.loads(text) if text else []


# --- analyze ---------------------------------------------------------------


def validate_findings(data: dict[str, Any]) -> list[str]:
    """Reject a failure mode without query, counts, or component, and a habit without a session count."""
    errors = []
    for i, fm in enumerate(data.get("failure_modes", [])):
        tag = f"failure_modes[{i}]"
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
    for i, habit in enumerate(data.get("success_habits", [])):
        count = habit.get("sessions")
        if not isinstance(count, int) or isinstance(count, bool) or count < 1:
            errors.append(f"success_habits[{i}] lacks a session count")
    return errors


def cmd_analyze(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    findings: dict[str, Any] = (
        json.loads(Path(args.findings).read_text()) if args.findings else {}
    )
    errors = validate_findings(findings)
    db = resolve_db()
    out: dict[str, Any] = {
        "status": "ok",
        "db": str(db),
        "harnesses": list(hc_stats.HARNESSES),
        "window_days": args.days,
    }
    if errors:
        emit({**out, "status": "invalid", "errors": errors})
        return 2
    if not db.is_file():
        emit({**out, "status": "no-db"})
        return 1
    window = (
        f"CAST(first_seen AS TIMESTAMPTZ) >= now() - INTERVAL '{int(args.days)}' DAY"
    )
    out["sessions"] = duck(
        db,
        f"SELECT harness, count(DISTINCT sessionId) AS sessions FROM sessions WHERE {IN_SCOPE} AND {window} GROUP BY harness ORDER BY harness",
    )
    out["tool_results"] = duck(
        db,
        "SELECT harness, count(*) AS results, sum(CASE WHEN is_error = 'true' THEN 1 ELSE 0 END) AS errors "
        f"FROM tool_results WHERE {IN_SCOPE} AND CAST(timestamp AS TIMESTAMPTZ) >= now() - INTERVAL '{int(args.days)}' DAY "
        "GROUP BY harness ORDER BY harness",
    )
    out["failure_modes"] = findings.get("failure_modes", [])
    out["success_habits"] = findings.get("success_habits", [])
    emit(out)
    return 0


# --- critic ----------------------------------------------------------------


def round_dir(root: Path, thread: str, rnd: int) -> Path:
    return root / thread / "rounds" / f"r{rnd}"


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


# Codex injects these as user messages; they are harness text, not prompts.
CODEX_INJECTED = ("<", "# AGENTS.md instructions")


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
        for line in lines:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            payload = entry.get("payload") if isinstance(entry, dict) else None
            if (
                entry.get("type") != "response_item"
                or not isinstance(payload, dict)
                or payload.get("type") != "message"
                or payload.get("role") != "user"
            ):
                continue
            text = flatten_content(payload.get("content"))
            if text.strip() and not text.lstrip().startswith(CODEX_INJECTED):
                prompts.append(text)
    return prompts


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


def run_critic_checks(
    args: argparse.Namespace, repo: Path, tags: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[str]]:
    violations: list[dict[str, Any]] = []
    expected = f"harness-climb/{args.thread}/r{args.round}"
    branch = hc_git.git_out(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if branch != expected:
        violations.append(
            {
                "check": "branch",
                "category": "branch-name",
                "expected": expected,
                "actual": branch,
            }
        )
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
        violations.append({"check": "leakage", "category": "denylist-unavailable"})
    else:
        violations += notes
        violations += hc_policy.check_leakage(hc_policy.parse_added_lines(diff), deny)
    if not scope:
        budget = subprocess.run(
            shlex.split(args.budget_cmd),
            cwd=repo,
            capture_output=True,
            text=True,
            check=False,
        )
        if budget.returncode != 0:
            violations.append(
                {
                    "check": "budget",
                    "category": "budget-exit",
                    "exit": budget.returncode,
                }
            )
    return violations, paths


def cmd_critic(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    root = state_root(args, repo)
    rdir = round_dir(root, args.thread, args.round)
    state_file = rdir / "critic.json"
    state = (
        json.loads(state_file.read_text()) if state_file.is_file() else {"failures": 0}
    )
    if state.get("rejected"):
        emit(
            {
                "status": "rejected",
                "attempt": state["failures"],
                "violations": state.get("violations", []),
            }
        )
        return 1
    tags_file = Path(args.tags) if args.tags else rdir / "tags.json"
    tags = json.loads(tags_file.read_text()) if tags_file.is_file() else {}
    violations, paths = run_critic_checks(args, repo, tags)
    head = hc_git.git_out(repo, "rev-parse", "HEAD")
    rdir.mkdir(parents=True, exist_ok=True)
    if not violations:
        state.update(
            passed=True,
            head=head,
            components=sorted({classify_tag(tags, p) for p in paths}),
        )
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
    state.update(failures=state["failures"] + 1, passed=False, violations=violations)
    status = "fail"
    if state["failures"] >= MAX_CRITIC_FAILURES:
        state["rejected"] = True
        status = "rejected"
        ledger_append(
            repo,
            root,
            args.thread,
            {
                "round": args.round,
                "change": "rejected by critic",
                "pr": "none",
                "lab": "n/a",
                "claude": "n/a",
                "codex": "n/a",
                "candidate": "rejected",
                "merge": "none",
            },
        )
    state_file.write_text(json.dumps(state, indent=2))
    emit({"status": status, "attempt": state["failures"], "violations": violations})
    return 1


def classify_tag(tags: dict[str, Any], path: str) -> str:
    raw = tags.get(path)
    return raw[0] if isinstance(raw, list) else str(raw)


# --- ledger ----------------------------------------------------------------

LEDGER_KEYS = ("round", "change", "pr", "lab", "claude", "codex", "candidate", "merge")


def _clean(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value).replace(" | ", " / ")).strip()


def parse_ledger_line(line: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in line.split(" | ") if "=" in part)


def verify_merge_tree(repo: Path, merge: str, thread: str, rnd: int) -> None:
    """A keep line must name a merge commit whose tree holds the edit and its gate file."""
    gate = hc_git.gate_path(thread, rnd)
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
    path = root / thread / "ledger.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as fh:
        fh.write(line + "\n")
    return {"status": "appended", "ledger": str(path), "line": line}


def cmd_ledger(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    root = state_root(args, repo)
    if args.action == "tail":
        path = root / args.thread / "ledger.md"
        lines = path.read_text().splitlines()[-args.last :] if path.is_file() else []
        emit({"status": "ok", "lines": lines})
        return 0
    fields = {k: getattr(args, k) for k in LEDGER_KEYS}
    try:
        emit(ledger_append(repo, root, args.thread, fields))
    except (InputError, hc_git.GitError) as exc:
        emit({"status": "refused", "error": str(exc)})
        return 1
    return 0


def is_measured(root: Path, thread: str, rnd: int) -> bool:
    """True when the ledger holds a field verdict for this gate round."""
    path = root / thread / "ledger.md"
    if not path.is_file():
        return False
    for line in path.read_text().splitlines():
        fields = parse_ledger_line(line)
        if (
            fields.get("round") == str(rnd)
            and fields.get("candidate") in hc_stats.VERDICTS
        ):
            return True
    return False


# --- freeze ----------------------------------------------------------------


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
        repo, "ls-tree", "-r", "--name-only", base, "--", hc_git.GATE_DIR, check=False
    ).stdout.split()
    pending = []
    for name in names:
        match = re.match(rf"^{re.escape(hc_git.GATE_DIR)}/(.+)-r(\d+)\.json$", name)
        if not match or (match.group(1), int(match.group(2))) == (thread, rnd):
            continue
        gate = hc_git.read_gate_at(repo, base, name)
        if gate.get("component") == component and not is_measured(
            root, match.group(1), int(match.group(2))
        ):
            pending.append(name)
    return pending


def cmd_freeze(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    root = state_root(args, repo)
    state_file = round_dir(root, args.thread, args.round) / "critic.json"
    state = json.loads(state_file.read_text()) if state_file.is_file() else {}
    head = hc_git.git_out(repo, "rev-parse", "HEAD")
    refusal = None
    if not state.get("passed") or state.get("head") != head:
        refusal = "no passing critic verdict for this HEAD"
    elif state.get("components") != [args.component]:
        refusal = f"critic tags {state.get('components')} do not match component {args.component}"
    pending = (
        []
        if refusal
        else in_flight(repo, root, args.base, args.component, args.thread, args.round)
    )
    if pending:
        refusal = f"component {args.component} has a merged unmeasured candidate: {', '.join(pending)}"
    lab: dict[str, str] = {}
    if not refusal:
        try:
            lab = lab_result(args.component, args.contract, args.autoimprove_verdict)
        except InputError as exc:
            refusal = str(exc)
    if refusal:
        emit({"status": "refused", "reason": refusal})
        return 1
    query = (
        Path(args.targeted_query_file).read_text()
        if args.targeted_query_file
        else args.targeted_query
    )
    gate = hc_stats.normalize_gate(
        {
            "thread": args.thread,
            "round": args.round,
            "component": args.component,
            "targeted_query": (query or "").strip(),
            "direction": args.direction,
            "guard_composite_version": hc_stats.GUARD_COMPOSITE_VERSION,
            "min_sessions": args.min_sessions,
            "soak_days": args.soak_days,
            "sync_grace_days": args.sync_grace_days,
            "token_per_gain": args.token_per_gain,
        }
    )
    if not gate["targeted_query"]:
        raise InputError("freeze needs a targeted query")
    rel = hc_git.gate_path(args.thread, args.round)
    target = repo / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(gate, indent=2, sort_keys=True) + "\n")
    hc_git.git(repo, "add", "--", rel)
    hc_git.git(
        repo,
        "commit",
        "-m",
        f"chore(harness-climb): freeze gate {args.thread}-r{args.round}",
        "--",
        rel,
    )
    emit(
        {
            "status": "frozen",
            "gate_file": rel,
            "commit": hc_git.git_out(repo, "rev-parse", "HEAD"),
            "lab": lab,
            "gate": gate,
        }
    )
    return 0


# --- field gate ------------------------------------------------------------


def _both(reason: str, **extra: Any) -> dict[str, Any]:
    inconclusive = {"verdict": hc_stats.INCONCLUSIVE, "reason": reason}
    return {
        "harnesses": {h: dict(inconclusive) for h in hc_stats.HARNESSES},
        "candidate": hc_stats.INCONCLUSIVE,
        **extra,
    }


def load_rows(
    db: Path, gate: dict[str, Any], start: float, end: float
) -> list[dict[str, Any]]:
    """Per-session rows for claude and codex between `start` and `end`."""
    has_version = duck(
        db,
        "SELECT count(*) AS n FROM information_schema.columns WHERE table_name = 'sessions' AND column_name = 'version'",
    )[0]["n"]
    version = "max(version)" if has_version else "CAST(NULL AS VARCHAR)"
    query = gate["targeted_query"].strip().rstrip(";")
    sql = f"""
    WITH s AS (
        SELECT harness, sessionId, epoch(CAST(min(first_seen) AS TIMESTAMPTZ)) AS start, {version} AS version
        FROM sessions WHERE {IN_SCOPE} GROUP BY harness, sessionId),
    tg AS (SELECT harness, sessionId, avg(value) AS target FROM ({query}) AS q GROUP BY harness, sessionId),
    er AS (SELECT harness, sessionId, avg(CASE WHEN is_error = 'true' THEN 1.0 ELSE 0.0 END) AS tool_error_rate
           FROM tool_results WHERE {IN_SCOPE} GROUP BY harness, sessionId),
    pd AS (SELECT harness, sessionId, count(*) AS permission_denials FROM permission_denials GROUP BY harness, sessionId),
    sh AS (SELECT harness, sessionId, count(*) AS stop_hook_blocks FROM stop_hooks WHERE preventedContinuation GROUP BY harness, sessionId),
    tk AS (SELECT harness, sessionId, avg(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)) AS tokens_per_turn
           FROM model_turns WHERE {IN_SCOPE} GROUP BY harness, sessionId)
    SELECT s.harness, s.sessionId AS session, s.start, s.version, tg.target, er.tool_error_rate,
           coalesce(pd.permission_denials, 0) AS permission_denials,
           coalesce(sh.stop_hook_blocks, 0) AS stop_hook_blocks, tk.tokens_per_turn
    FROM s LEFT JOIN tg USING (harness, sessionId) LEFT JOIN er USING (harness, sessionId)
    LEFT JOIN pd USING (harness, sessionId) LEFT JOIN sh USING (harness, sessionId)
    LEFT JOIN tk USING (harness, sessionId)
    WHERE s.start >= {float(start)} AND s.start < {float(end)}
    """
    return duck(db, sql)


def field_gate(
    repo: Path,
    thread: str,
    rnd: int,
    merge: str,
    history_text: str,
    rows: list[dict[str, Any]] | None,
    now: float,
    db: Path | None = None,
) -> dict[str, Any]:
    """Verdict dict. Reads settings from the merge commit and mutates nothing."""
    gate = hc_stats.normalize_gate(
        hc_git.read_gate_at(repo, merge, hc_git.gate_path(thread, rnd))
    )
    out: dict[str, Any] = {
        "status": "ok",
        "thread": thread,
        "round": rnd,
        "merge": merge,
        "gate": gate,
        "action": "none",
    }
    if gate["guard_composite_version"] not in hc_stats.GUARD_COMPOSITE:
        return {**out, **_both("guard-version-unknown")}
    sync = hc_git.first_sync_containing(
        repo, merge, hc_git.parse_sync_history(history_text)
    )
    if sync is None:
        return {**out, **_both("no-sync")}
    after_start = float(sync[0])
    out["sync"] = {"epoch": sync[0], "sha": sync[1]}
    if (
        after_start
        > hc_git.commit_time(repo, merge) + gate["sync_grace_days"] * hc_stats.DAY
    ):
        return {**out, **_both("sync-late")}
    if now < after_start + gate["soak_days"] * hc_stats.DAY:
        return {
            **out,
            "status": "not-due",
            "due": after_start + gate["soak_days"] * hc_stats.DAY,
        }
    if rows is None:
        if db is None or not db.is_file():
            return {**out, "status": "no-db"}
        soak = gate["soak_days"] * hc_stats.DAY
        rows = load_rows(db, gate, after_start - 2 * soak, after_start + soak)
    per = {
        h: hc_stats.evaluate_harness(h, gate, rows, after_start)
        for h in hc_stats.HARNESSES
    }
    candidate = hc_stats.combine(r["verdict"] for r in per.values())
    out.update(harnesses=per, candidate=candidate)
    if candidate == hc_stats.REVERT:
        out["action"] = "open-revert-pr"
    return out


def cmd_field_gate(args: argparse.Namespace) -> int:
    repo = repo_root(args.repo)
    if stopped(args, repo):
        return 0
    history = Path(args.history) if args.history else hc_git.default_history_path()
    history_text = history.read_text() if history.is_file() else ""
    rows = json.loads(Path(args.rows).read_text()) if args.rows else None
    now = args.now if args.now is not None else time.time()
    db = None if rows is not None else resolve_db()
    try:
        result = field_gate(
            repo, args.thread, args.round, args.merge, history_text, rows, now, db
        )
    except (hc_git.GitError, ValueError) as exc:
        emit({"status": "error", "error": str(exc)})
        return 2
    emit(result)
    return 0 if result["status"] in ("ok", "not-due") else 1


# --- cli -------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="harness_climb.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name: str, handler: Any, thread: bool = True) -> argparse.ArgumentParser:
        p = sub.add_parser(name)
        p.set_defaults(handler=handler)
        p.add_argument(
            "--repo", help="repository root (default: git toplevel of the cwd)"
        )
        if thread:
            p.add_argument(
                "--state-dir", help="state root (default: <repo>/.harness-climb)"
            )
            p.add_argument("--thread", required=True)
        return p

    p = add("analyze", cmd_analyze)
    p.add_argument("--days", type=int, default=14)
    p.add_argument("--findings", help="analyst findings JSON to validate")

    p = add("critic", cmd_critic)
    p.add_argument("--round", type=int, required=True)
    p.add_argument("--base", default="main")
    p.add_argument("--tags", help="JSON map of changed path to component tag")
    p.add_argument(
        "--denylist", help="JSON {prompts, projects} instead of the session database"
    )
    p.add_argument("--budget-cmd", default=DEFAULT_BUDGET_CMD)

    p = add("freeze", cmd_freeze)
    p.add_argument("--round", type=int, required=True)
    p.add_argument("--component", required=True, choices=hc_policy.COMPONENTS)
    p.add_argument("--base", default="main")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--targeted-query")
    group.add_argument("--targeted-query-file")
    p.add_argument("--direction", choices=("lower", "higher"), default="lower")
    p.add_argument(
        "--min-sessions", type=int, default=hc_stats.GATE_DEFAULTS["min_sessions"]
    )
    p.add_argument(
        "--soak-days", type=float, default=hc_stats.GATE_DEFAULTS["soak_days"]
    )
    p.add_argument(
        "--sync-grace-days",
        type=float,
        default=hc_stats.GATE_DEFAULTS["sync_grace_days"],
    )
    p.add_argument(
        "--token-per-gain", type=float, default=hc_stats.GATE_DEFAULTS["token_per_gain"]
    )
    p.add_argument(
        "--contract",
        action="store_true",
        help="the skill has an approved autoimprove contract",
    )
    p.add_argument("--autoimprove-verdict")

    p = add("field-gate", cmd_field_gate)
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

    p = add("ledger", cmd_ledger)
    p.add_argument("action", choices=("append", "tail"))
    p.add_argument("--last", type=int, default=5)
    for key in LEDGER_KEYS:
        p.add_argument(f"--{key}")

    p = add("soak-check", soak_check.run, thread=False)
    p.add_argument(
        "--base", default="", help="PR base commit; empty means no pull request"
    )
    p.add_argument("--head", default="HEAD")
    p.add_argument("--main-ref", default="origin/main")
    p.add_argument("--labels", default="", help="comma-separated PR labels")
    p.add_argument("--now", type=float)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except (InputError, hc_git.GitError, ValueError, OSError) as exc:
        emit({"status": "error", "error": str(exc)})
        return 2


if __name__ == "__main__":
    sys.exit(main())
