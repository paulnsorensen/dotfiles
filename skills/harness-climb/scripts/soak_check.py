"""Soak hold: fail a harness pin bump while a field-gate soak window is open.

A window opens when a PR that adds a gate file merges to main. It closes
after the gate's sync grace plus its soak length. Both times come from git
history, so the check needs no extra state.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

import hc_git
from hc_stats import DAY, GATE_DEFAULTS

PIN_FILE = "chezmoi/dot_config/mise/config.toml"
PINNED_TOOLS = ("aqua:anthropics/claude-code", "aqua:openai/codex")
OVERRIDE_LABEL = "harness-climb/soak-override"


def changed_pins(repo: str | Path, base: str, head: str) -> list[str]:
    """Pinned tools whose line the PR diff adds or removes."""
    diff = hc_git.git_out(
        repo, "diff", "-U0", "--no-color", f"{base}...{head}", "--", PIN_FILE
    )
    changed = set()
    for line in diff.splitlines():
        if line[:1] in ("+", "-") and not line.startswith(("+++", "---")):
            changed.update(tool for tool in PINNED_TOOLS if tool in line)
    return sorted(changed)


def _resolve_main(repo: str | Path, main_ref: str) -> str:
    for candidate in (main_ref, "main"):
        if (
            hc_git.git(
                repo,
                "rev-parse",
                "--verify",
                "--quiet",
                f"{candidate}^{{commit}}",
                check=False,
            ).returncode
            == 0
        ):
            return candidate
    raise hc_git.GitError(f"main ref {main_ref} not found; fetch full history")


def open_windows(repo: str | Path, main_ref: str, now: float) -> list[dict[str, Any]]:
    """Gate files added to main whose soak window contains `now`."""
    ref = _resolve_main(repo, main_ref)
    log = hc_git.git_out(
        repo, "log", "--first-parent", "--diff-filter=A", "--name-only",
        "--format=%x01%H %ct", ref, "--", hc_git.GATE_DIR,
    )  # fmt: skip
    added: dict[str, tuple[str, int]] = {}
    for block in log.split("\x01")[1:]:
        head, *files = block.strip().splitlines()
        sha, ctime = head.split()
        for path in files:
            if path.endswith(".json"):
                added.setdefault(path, (sha, int(ctime)))  # newest add wins
    windows = []
    for path, (sha, opened) in sorted(added.items()):
        try:
            gate = hc_git.read_gate_at(repo, sha, path)
        except hc_git.GitError:
            gate = {}
        grace = gate.get("sync_grace_days", GATE_DEFAULTS["sync_grace_days"])
        soak = gate.get("soak_days", GATE_DEFAULTS["soak_days"])
        closes = opened + (grace + soak) * DAY
        if opened <= now < closes:
            windows.append(
                {"gate_file": path, "merge": sha, "opened": opened, "closes": closes}
            )
    return windows


def soak_check(
    repo: str | Path,
    base: str,
    head: str,
    main_ref: str,
    labels: list[str],
    now: float | None = None,
) -> dict[str, Any]:
    """Verdict dict; status is `pass` or `fail`."""
    now = time.time() if now is None else now
    if not base:
        return {
            "status": "pass",
            "reason": "no-pull-request",
            "pins_changed": [],
            "open_gate_files": [],
        }
    pins = changed_pins(repo, base, head)
    if not pins:
        return {
            "status": "pass",
            "reason": "no-pin-change",
            "pins_changed": [],
            "open_gate_files": [],
        }
    windows = open_windows(repo, main_ref, now)
    names = [w["gate_file"] for w in windows]
    if not windows:
        return {
            "status": "pass",
            "reason": "no-open-window",
            "pins_changed": pins,
            "open_gate_files": [],
        }
    if OVERRIDE_LABEL in labels:
        return {
            "status": "pass",
            "reason": "override",
            "override": OVERRIDE_LABEL,
            "pins_changed": pins,
            "open_gate_files": names,
            "windows": windows,
        }
    return {
        "status": "fail",
        "reason": "open-window",
        "pins_changed": pins,
        "open_gate_files": names,
        "windows": windows,
    }


def run(args: Any) -> int:
    labels = [x.strip() for x in (args.labels or "").split(",") if x.strip()]
    try:
        result = soak_check(
            args.repo or ".", args.base, args.head, args.main_ref, labels, args.now
        )
    except hc_git.GitError as exc:
        print(json.dumps({"status": "error", "error": str(exc)}))
        return 2
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "pass" else 1
