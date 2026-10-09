"""Critic policy: component tags, owned-source allowlist, leakage denylist."""

from __future__ import annotations

import posixpath
import re
from collections.abc import Iterable
from pathlib import Path
from typing import Any

COMPONENTS = ("global-doc", "preamble", "agent-def", "hook", "skill")

# One path class per component tag. A path outside every class is not owned.
_CLASSES: dict[str, tuple[re.Pattern[str], ...]] = {
    "global-doc": (
        re.compile(r"^(AGENTS|CLAUDE)\.md$"),
        re.compile(r"^(agents|agent-profile)/AGENTS\.md$"),
        re.compile(r"^profiles/[^/]+/(AGENTS|CLAUDE)\.md$"),
    ),
    "preamble": (re.compile(r"^agents/preamble\.md$"),),
    "agent-def": (
        re.compile(r"^agents/registry\.yaml$"),
        re.compile(r"^agents/agent_definitions/.+"),
    ),
    "hook": (
        re.compile(r"^agents/hooks/.+"),
        re.compile(r"^claude/hooks/.+"),
    ),
    "skill": (re.compile(r"^skills/[^/_][^/]*/.+"),),
}

BUDGET_CONFIG = "agents/instruction-budgets.toml"
RUNTIME_PREFIXES = (
    ".claude/",
    ".codex/",
    ".omp/",
    ".pi/",
    ".cursor/",
    ".copilot/",
    "chezmoi/private_dot_codex/",
)
# Short names that vendored repositories answer to in a skills path.
_VENDOR_ALIASES = {
    "skillz-that-grillz": ("skillz",),
    "sliced-bread-architecture": ("sliced-bread",),
}

NGRAM = 8
MIN_PROJECT_LEN = 4


def vendored_names(registry_text: str) -> set[str]:
    """Vendored skill names: source repository names plus explicit `skills:` lists."""
    names: set[str] = set()
    in_sources = False
    for line in registry_text.splitlines():
        if re.match(r"^sources:\s*$", line):
            in_sources = True
            continue
        if not in_sources:
            continue
        if re.match(r"^\S", line) and not line.startswith("#"):
            break
        repo = re.match(r"^  ([\w.-]+)/([\w.-]+):\s*$", line)
        if repo:
            names.add(repo.group(2))
            names.update(_VENDOR_ALIASES.get(repo.group(2), ()))
        listed = re.match(r"^\s+skills:\s*\[(.*)\]", line)
        if listed:
            names.update(n.strip() for n in listed.group(1).split(",") if n.strip())
    return names


def classify(path: str) -> str | None:
    """Component tag for a path, or None when no class matches."""
    for tag, patterns in _CLASSES.items():
        if any(p.match(path) for p in patterns):
            return tag
    return None


def _normalized(path: str) -> str | None:
    if path.startswith(("/", "~")) or "\\" in path:
        return None
    clean = posixpath.normpath(path)
    return None if clean.startswith("..") else clean


def check_scope(paths: Iterable[str], vendored: set[str]) -> list[dict[str, str]]:
    violations = []
    for path in paths:
        clean = _normalized(path)
        if clean is None or clean.startswith(RUNTIME_PREFIXES):
            violations.append(
                {"check": "scope", "category": "runtime-output", "path": path}
            )
        elif clean == BUDGET_CONFIG:
            violations.append(
                {"check": "budget", "category": "budget-config", "path": path}
            )
        elif clean.startswith("skills/") and clean.split("/")[1] in vendored:
            violations.append({"check": "scope", "category": "vendored", "path": path})
        elif classify(clean) is None:
            violations.append(
                {"check": "scope", "category": "outside-allowlist", "path": path}
            )
    return violations


def check_tags(paths: Iterable[str], tags: dict[str, Any]) -> list[dict[str, str]]:
    """Each changed path needs exactly one tag, and the tag must match its path class."""
    violations = []
    for path in paths:
        raw = tags.get(path)
        listed = [] if raw is None else (raw if isinstance(raw, list) else [raw])
        if not listed:
            violations.append({"check": "tag", "category": "tag-missing", "path": path})
        elif len(listed) > 1:
            violations.append(
                {"check": "tag", "category": "tag-multiple", "path": path}
            )
        elif listed[0] not in COMPONENTS:
            violations.append({"check": "tag", "category": "tag-unknown", "path": path})
        elif classify(path) != listed[0]:
            violations.append(
                {"check": "tag", "category": "tag-mismatch", "path": path}
            )
    return violations


# --- leakage ---------------------------------------------------------------

_WORD = re.compile(r"[a-z0-9]+")


def _tokens(text: str) -> list[str]:
    return _WORD.findall(text.lower())


def _ngram_keys(words: list[str]) -> Iterable[str]:
    for i in range(len(words) - NGRAM + 1):
        yield " ".join(words[i : i + NGRAM])


def build_denylist(
    prompts: Iterable[str], projects: Iterable[str], own_names: Iterable[str] = ()
) -> dict[str, set[str]]:
    """Denylist by category: prompt n-grams, project names, repository paths."""
    skip = {n.lower() for n in own_names}
    deny: dict[str, set[str]] = {"prompt": set(), "project": set(), "path": set()}
    for prompt in prompts:
        if prompt and not prompt.lstrip().startswith("/"):
            deny["prompt"].update(_ngram_keys(_tokens(prompt)))
    for project in projects:
        if not project:
            continue
        base = Path(project).name.lower()
        if len(base) >= MIN_PROJECT_LEN and base not in skip:
            deny["project"].add(base)
        if project.count("/") >= 2:
            deny["path"].add(project.rstrip("/").lower())
    return deny


def check_leakage(
    added: dict[str, list[tuple[int, str]]], deny: dict[str, set[str]]
) -> list[dict[str, Any]]:
    """Scan added lines only. A violation holds the category and file:line, never text."""
    violations: list[dict[str, Any]] = []
    for path, lines in added.items():
        stream: list[tuple[str, int]] = []
        for lineno, text in lines:
            low = text.lower()
            for category in ("path", "project"):
                if any(span in low for span in deny.get(category, ())):
                    violations.append(
                        {
                            "check": "leakage",
                            "category": category,
                            "file": path,
                            "line": lineno,
                        }
                    )
            stream.extend((tok, lineno) for tok in _tokens(text))
        prompts = deny.get("prompt", set())
        seen: set[int] = set()
        for i in range(len(stream) - NGRAM + 1):
            if (
                " ".join(t for t, _ in stream[i : i + NGRAM]) in prompts
                and stream[i][1] not in seen
            ):
                seen.add(stream[i][1])
                violations.append(
                    {
                        "check": "leakage",
                        "category": "prompt",
                        "file": path,
                        "line": stream[i][1],
                    }
                )
    return violations


def parse_added_lines(diff: str) -> dict[str, list[tuple[int, str]]]:
    """Added lines per file from `git diff -U0`, with new-file line numbers."""
    added: dict[str, list[tuple[int, str]]] = {}
    path: str | None = None
    lineno = 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            target = line[4:]
            path = None if target == "/dev/null" else target.removeprefix("b/")
        elif line.startswith("@@"):
            match = re.match(r"@@ -\S+ \+(\d+)", line)
            lineno = int(match.group(1)) if match else 0
        elif path and line.startswith("+") and not line.startswith("+++"):
            added.setdefault(path, []).append((lineno, line[1:]))
            lineno += 1
    return added
