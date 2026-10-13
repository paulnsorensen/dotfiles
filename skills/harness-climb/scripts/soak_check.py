"""Soak hold: fail a harness pin bump while a field-gate soak window is open.

A window opens when a PR that adds a gate file merges to main. It closes
after the gate's sync grace plus its soak length. Both times come from git
history, so the check needs no extra state.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

import hc_gate
import hc_git
from hc_core import emit
from hc_stats import DAY

PIN_FILE = "chezmoi/dot_config/mise/config.toml"
PINNED_TOOLS = ("aqua:anthropics/claude-code", "aqua:openai/codex")
OVERRIDE_LABEL = "harness-climb/soak-override"


def _pin_values(repo: str | Path, rev: str) -> dict[str, Any] | None:
    """Pin values at a revision.

    Maps each pinned tool to its value. A tool maps to None when the file is
    absent at that revision or the tool is unset. The result is None only when
    the TOML does not parse.
    """
    import tomllib  # local: ruff 0.16 and 0.17 class this module differently

    proc = hc_git.git(repo, "show", f"{rev}:{PIN_FILE}", check=False)
    if proc.returncode != 0:
        return dict.fromkeys(PINNED_TOOLS)
    try:
        tools = tomllib.loads(proc.stdout).get("tools", {})
    except tomllib.TOMLDecodeError:
        return None
    return {tool: tools.get(tool) for tool in PINNED_TOOLS}


def changed_pins(repo: str | Path, base: str, head: str) -> list[str]:
    """Pinned tools whose parsed value differs between the merge base and head.

    An unparsable file counts as a change to every pin, so a bump cannot hide in it.
    """
    old = _pin_values(repo, hc_git.git_out(repo, "merge-base", base, head))
    new = _pin_values(repo, head)
    if old is None or new is None:
        return sorted(PINNED_TOOLS)
    return sorted(tool for tool in PINNED_TOOLS if old[tool] != new[tool])


def open_windows(repo: str | Path, main_ref: str, now: float) -> list[dict[str, Any]]:
    """Gate files added to main whose soak window contains `now`."""
    ref = hc_git.resolve_main(repo, main_ref)
    names = hc_git.git_out(
        repo, "log", "--first-parent", "--diff-filter=A", "--name-only",
        "--format=", ref, "--", hc_gate.GATE_DIR,
    )  # fmt: skip
    windows = []
    for path in sorted({n for n in names.splitlines() if n.endswith(".json")}):
        added = hc_gate.gate_merge(repo, ref, path)
        if added is None:
            continue
        sha, opened = added
        try:
            gate = hc_gate.normalize_gate(hc_gate.read_gate_at(repo, sha, path))
        except (hc_git.GitError, ValueError):
            gate = dict(hc_gate.GATE_DEFAULTS)
        closes = opened + (gate["sync_grace_days"] + gate["soak_days"]) * DAY
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
    result: dict[str, Any] = {
        "status": "pass",
        "pins_changed": [],
        "open_gate_files": [],
    }
    if not base:
        return {**result, "reason": "no-pull-request"}
    pins = changed_pins(repo, base, head)
    if not pins:
        return {**result, "reason": "no-pin-change"}
    windows = open_windows(repo, main_ref, now)
    result["pins_changed"] = pins
    if not windows:
        return {**result, "reason": "no-open-window"}
    result.update(open_gate_files=[w["gate_file"] for w in windows], windows=windows)
    if OVERRIDE_LABEL in labels:
        return {**result, "reason": "override", "override": OVERRIDE_LABEL}
    return {**result, "status": "fail", "reason": "open-window"}


def run(args: Any) -> int:
    labels = [x.strip() for x in (args.labels or "").split(",") if x.strip()]
    result = soak_check(
        args.repo or ".", args.base, args.head, args.main_ref, labels, args.now
    )
    emit(result)
    return 0 if result["status"] == "pass" else 1
