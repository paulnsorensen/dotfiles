#!/usr/bin/env python3
"""Select the `just check` legs and test files that a change can affect.

The selector maps changed paths to gate legs. It selects Bats and workflow
smoke tests per file from the repository paths that each test file names.
Thus the map lives in the tests and does not drift into a separate registry.
CI still runs every leg; this selection only shortens the local gate.

A test file is selected for a changed path when one of its path tokens:

- is the path, or a directory that contains the path (two or more segments);
- is a glob that matches the path (`$VAR` segments count as `*`).

A test file is also selected when it names the changed file as a word: the
basename when it is unique in the repository, else `parent/basename` (and
`parent.stem` for modules).
A test that calls a `tests/*.bash` helper function observes the helper's paths.
A changed file also selects the tests of each non-Markdown file that names it
as a word (a source, an import, a run by path, an `includeTemplate`),
transitively. A module also matches as `parent/stem`. Data files, tests, and
gate files never join that closure. A file with more than 10 users joins it
but does not expand further. Unmatched changed paths run the whole `test` leg.

Usage:
    affected.py plan [--all] [--base REF]      tab-separated plan lines
    affected.py commands [--all] [--base REF]  one shell command per leg

The `commands` form writes a human summary to stderr.
The stdlib-only code runs on the macOS system Python 3.9.
"""

from __future__ import annotations

import argparse
import functools
import os
import re
import shlex
import subprocess
import sys
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

# Legs in launch order: the slowest leg starts first.
LEGS = (
    "test",
    "test-python",
    "lint-shell",
    "lint-markdown",
    "smoke",
    "lint-js",
    "lint-python",
)

# Files that change how the gate selects or runs work: run every leg.
GATE_FILES = frozenset({"justfile", "tests/check-affected.sh", "tests/lib/affected.py"})
# Shared Bats infrastructure that every .bats file loads.
BATS_ALL = frozenset(
    {"tests/test_helper.bash", "tests/run-tests.sh", "tests/install-bats.sh"}
)
# Shared smoke infrastructure that every workflow test imports.
SMOKE_ALL = frozenset({"tests/workflows/harness.mjs", "tests/workflows-test.sh"})
# Repository inputs that the agent-profile pytest suite reads through
# `Path` joins. Those joins carry no path tokens to extract.
PYTEST_PREFIXES = (
    "agent-profile/",
    "profiles/",
    "agents/",
    "chezmoi/.chezmoidata/",
    "chezmoi/lib/agent-profile-sync.sh",
    "skills/_registry.yaml",
    "claude/plugins/registry.yaml",
)
# Pinned Node linter versions (markdownlint-cli2, eslint).
LINT_DEPS_PREFIX = ".github/lint-deps/"
MARKDOWNLINT_CONFIG = ".markdownlint-cli2.yaml"
PYTHON_CONFIGS = frozenset({"pyproject.toml", "ruff.toml", ".ruff.toml"})
# Tool pins (shellcheck, ruff, ...) for the lint legs: any change runs every lint leg.
MISE_CONFIGS = frozenset(
    {"chezmoi/dot_config/mise/config.toml", "mise.toml", ".mise.toml"}
)
LINT_LEGS = ("lint-shell", "lint-markdown", "lint-js", "lint-python")
SHELL_LINT_EXTRA = frozenset({"chezmoi/private_dot_codex/modify_private_config.toml"})

BATS_GLOB = "tests/*.bats"
BATS_HELPER_GLOB = "tests/*.bash"
SMOKE_GLOB = "tests/workflows/*.test.mjs"

_TOKEN_RE = re.compile(r"[A-Za-z0-9_.*${}-]*/[A-Za-z0-9_.*${}/-]*")
_VAR_RE = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*")
_FUNC_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{\s*$(.*?)^\}", re.MULTILINE | re.DOTALL
)
_SHEBANG_RE = re.compile(r"^#!.*\b(?:ba)?sh\b")
# Shell `source` and `.`, Python and JS `import`/`from`, and Node `require(`.
# These lines find same-directory relative sources and module stems.
_SOURCE_LINE_RE = r"(^|[;&|[:space:]])(source|\.|import|from)[[:space:]]+|require\("
_MODULE_EXTS = frozenset({"py", "js", "mjs", "cjs"})
_CLOSURE_ROUNDS = 5


@dataclass
class Plan:
    """Legs to run. `files[leg]` is None for a whole-leg run."""

    files: dict[str, set[str] | None] = field(default_factory=dict)
    unmatched: list[str] = field(default_factory=list)
    changed: list[str] = field(default_factory=list)
    test_total: dict[str, int] = field(default_factory=dict)
    reason: str = ""

    def run_whole(self, leg: str) -> None:
        self.files[leg] = None

    def add_files(self, leg: str, paths: set[str]) -> None:
        if not paths or (leg in self.files and self.files[leg] is None):
            return
        self.files.setdefault(leg, set()).update(paths)  # type: ignore[union-attr]


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True
    ).stdout


def merge_base(root: Path, base: str | None) -> str | None:
    """Return the fork point of HEAD and `base`, origin/main, or main."""
    refs = [base] if base else ["origin/main", "main"]
    for ref in refs:
        try:
            return git(root, "merge-base", "HEAD", ref).strip()
        except subprocess.CalledProcessError:
            if base:
                raise SystemExit(f"affected: cannot find a merge base with '{base}'")
    return None


def _nul_split(out: str) -> list[str]:
    return [p for p in out.split("\0") if p]


def changed_paths(root: Path, base: str | None) -> list[str]:
    """Committed, staged, unstaged, and untracked paths since `base`.

    NUL-separated output keeps special names unquoted.
    """
    diff = git(root, "diff", "-z", "--name-only", "--no-renames", base or "HEAD")
    untracked = git(root, "ls-files", "-z", "--others", "--exclude-standard")
    return sorted(set(_nul_split(diff) + _nul_split(untracked)))


def path_tokens(text: str, tops: frozenset[str]) -> set[str]:
    """Repository-relative paths and globs that a test file names."""
    tokens = set()
    for raw in _TOKEN_RE.findall(text):
        tok = _VAR_RE.sub("*", raw)
        if any(c in tok for c in "${}"):
            continue
        segs = [s for s in tok.split("/") if s]
        while segs and segs[0] not in tops:
            segs.pop(0)
        if segs:
            tokens.add("/".join(segs))
    return tokens


def _glob_regex(glob: str) -> str:
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        c = glob[i]
        out.append("[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c))
        i += 1
    return "".join(out)


@functools.cache
def _token_rule(token: str) -> re.Pattern[str]:
    # A token with a slash also matches every path below it (a directory).
    tail = "(?:/.*)?" if "/" in token else ""
    return re.compile(_glob_regex(token) + tail)


def token_matches(token: str, path: str) -> bool:
    """True when a test that names `token` can observe a change to `path`."""
    return _token_rule(token).fullmatch(path) is not None


def needles(path: str, basename_counts: Counter[str]) -> list[str]:
    """The words a file that uses `path` writes.

    A unique basename is enough. A shared basename needs `parent/basename`.
    A module also matches as `parent/stem` (an extensionless `require`) and
    `parent.stem` (a dotted Python import).
    """
    parts = path.split("/")
    words = [parts[-1]] if basename_counts.get(parts[-1], 0) <= 1 else []
    if len(parts) < 2:
        return words
    if not words:
        words.append("/".join(parts[-2:]))
    stem, dot, ext = parts[-1].rpartition(".")
    if dot and stem and ext in _MODULE_EXTS:
        words += [f"{parts[-2]}/{stem}", f"{parts[-2]}.{stem}"]
    return words


def has_word(text: str, word: str) -> bool:
    """True when `word` occurs in `text` with no word character on either side."""
    start = text.find(word)
    while start >= 0:
        end = start + len(word)
        before = text[start - 1] if start else " "
        after = text[end] if end < len(text) else " "
        if not (before.isalnum() or before == "_" or after.isalnum() or after == "_"):
            return True
        start = text.find(word, start + 1)
    return False


def source_lines(root: Path) -> list[tuple[str, str]]:
    """(file, line) for every non-Markdown line that sources or imports a file."""
    try:
        out = git(root, "grep", "-z", "-I", "--untracked", "-E", _SOURCE_LINE_RE)
    except subprocess.CalledProcessError:
        return []
    lines = []
    for row in out.splitlines():
        name, _, line = row.partition("\0")
        if not name.endswith(".md"):
            lines.append((name, line))
    return lines


def referrers(root: Path, word: str) -> set[str]:
    """Non-Markdown files that name `word` as a whole word."""
    try:
        out = git(root, "grep", "-z", "-l", "-I", "--untracked", "-F", "-w", "-e", word)
    except subprocess.CalledProcessError:
        return set()
    return {p for p in _nul_split(out) if not p.endswith(".md")}


_DATA_EXTS = (".tsv", ".yaml", ".yml", ".json", ".toml")


def is_hub(path: str) -> bool:
    """True for files that the closure must not expand through.

    Data files list names, and tests and gate infrastructure name many files.
    Expanding through them spreads one change across the suite. A test that
    names a changed file is still selected directly, and a gate file that
    changes runs whole legs.
    """
    if path.endswith(_DATA_EXTS):
        return True
    if path in GATE_FILES or path in BATS_ALL or path in SMOKE_ALL:
        return True
    return path.startswith("tests/") and path.endswith((".bats", ".bash", ".test.mjs"))


_HUB_FAN_IN = 10


def _local_words(path: str) -> set[str]:
    """Words that a file in the same directory uses to source or import `path`."""
    base = path.rpartition("/")[2]
    stem, dot, ext = base.rpartition(".")
    return {base, stem} if dot and stem and ext in _MODULE_EXTS else {base}


def source_closure(
    changed: list[str],
    lines: list[tuple[str, str]],
    basename_counts: Counter[str],
    find_referrers: Callable[[str], set[str]] = lambda word: set(),
) -> dict[str, str]:
    """Map each changed path, and each file that uses one, to its origin.

    A file uses a path when any non-Markdown line names a needle of the path
    (a source, an import, a run by path, an `includeTemplate`), or when a
    source or import line names its basename or module stem from the same
    directory. Data files, tests, and gate files never join the closure.
    A hub, a file with more than `_HUB_FAN_IN` users, joins it but passes the
    change to no one. A changed hub still expands. A test that names the
    changed file itself always runs.
    """

    def users_of(path: str) -> set[str]:
        local = _local_words(path)
        directory = path.rpartition("/")[0]
        users: set[str] = set()
        for word in needles(path, basename_counts):
            users |= find_referrers(word)
        for name, line in lines:
            if name.rpartition("/")[0] == directory and any(
                has_word(line, w) for w in local
            ):
                users.add(name)
        return users

    origin = {p: p for p in changed}
    frontier = list(changed)
    for _ in range(_CLOSURE_ROUNDS):
        found = []
        for path in frontier:
            for name in sorted(users_of(path)):
                if name in origin or is_hub(name):
                    continue
                origin[name] = origin[path]
                # A hub joins the origin, so tests that exercise the change
                # through it run. Nothing expands past it.
                if len(users_of(name)) <= _HUB_FAN_IN:
                    found.append(name)
        if not found:
            break
        frontier = found
    return origin


def helper_tokens(helpers: dict[str, str], tops: frozenset[str]) -> dict[str, set[str]]:
    """Path tokens per shared helper function, keyed by function name.

    A test that calls a helper observes the paths that the helper names.
    """
    tokens: dict[str, set[str]] = {}
    for text in helpers.values():
        for name, body in _FUNC_RE.findall(text):
            found = path_tokens(body, tops)
            if found:
                tokens.setdefault(name, set()).update(found)
    return tokens


def select_tests(
    tests: dict[str, str],
    origin: dict[str, str],
    tops: frozenset[str],
    basename_counts: Counter[str],
    helpers: dict[str, set[str]] | None = None,
) -> tuple[set[str], set[str]]:
    """Return (selected test files, origins that some test observes)."""
    selected: set[str] = set()
    observed: set[str] = set()
    words = {p: needles(p, basename_counts) for p in origin}
    for test, text in tests.items():
        tokens = path_tokens(text, tops)
        for name, found in (helpers or {}).items():
            if has_word(text, name):
                tokens |= found
        for path, root_path in origin.items():
            word = words[path]
            if (
                path == test
                or any(token_matches(t, path) for t in tokens)
                or any(has_word(text, w) for w in word)
            ):
                selected.add(test)
                observed.add(root_path)
    return selected, observed


def _is_shell(root: Path, path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    if path.endswith((".sh", ".bash")) or name == ".sync" or path.startswith("bin/"):
        return True
    if path in SHELL_LINT_EXTRA:
        return True
    try:
        with open(root / path, encoding="utf-8", errors="replace") as handle:
            return bool(_SHEBANG_RE.match(handle.readline()))
    except OSError:
        return False


def lint_legs(root: Path, path: str) -> dict[str, bool]:
    """Leg -> whole-leg flag for the lint and pytest legs that `path` needs.

    A False flag means: run the leg on this file only.
    """
    legs: dict[str, bool] = {}
    if _is_shell(root, path):
        legs["lint-shell"] = True
    if path.endswith(".py") or path in PYTHON_CONFIGS:
        legs["lint-python"] = True
    if path.startswith(("claude/hooks/", LINT_DEPS_PREFIX)):
        legs["lint-js"] = True
    if path == MARKDOWNLINT_CONFIG or path.startswith(LINT_DEPS_PREFIX):
        legs["lint-markdown"] = True
    elif path.endswith(".md") and (root / path).is_file():
        legs["lint-markdown"] = False
    if path.startswith(PYTEST_PREFIXES):
        legs["test-python"] = True
    if path in MISE_CONFIGS:
        legs.update({leg: True for leg in LINT_LEGS})
    return legs


def _read_tests(root: Path, pattern: str) -> dict[str, str]:
    return {
        p.relative_to(root).as_posix(): p.read_text(encoding="utf-8", errors="replace")
        for p in sorted(root.glob(pattern))
    }


def build_plan(root: Path, changed: list[str], run_all: bool = False) -> Plan:
    plan = Plan(changed=changed)
    gate = [p for p in changed if p in GATE_FILES]
    if run_all or gate:
        if gate:
            plan.reason = f"gate files changed ({' '.join(gate)}): every leg runs"
        for leg in LEGS:
            plan.run_whole(leg)
        return plan
    if not changed:
        return plan

    tracked = _nul_split(git(root, "ls-files", "-z"))
    tops = frozenset(p.split("/", 1)[0] for p in tracked)
    basename_counts = Counter(p.rsplit("/", 1)[-1] for p in tracked)
    origin = source_closure(
        changed,
        source_lines(root),
        basename_counts,
        functools.cache(lambda word: referrers(root, word)),
    )

    observed: set[str] = set()
    for path in changed:
        for leg, whole in lint_legs(root, path).items():
            observed.add(path)
            if whole:
                plan.run_whole(leg)
            else:
                plan.add_files(leg, {path})

    helpers = helper_tokens(_read_tests(root, BATS_HELPER_GLOB), tops)
    suites = (
        ("test", BATS_GLOB, BATS_ALL, helpers),
        ("smoke", SMOKE_GLOB, SMOKE_ALL, {}),
    )
    for leg, pattern, shared, suite_helpers in suites:
        tests = _read_tests(root, pattern)
        plan.test_total[leg] = len(tests)
        selected, seen = select_tests(
            tests, origin, tops, basename_counts, suite_helpers
        )
        observed |= seen
        hits = [p for p in changed if p in shared]
        observed.update(hits)
        if hits:
            plan.run_whole(leg)
        else:
            plan.add_files(leg, selected)

    # A deleted path that no test names needs no report.
    plan.unmatched = [p for p in changed if p not in observed and (root / p).exists()]
    if plan.unmatched:
        # No leg observes these paths, so a test may read them in a way the
        # selector cannot see. Fail closed: run the whole test leg.
        plan.run_whole("test")
        plan.reason = (
            "no leg or test observes "
            + " ".join(plan.unmatched)
            + ": the whole test leg runs"
        )
    return plan


def plan_lines(plan: Plan) -> list[str]:
    lines = []
    for leg in LEGS:
        if leg not in plan.files:
            continue
        files = plan.files[leg]
        lines.extend([leg] if files is None else [f"{leg}\t{f}" for f in sorted(files)])
    lines.extend(f"unmatched\t{p}" for p in plan.unmatched)
    return lines


def command_lines(plan: Plan) -> list[str]:
    """One `just <leg> [files]` command per selected leg, slowest first."""
    commands = []
    for leg in LEGS:
        if leg not in plan.files:
            continue
        files = plan.files[leg]
        args: list[str] = []
        if files is not None:
            # run-tests.sh resolves Bats files relative to tests/.
            strip = "tests/" if leg == "test" else ""
            args = [f[len(strip) :] for f in sorted(files)]
        commands.append(" ".join(["just", leg, *map(shlex.quote, args)]))
    return commands


def summary(plan: Plan, source: str) -> list[str]:
    lines = [f"check: {source}; {len(plan.changed)} changed path(s)"]
    if not plan.changed and not plan.reason:
        lines.append("check: no changes")
    if plan.reason:
        lines.append(f"check: {plan.reason}")
    for leg in LEGS:
        if leg not in plan.files:
            continue
        files = plan.files[leg]
        if files is None:
            detail = "all"
        else:
            total = plan.test_total.get(leg)
            names = " ".join(sorted(f.rsplit("/", 1)[-1] for f in files))
            count = f"{len(files)}/{total}" if total else str(len(files))
            detail = f"{count} file(s): {names}"
        lines.append(f"check:   {leg}: {detail}")
    skipped = [leg for leg in LEGS if leg not in plan.files]
    if skipped:
        lines.append(f"check:   skip: {' '.join(skipped)}")
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="affected.py", description=__doc__.splitlines()[0]
    )
    parser.add_argument("format", choices=("plan", "commands"))
    parser.add_argument("--all", action="store_true", help="run every leg in full")
    parser.add_argument("--base", help="compare against the merge base with REF")
    parser.add_argument("--paths", nargs="+", help="use these changed paths, not git")
    args = parser.parse_args(argv)

    root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    source = "given paths"
    base: str | None = None
    if args.paths:
        changed = sorted(set(args.paths))
    elif args.all:
        changed = []
    else:
        base = merge_base(root, args.base or os.environ.get("CHECK_BASE"))
        changed = changed_paths(root, base)
        source = f"base {base[:12]}" if base else "no base"
    # Without a base, committed branch changes are invisible: run every leg.
    no_base = not args.paths and not args.all and base is None
    plan = build_plan(root, changed, run_all=args.all or no_base)
    if no_base:
        plan.reason = "no origin/main or main to compare against: every leg runs"

    if args.format == "plan":
        print("\n".join(plan_lines(plan)))
        return 0
    if not args.all:
        print("\n".join(summary(plan, source)), file=sys.stderr)
    print("\n".join(command_lines(plan)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
