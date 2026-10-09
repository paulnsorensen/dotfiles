"""Field-gate statistics: guard composite, windows, Welch 2-SE verdicts.

Every function here is pure. Rows are per-session dicts with the keys
`harness`, `start` (epoch seconds), `version`, `target`, `tool_error_rate`,
`permission_denials`, `stop_hook_blocks`, and `tokens_per_turn`.
"""

from __future__ import annotations

import math
import statistics
from collections.abc import Iterable
from typing import Any

HARNESSES = ("claude", "codex")
DAY = 86400

GUARD_COMPOSITE_VERSION = 1
# Each member names the harnesses that record it. A harness outside the list
# gets `n/a` for that member. `n/a` is never a pass.
GUARD_COMPOSITE: dict[int, tuple[tuple[str, tuple[str, ...]], ...]] = {
    1: (
        ("tool_error_rate", ("claude", "codex")),
        ("permission_denials", ("claude",)),
        ("stop_hook_blocks", ("claude",)),
    ),
}

KEEP, KEEP_CHEAPER, REVERT, INCONCLUSIVE = (
    "keep",
    "keep-cheaper",
    "revert",
    "inconclusive",
)
VERDICTS = (KEEP, KEEP_CHEAPER, REVERT, INCONCLUSIVE)


# --- windows ---------------------------------------------------------------


def last_version_change(
    rows: Iterable[dict[str, Any]], before_ts: float
) -> float | None:
    """Start time of the first session of the latest version run before `before_ts`."""
    versioned = sorted(
        (r for r in rows if r.get("version") and r["start"] < before_ts),
        key=lambda r: r["start"],
    )
    change = None
    previous = None
    for row in versioned:
        if previous is not None and row["version"] != previous:
            change = row["start"]
        previous = row["version"]
    return change


def select_windows(
    after_start: float, soak_days: float, version_change: float | None
) -> dict[str, tuple[float, float]]:
    """Before = [max(after_start - soak, last change), after_start); after = [after_start, after_start + soak)."""
    soak = soak_days * DAY
    before_start = after_start - soak
    if version_change is not None:
        before_start = max(before_start, version_change)
    return {
        "before": (before_start, after_start),
        "after": (after_start, after_start + soak),
    }


def in_window(
    rows: Iterable[dict[str, Any]], window: tuple[float, float]
) -> list[dict[str, Any]]:
    return [r for r in rows if window[0] <= r["start"] < window[1]]


# --- statistics ------------------------------------------------------------


def _values(rows: Iterable[dict[str, Any]], key: str) -> list[float]:
    return [float(r[key]) for r in rows if r.get(key) is not None]


def welch(before: list[float], after: list[float]) -> dict[str, float | int]:
    """Unpaired difference of means (after - before) and its standard error."""

    def moments(xs: list[float]) -> tuple[float, float]:
        var = statistics.variance(xs) if len(xs) > 1 else math.nan
        return statistics.fmean(xs), var

    mb, vb = moments(before)
    ma, va = moments(after)
    se = math.sqrt(vb / len(before) + va / len(after))
    return {
        "mean_before": mb,
        "mean_after": ma,
        "diff": ma - mb,
        "se": se,
        "n_before": len(before),
        "n_after": len(after),
    }


def beyond(cmp: dict[str, float | int]) -> bool:
    """True when |diff| exceeds 2 SE. An undefined SE never counts."""
    if math.isnan(cmp["se"]):
        return False
    return abs(cmp["diff"]) > 2 * cmp["se"]


def _relative(change: float, base: float) -> float:
    if base == 0:
        return 0.0 if change == 0 else math.copysign(math.inf, change)
    return change / abs(base)


def _num(x: float) -> float | None:
    return None if math.isinf(x) or math.isnan(x) else round(x, 6)


def _report(cmp: dict[str, float | int]) -> dict[str, Any]:
    return {k: (_num(v) if isinstance(v, float) else v) for k, v in cmp.items()}


def guard_members(version: int, harness: str) -> list[tuple[str, bool]]:
    return [
        (name, harness in harnesses) for name, harnesses in GUARD_COMPOSITE[version]
    ]


def judge(
    harness: str, gate: dict[str, Any], before: list[dict], after: list[dict]
) -> dict[str, Any]:
    """One harness verdict from the two windows. Windows already passed the session-count and version checks."""
    guards: dict[str, Any] = {}
    regressed: str | None = None
    for name, recorded in guard_members(gate["guard_composite_version"], harness):
        if not recorded:
            guards[name] = {"status": "n/a"}
            continue
        b, a = _values(before, name), _values(after, name)
        if not b or not a:
            return _result(INCONCLUSIVE, f"guard-no-data:{name}", guards, None, None)
        cmp = welch(b, a)
        bad = beyond(cmp) and cmp["diff"] > 0
        guards[name] = {"status": "regress" if bad else "pass", **_report(cmp)}
        if bad and regressed is None:
            regressed = name

    target = welch(_values(before, "target"), _values(after, "target"))
    sign = -1 if gate["direction"] == "lower" else 1
    improved = beyond(target) and sign * target["diff"] > 0
    worse = beyond(target) and sign * target["diff"] < 0
    gain = _relative(sign * target["diff"], target["mean_before"])
    target_report = {**_report(target), "gain": _num(gain)}

    tb, ta = _values(before, "tokens_per_turn"), _values(after, "tokens_per_turn")
    tokens = welch(tb, ta) if len(tb) > 1 and len(ta) > 1 else None
    cost = _relative(tokens["diff"], tokens["mean_before"]) if tokens else None
    token_report = (
        {**_report(tokens), "cost": _num(cost)} if tokens else {"status": "unavailable"}
    )

    if worse:
        return _result(REVERT, "target", guards, target_report, token_report)
    if regressed:
        return _result(REVERT, regressed, guards, target_report, token_report)
    if improved:
        if tokens is None:
            return _result(
                INCONCLUSIVE, "tokens-unavailable", guards, target_report, token_report
            )
        budget = gate["token_per_gain"] * gain if gate["token_per_gain"] else 0.0
        if cost > budget:
            return _result(REVERT, "token-cost", guards, target_report, token_report)
        return _result(KEEP, "target", guards, target_report, token_report)
    if tokens is not None and beyond(tokens) and tokens["diff"] < 0:
        return _result(KEEP_CHEAPER, "tokens", guards, target_report, token_report)
    return _result(INCONCLUSIVE, "no-effect", guards, target_report, token_report)


def _result(
    verdict: str, reason: str, guards: dict, target: dict | None, tokens: dict | None
) -> dict[str, Any]:
    return {
        "verdict": verdict,
        "reason": reason,
        "guards": guards,
        "target": target,
        "tokens": tokens,
    }


def combine(verdicts: Iterable[str]) -> str:
    """Candidate verdict: revert beats keep, keep beats keep-cheaper, else inconclusive."""
    seen = set(verdicts)
    for winner in (REVERT, KEEP, KEEP_CHEAPER):
        if winner in seen:
            return winner
    return INCONCLUSIVE


def evaluate_harness(
    harness: str, gate: dict[str, Any], rows: list[dict], after_start: float
) -> dict[str, Any]:
    """Select windows for one harness, run the pre-checks, and judge."""
    mine = [r for r in rows if r.get("harness") == harness]
    windows = select_windows(
        after_start, gate["soak_days"], last_version_change(mine, after_start)
    )
    before, after = (
        in_window(mine, windows["before"]),
        in_window(mine, windows["after"]),
    )
    scored_before = [r for r in before if r.get("target") is not None]
    scored_after = [r for r in after if r.get("target") is not None]
    base = {"windows": {k: list(v) for k, v in windows.items()}}
    versions = sorted({r["version"] for r in before + after if r.get("version")})
    if len(versions) > 1:
        return {
            **base,
            **_result(INCONCLUSIVE, "version-changed", {}, None, None),
            "versions": versions,
        }
    counts = {"before": len(scored_before), "after": len(scored_after)}
    if min(counts.values()) < gate["min_sessions"]:
        return {
            **base,
            **_result(INCONCLUSIVE, "min-sessions", {}, None, None),
            "sessions": counts,
            "min_sessions": gate["min_sessions"],
        }
    judged = judge(harness, gate, scored_before, scored_after)
    return {**base, **judged, "sessions": counts}
