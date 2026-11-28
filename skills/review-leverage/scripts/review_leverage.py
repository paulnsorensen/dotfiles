#!/usr/bin/env python3
"""Rank where a human reviews a diff first, and keep an outcome record.

Code sets every tier and rank. A model may explain an area, but its output is
an aid and never a gate. Policy is builtin plus an optional
`.review-leverage.toml` read only from the default branch, never from the
reviewed head.

Subcommands: rank, record, close, outcomes.
Exit codes: 0 ok, 2 bad input, 3 walked area undecided, 4 head moved.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCHEMA = 1
POLICY_FILE = ".review-leverage.toml"
DECISIONS = ("ok", "fix", "block", "defer")
FLOOR = frozenset({"gate-mute", "test-oracle"})
MAX_REASONS = 6

# category -> (tier, base score). The tier comes from the category only.
CATEGORIES: dict[str, tuple[str, int]] = {
    "gate-mute": ("must", 100),
    "test-oracle": ("must", 90),
    "auth-security": ("must", 85),
    "schema-breaking": ("must", 80),
    "api-breaking": ("must", 70),
    "policy-must": ("must", 65),
    "test-added": ("should", 50),
    "api-change": ("should", 45),
    "schema-additive": ("should", 40),
    "agent-config": ("should", 35),
    "hotspot": ("should", 30),
    "low-signal": ("skip", 0),
}

BUILTIN_POLICY: dict[str, Any] = {
    "should_budget": 3,
    "paths": {
        "gate-mute": [
            POLICY_FILE,
            "**/review-leverage/**",
            "**/slices.toml",
            "**/*baseline*",
            ".github/workflows/**",
            ".github/rulesets/**",
            "**/CODEOWNERS",
            ".pre-commit-config.yaml",
            "**/prek.toml",
            "lefthook.y*ml",
            "**/.markdownlint*",
            "**/.eslintrc*",
            "**/eslint.config.*",
            "**/.eslintignore",
            "**/ruff.toml",
            "**/.ruff.toml",
            "**/setup.cfg",
            "**/tox.ini",
            "**/pytest.ini",
            "**/.coveragerc",
            "**/codecov.y*ml",
            "**/.codecov.y*ml",
            "**/.shellcheckrc",
            "**/.semgrepignore",
            "**/.semgrep.y*ml",
            "**/.gitleaks*",
            "**/.trivyignore",
            "**/deny.toml",
            "**/clippy.toml",
            "**/mutants.toml",
            "**/stryker.conf.*",
            "**/.dependency-cruiser.*",
            "**/tach.toml",
            "**/.go-arch-lint.y*ml",
            "**/.golangci.y*ml",
            "**/mypy.ini",
            "**/pyrightconfig.json",
            "**/.coderabbit.y*ml",
            "justfile",
            "Justfile",
            "Makefile",
        ],
        "test": [
            "tests/**",
            "test/**",
            "spec/**",
            "**/tests/**",
            "**/test/**",
            "**/__tests__/**",
            "**/__snapshots__/**",
            "**/*.snap",
            "**/*_test.*",
            "**/test_*.py",
            "**/conftest.py",
            "**/*.test.*",
            "**/*.spec.*",
            "**/*.bats",
            "**/testdata/**",
            "**/*.feature",
            "**/acceptance/**",
        ],
        "auth-security": [".env*", "**/secrets/**", "**/*.pem"],
        "schema": [
            "**/migrations/**",
            "**/migrate/**",
            "**/*.sql",
            "**/schema.*",
            "**/schema/**",
            "**/*.schema.json",
            "**/*.proto",
            "**/openapi*.y*ml",
            "**/openapi*.json",
            "**/swagger*.y*ml",
            "**/*.graphql",
            "**/*.avsc",
        ],
        "api": [
            "**/__init__.py",
            "**/index.ts",
            "**/index.js",
            "**/mod.rs",
            "**/lib.rs",
            "**/*.d.ts",
            "**/api/**",
            "bin/*",
            "**/cmd/**",
            "**/package.json",
            "**/Cargo.toml",
            "**/pyproject.toml",
            "**/go.mod",
        ],
        "agent-config": [
            "**/AGENTS.md",
            "**/CLAUDE.md",
            "**/SKILL.md",
            "**/skills/**",
            ".claude/**",
            ".codex/**",
            ".cursor/**",
            ".agents/**",
            "**/.cursorrules",
            ".github/copilot-instructions.md",
            "**/.mcp.json",
        ],
    },
    "must_paths": [],
    "skip_paths": [
        "**/*.lock",
        "**/package-lock.json",
        "**/pnpm-lock.yaml",
        "**/go.sum",
        "**/CHANGELOG.md",
        ".hallouminate/wiki/**",
        "docs/**",
    ],
}

AUTH_PATH_RE = re.compile(
    r"(^|[/_.-])(auth|authn|authz|authentication|authorization|login|logout|"
    r"oauth\w*|jwt|secrets?|credentials?|passwords?|passwd|crypto\w*|acl|rbac|"
    r"sudoers?|vault|keychain|csrf)([/_.-]|$)",
    re.IGNORECASE,
)
AUTH_LINE_RE = re.compile(
    r"shell\s*=\s*True|\beval\s*\(|verify\s*=\s*False|chmod\s+(-R\s+)?777|"
    r"curl[^|\n]*\|\s*(ba|z)?sh\b|dangerously|bypassPermissions|"
    r"NODE_TLS_REJECT_UNAUTHORIZED|StrictHostKeyChecking\W+no|"
    r"pull_request_target|write-all|allowed_non_write_users",
    re.IGNORECASE,
)
MUTE_LINE_RE = re.compile(
    r"#\s*noqa|eslint-disable|@ts-(ignore|expect-error|nocheck)|"
    r"#\s*type:\s*ignore|#!?\[allow\(|shellcheck\s+disable|//\s*nolint|"
    r"pragma:\s*no\s*cover|markdownlint-disable|--no-verify|"
    r"continue-on-error:\s*true|pylint:\s*disable|rubocop:disable|\bnosec\b|"
    r"NOSONAR|@SuppressWarnings|istanbul ignore|c8 ignore|mutants::skip",
)
ASSERT_RE = re.compile(
    r"\b(assert\w*|expect\w*|refute\w*|must_\w+|XCTAssert\w*)\b|\.should\b|"
    r"\bt\.(Error|Fatal|Fail)\w*|\brequire\.\w+|^\s*\[\[?\s|^\s*(Then|And)\s",
)
SKIP_RE = re.compile(
    r"@pytest\.mark\.(skip|xfail)|pytest\.skip\(|unittest\.skip|^\s*skip\b|"
    r"\.(skip|only|todo)\(|\b(xit|xdescribe|fit|fdescribe)\(|t\.Skip|"
    r"#\[ignore\]|@(Disabled|Ignore)\b|@skip\b",
)
TEST_CASE_RE = re.compile(
    r"^\s*(def test_\w+|async def test_\w+|@test\s|it\(|test\(|func Test\w+|"
    r"#\[test\]|Scenario:)"
)
SIGNATURE_RE = re.compile(
    r"^\s*(pub(\([\w:]+\))?\s+(async\s+)?(fn|struct|enum|trait|type|const|mod)\b|"
    r"export\s+(default\s+)?(async\s+)?(function|class|const|let|interface|type|enum)\b|"
    r"(async\s+)?def\s+[A-Za-z]\w*\s*\(|class\s+[A-Z]\w*|"
    r"func\s+(\([^)]*\)\s*)?[A-Z]\w*\s*\(|public\s+[\w<>\[\], ]+\s+\w+\s*\()"
)
# Shell functions are an interface only in a sourced library.
SHELL_FN_RE = re.compile(r"^\s*(function\s+)?[a-z][\w:-]*\s*\(\)\s*\{")
SHELL_LIB_RE = re.compile(r"(^|/)lib/|lib[\w.-]*\.(sh|bash|zsh)$|\.(bash|zsh)$")
SCHEMA_BREAK_RE = re.compile(
    r"\b(DROP|RENAME|TRUNCATE|DELETE\s+FROM|ALTER\s+COLUMN)\b", re.IGNORECASE
)
ESCAPE_RE = re.compile(
    r"\b(revert\w*|fix\w*|hotfix|bugfix|regress\w*|rollback|roll back)\b",
    re.IGNORECASE,
)


class UsageError(Exception):
    """Bad input: exit 2."""


# --- git and gh -------------------------------------------------------------


def _run(cmd: list[str], cwd: Path, check: bool = True) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    if check and proc.returncode != 0:
        raise UsageError(f"{' '.join(cmd[:3])} failed: {proc.stderr.strip()[:300]}")
    return proc.stdout


def _git(repo: Path, *args: str, check: bool = True) -> str:
    return _run(["git", *args], repo, check)


def _toplevel(path: Path) -> Path:
    return Path(_git(path, "rev-parse", "--show-toplevel").strip())


def _default_ref(repo: Path) -> str:
    out = _git(
        repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", check=False
    ).strip()
    if out:
        return out
    for cand in ("origin/main", "origin/master"):
        if _git(repo, "rev-parse", "--verify", "--quiet", cand, check=False).strip():
            return cand
    raise UsageError("cannot find the default branch (origin/HEAD, origin/main)")


def _repo_id(repo: Path) -> str:
    url = _git(repo, "remote", "get-url", "origin", check=False).strip()
    m = re.search(r"[:/]([^/:]+/[^/]+?)(\.git)?/?$", url)
    return m.group(1) if m else repo.name


def _pr_meta(repo: Path, pr: str) -> dict[str, Any]:
    if not shutil.which("gh"):
        raise UsageError("--pr needs the gh CLI on PATH")
    fields = "number,url,headRefOid,baseRefName,title,state"
    data = json.loads(_run(["gh", "pr", "view", pr, "--json", fields], repo))
    _git(repo, "fetch", "--quiet", "origin", f"pull/{data['number']}/head")
    _git(repo, "fetch", "--quiet", "origin", data["baseRefName"])
    return data


# --- policy -----------------------------------------------------------------


def _glob_re(pattern: str) -> re.Pattern[str]:
    anchored = "/" in pattern.rstrip("/")
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
            continue
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        out.append({"*": "[^/]*", "?": "[^/]"}.get(c, re.escape(c)))
        i += 1
    body = "".join(out)
    return re.compile(body + "$" if anchored else "(?:.*/)?" + body + "$")


def _matches(path: str, patterns: list[str]) -> str | None:
    for pat in patterns:
        if _glob_re(pat).match(path):
            return pat
    return None


def _str_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise UsageError(f"policy {label} must be a list of strings")
    return value


def load_policy(repo: Path, default_ref: str) -> tuple[dict[str, Any], str]:
    """Merge builtin policy with the default-branch policy file, append-only."""
    policy = json.loads(json.dumps(BUILTIN_POLICY))
    spec = f"{default_ref}:{POLICY_FILE}"
    blob = _git(repo, "rev-parse", "--verify", "--quiet", spec, check=False).strip()
    if not blob:
        return policy, "builtin"
    try:
        repo_policy = tomllib.loads(_git(repo, "show", spec))
    except tomllib.TOMLDecodeError as exc:
        raise UsageError(f"{spec} is not valid TOML: {exc}") from exc
    known = {"should_budget", "paths", "must_paths", "skip_paths"}
    unknown = set(repo_policy) - known
    if unknown:
        raise UsageError(f"{spec} has unknown keys: {sorted(unknown)}")
    if "should_budget" in repo_policy:
        budget = repo_policy["should_budget"]
        if not isinstance(budget, int) or not 0 <= budget <= 20:
            raise UsageError("policy should_budget must be an integer 0..20")
        policy["should_budget"] = budget
    for key in ("must_paths", "skip_paths"):
        policy[key] += _str_list(repo_policy.get(key, []), key)
    paths = repo_policy.get("paths", {})
    if not isinstance(paths, dict):
        raise UsageError("policy paths must be a table")
    for key, globs in paths.items():
        if key not in policy["paths"]:
            raise UsageError(f"policy paths.{key} is not a known path group")
        policy["paths"][key] += _str_list(globs, f"paths.{key}")
    return policy, f"builtin+{spec}@{blob[:12]}"


# --- diff parsing -----------------------------------------------------------


@dataclass
class FileDiff:
    path: str
    old_path: str | None = None
    status: str = "M"
    added: list[tuple[int, str]] = field(default_factory=list)
    removed: list[tuple[int, str]] = field(default_factory=list)
    binary: bool = False


HUNK_RE = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def parse_diff(text: str) -> list[FileDiff]:
    files: list[FileDiff] = []
    cur: FileDiff | None = None
    old_no = new_no = 0
    for line in text.splitlines():
        if line.startswith("diff --git "):
            m = re.match(r"diff --git a/(.*) b/(.*)$", line)
            cur = FileDiff(path=m.group(2) if m else line.split()[-1])
            files.append(cur)
            continue
        if cur is None:
            continue
        if line.startswith("new file mode"):
            cur.status = "A"
        elif line.startswith("deleted file mode"):
            cur.status = "D"
        elif line.startswith("rename from "):
            cur.old_path, cur.status = line[len("rename from ") :], "R"
        elif line.startswith("Binary files "):
            cur.binary = True
        elif m := HUNK_RE.match(line):
            old_no, new_no = int(m.group(1)), int(m.group(2))
        elif line.startswith("+") and not line.startswith("+++"):
            cur.added.append((new_no, line[1:]))
            new_no += 1
        elif line.startswith("-") and not line.startswith("---"):
            cur.removed.append((old_no, line[1:]))
            old_no += 1
    return files


# --- classification ---------------------------------------------------------


def _clip(text: str) -> str:
    text = text.strip()
    return text if len(text) <= 70 else text[:67] + "..."


def _hits(
    lines: list[tuple[int, str]], rx: re.Pattern[str], what: str, side: str
) -> list[str]:
    return [f"{what} at {side}:{n} `{_clip(t)}`" for n, t in lines if rx.search(t)]


def classify(fd: FileDiff, policy: dict[str, Any]) -> list[tuple[str, list[str]]]:
    """Return every (category, reasons) pair that fits one changed file."""
    paths = policy["paths"]
    path = fd.path
    found: list[tuple[str, list[str]]] = []

    if pat := _matches(path, paths["gate-mute"]):
        found.append(("gate-mute", [f"edits gate config (policy glob `{pat}`)"]))
    mutes = _hits(fd.added, MUTE_LINE_RE, "adds suppression", "new")
    if mutes:
        found.append(("gate-mute", mutes))

    if _matches(path, paths["test"]):
        weak = _hits(fd.removed, ASSERT_RE, "removes or rewrites assertion", "old")
        weak += _hits(fd.removed, TEST_CASE_RE, "removes test case", "old")
        weak += _hits(fd.added, SKIP_RE, "adds skip marker", "new")
        if (path.endswith(".snap") or "__snapshots__/" in path) and fd.removed:
            weak.append(f"rewrites snapshot ({len(fd.removed)} lines removed)")
        if fd.status == "D":
            weak.append("deletes test file")
        if weak:
            found.append(("test-oracle", weak))
        else:
            found.append(
                (
                    "test-added",
                    [f"adds {len(fd.added)} test lines; author wrote the oracle"],
                )
            )

    auth = []
    if AUTH_PATH_RE.search(path) or _matches(path, paths["auth-security"]):
        auth.append("path names an auth or security concern")
    auth += _hits(fd.added, AUTH_LINE_RE, "adds risky construct", "new")
    if auth:
        found.append(("auth-security", auth))

    if _matches(path, paths["schema"]):
        brk = _hits(fd.added, SCHEMA_BREAK_RE, "destructive statement", "new")
        real_removed = [r for r in fd.removed if r[1].strip()]
        if real_removed:
            brk.append(f"removes {len(real_removed)} schema lines")
        if brk:
            found.append(("schema-breaking", brk))
        else:
            found.append(("schema-additive", ["additive schema or migration change"]))

    sig_rx = SIGNATURE_RE
    if SHELL_LIB_RE.search(path):
        sig_rx = re.compile(f"{SIGNATURE_RE.pattern}|{SHELL_FN_RE.pattern}")
    added_text = {t.strip() for _, t in fd.added}
    gone = [(n, t) for n, t in fd.removed if t.strip() not in added_text]
    removed_sigs = _hits(gone, sig_rx, "removes or changes signature", "old")
    if removed_sigs and fd.status != "A":
        found.append(("api-breaking", removed_sigs))
    else:
        api = _hits(fd.added, sig_rx, "adds public signature", "new")
        if _matches(path, paths["api"]):
            api.insert(0, "edits a module entry point or manifest")
        if api:
            found.append(("api-change", api))

    if pat := _matches(path, policy["must_paths"]):
        found.append(("policy-must", [f"repo policy must_paths `{pat}`"]))

    if _matches(path, paths["agent-config"]):
        found.append(("agent-config", ["edits agent instructions or skills"]))
    return found


def _risk(repo: Path, files: list[str]) -> tuple[dict[str, dict[str, Any]], str]:
    if os.environ.get("REVIEW_LEVERAGE_RISK", "on") == "off":
        return {}, "off"
    tool = shutil.which("git-file-risk")
    live = [f for f in files if (repo / f).exists()]
    if not tool or not live:
        return {}, "unavailable" if not tool else "no files"
    proc = subprocess.run(
        [tool, *live], cwd=repo, capture_output=True, text=True, check=False
    )
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}, "unreadable"
    return {r["file"]: r for r in rows if "error" not in r}, "git-file-risk"


def _band(row: dict[str, Any] | None) -> str | None:
    if not row:
        return None
    hot = row.get("authors_90d", 0) >= 4 and row.get("changes_90d", 0) >= 8
    if hot or row.get("reverts", 0) >= 1:
        return "high"
    if (
        row.get("authors_90d", 0) >= 4
        or row.get("changes_90d", 0) >= 8
        or row.get("last_change_days", 999) < 14
    ):
        return "elevated"
    return None


def build_areas(
    diffs: list[FileDiff],
    policy: dict[str, Any],
    risk: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], dict[str, Any]] = {}
    for fd in diffs:
        found = classify(fd, policy)
        band = _band(risk.get(fd.path))
        size = len(fd.added) + len(fd.removed)
        if not found:
            if band == "high":
                found = [("hotspot", ["git-file-risk band high"])]
            else:
                skip = _matches(fd.path, policy["skip_paths"])
                why = f"policy skip_paths `{skip}`" if skip else "no leverage signal"
                found = [("low-signal", [why])]
        cat = max(found, key=lambda f: CATEGORIES[f[0]][1])[0]
        skip_pat = _matches(fd.path, policy["skip_paths"])
        if skip_pat and cat not in FLOOR:
            found = [("low-signal", [f"policy skip_paths `{skip_pat}`"])]
            cat = "low-signal"
        reasons = [r for c, rs in found if c == cat for r in rs]
        reasons += [f"also {c}" for c, _ in found if c != cat]
        if band and cat != "low-signal":
            reasons.append(f"git-file-risk band {band}")
        directory = fd.path.rsplit("/", 1)[0] if "/" in fd.path else "."
        area = groups.setdefault(
            (cat, directory),
            {
                "category": cat,
                "dir": directory,
                "files": [],
                "reasons": [],
                "lines": 0,
                "bonus": 0,
            },
        )
        area["files"].append(fd.path)
        area["reasons"] += [f"{fd.path}: {r}" for r in reasons]
        area["lines"] += size
        area["bonus"] = max(
            area["bonus"], {"high": 15, "elevated": 5}.get(band or "", 0)
        )
    areas = []
    for (cat, _), a in groups.items():
        tier, base = CATEGORIES[cat]
        score = (
            base + a.pop("bonus") + min(10, a["lines"] // 40) if tier != "skip" else 0
        )
        extra = len(a["reasons"]) - MAX_REASONS
        a["reasons"] = a["reasons"][:MAX_REASONS] + (
            [f"(+{extra} more)"] if extra > 0 else []
        )
        areas.append({**a, "tier": tier, "score": score})
    order = {"must": 0, "should": 1, "skip": 2}
    areas.sort(key=lambda a: (order[a["tier"]], -a["score"], a["dir"]))
    for i, a in enumerate(areas, 1):
        a["id"] = f"A{i}"
    return areas


def select_walk(
    areas: list[dict[str, Any]], budget: int
) -> tuple[list[str], list[dict[str, str]]]:
    walk, skipped, should_seen = [], [], 0
    for a in areas:
        if a["tier"] == "must":
            walk.append(a["id"])
        elif a["tier"] == "should" and should_seen < budget:
            should_seen += 1
            walk.append(a["id"])
        elif a["tier"] == "should":
            skipped.append(
                {
                    "id": a["id"],
                    "reason": f"should tier beyond budget {budget} (score {a['score']})",
                }
            )
        else:
            skipped.append(
                {
                    "id": a["id"],
                    "reason": f"skip tier: {a['reasons'][0].split(': ', 1)[-1]}",
                }
            )
    return walk, skipped


# --- state ------------------------------------------------------------------


def _home() -> Path:
    base = os.environ.get("REVIEW_LEVERAGE_HOME")
    return Path(base) if base else Path.home() / ".local/share/review-leverage"


def _now() -> str:
    return dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_run(path: str) -> dict[str, Any]:
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise UsageError(f"cannot read run file {path}: {exc}") from exc


def _save_run(run: dict[str, Any]) -> None:
    Path(run["run_file"]).write_text(json.dumps(run, indent=2) + "\n")


def _append_ledger(entry: dict[str, Any]) -> None:
    ledger = _home() / "ledger.jsonl"
    ledger.parent.mkdir(parents=True, exist_ok=True)
    with ledger.open("a") as fh:
        fh.write(json.dumps(entry, sort_keys=True) + "\n")


def _entry(
    run: dict[str, Any], area: dict[str, Any], decision: str, **extra: Any
) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "ts": _now(),
        "repo": run["repo"],
        "pr": run.get("pr"),
        "base_sha": run["base_sha"],
        "head_sha": run["head_sha"],
        "policy": run["policy"],
        "area": area["id"],
        "category": area["category"],
        "tier": area["tier"],
        "files": area["files"],
        "decision": decision,
        "reviewer": os.environ.get("USER", "unknown"),
        **extra,
    }


# --- commands ---------------------------------------------------------------


def cmd_rank(args: argparse.Namespace) -> int:
    repo = _toplevel(Path(args.repo))
    default_ref = _default_ref(repo)
    pr = None
    if args.pr:
        meta = _pr_meta(repo, args.pr)
        pr, head, base_ref = (
            meta["number"],
            meta["headRefOid"],
            f"origin/{meta['baseRefName']}",
        )
    else:
        head = _git(repo, "rev-parse", args.head).strip()
        base_ref = args.base or default_ref
    base_sha = _git(repo, "merge-base", base_ref, head).strip()
    text = _git(
        repo,
        "diff",
        "--no-color",
        "--no-ext-diff",
        "-U0",
        "--find-renames",
        base_sha,
        head,
    )
    diffs = parse_diff(text)
    if not diffs:
        raise UsageError(f"no changes between {base_ref} and {head[:12]}")
    policy, policy_src = load_policy(repo, default_ref)
    risk, risk_src = _risk(repo, [d.path for d in diffs])
    areas = build_areas(diffs, policy, risk)
    walk, skipped = select_walk(areas, policy["should_budget"])
    runs = _home() / "runs" / _repo_id(repo).replace("/", "__")
    runs.mkdir(parents=True, exist_ok=True)
    run_file = runs / f"{f'pr{pr}' if pr else 'branch'}-{head[:12]}.json"
    run = {
        "schema": SCHEMA,
        "created": _now(),
        "repo": _repo_id(repo),
        "repo_path": str(repo),
        "pr": pr,
        "base_ref": base_ref,
        "base_sha": base_sha,
        "head_sha": head,
        "policy": policy_src,
        "should_budget": policy["should_budget"],
        "risk_source": risk_src,
        "areas": areas,
        "walk": walk,
        "skipped": skipped,
        "decisions": {},
        "closed": False,
        "run_file": str(run_file),
    }
    _save_run(run)
    if args.json:
        print(json.dumps(run, indent=2))
        return 0
    print(f"run: {run_file}")
    print(
        f"head: {head[:12]}  base: {base_ref}@{base_sha[:12]}  policy: {policy_src}  risk: {risk_src}"
    )
    tiers = {t: sum(a["tier"] == t for a in areas) for t in ("must", "should", "skip")}
    print(
        f"areas: {len(areas)} (must {tiers['must']}, should {tiers['should']}, skip {tiers['skip']}); walk {len(walk)}, skipped {len(skipped)}"
    )
    by_id = {a["id"]: a for a in areas}
    for aid in walk:
        a = by_id[aid]
        print(
            f"  {aid} {a['tier']:6} {a['score']:3} {a['category']:15} {a['dir']} ({len(a['files'])} files)"
        )
    return 0


def _area(run: dict[str, Any], area_id: str) -> dict[str, Any]:
    for a in run["areas"]:
        if a["id"] == area_id:
            return a
    raise UsageError(f"area {area_id} is not in the run")


def cmd_record(args: argparse.Namespace) -> int:
    run = _load_run(args.run)
    if run["closed"]:
        raise UsageError("run is closed; rank again to review a new head")
    if args.decision not in DECISIONS:
        raise UsageError(f"decision must be one of {', '.join(DECISIONS)}")
    area = _area(run, args.area)
    entry = _entry(run, area, args.decision, note=args.note or "")
    _append_ledger(entry)
    run["decisions"][area["id"]] = {
        "decision": args.decision,
        "note": args.note or "",
        "ts": entry["ts"],
    }
    _save_run(run)
    print(f"recorded {area['id']} {args.decision} @ {run['head_sha'][:12]}")
    return 0


def cmd_close(args: argparse.Namespace) -> int:
    run = _load_run(args.run)
    if run["closed"]:
        print("run already closed")
        return 0
    if run.get("pr") and shutil.which("gh"):
        live = _run(
            [
                "gh",
                "pr",
                "view",
                str(run["pr"]),
                "--json",
                "headRefOid",
                "--jq",
                ".headRefOid",
            ],
            Path(run["repo_path"]),
            check=False,
        ).strip()
        if live and live != run["head_sha"]:
            print(
                f"head moved: reviewed {run['head_sha'][:12]}, PR now {live[:12]}; rank again",
                file=sys.stderr,
            )
            return 4
    open_ids = [aid for aid in run["walk"] if aid not in run["decisions"]]
    if open_ids:
        print(f"undecided walked areas: {', '.join(open_ids)}", file=sys.stderr)
        return 3
    for skip in run["skipped"]:
        if skip["id"] in run["decisions"]:
            continue
        _append_ledger(
            _entry(run, _area(run, skip["id"]), "skipped", reason=skip["reason"])
        )
    run["closed"] = True
    _save_run(run)
    counts: dict[str, int] = {}
    for d in run["decisions"].values():
        counts[d["decision"]] = counts.get(d["decision"], 0) + 1
    summary = ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))
    print(f"closed @ {run['head_sha'][:12]}: {summary}; skipped {len(run['skipped'])}")
    for skip in run["skipped"]:
        print(
            f"  skipped {skip['id']} {_area(run, skip['id'])['dir']}: {skip['reason']}"
        )
    return 0


def cmd_outcomes(args: argparse.Namespace) -> int:
    repo = _toplevel(Path(args.repo))
    repo_id = _repo_id(repo)
    ledger = _home() / "ledger.jsonl"
    entries = []
    if ledger.exists():
        for line in ledger.read_text().splitlines():
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("repo") == repo_id:
                entries.append(e)
    cutoff = dt.datetime.now(dt.UTC) - dt.timedelta(days=args.days)
    entries = [e for e in entries if dt.datetime.fromisoformat(e["ts"]) >= cutoff]
    if not entries:
        print(
            json.dumps([])
            if args.json
            else f"no ledger entries for {repo_id} in {args.days} days"
        )
        return 0
    ref = _default_ref(repo)
    since = min(e["ts"] for e in entries)
    log = _git(
        repo,
        "log",
        ref,
        f"--since={since}",
        "--format=@@%H%x09%ct%x09%s",
        "--name-only",
    )
    commits, cur = [], None
    for line in log.splitlines():
        if line.startswith("@@"):
            sha, ct, subject = line[2:].split("\t", 2)
            cur = {"sha": sha, "ct": int(ct), "subject": subject, "files": set()}
            commits.append(cur)
        elif line.strip() and cur:
            cur["files"].add(line.strip())
    matches = []
    for e in entries:
        ts = dt.datetime.fromisoformat(e["ts"]).timestamp()
        own = f"(#{e['pr']})" if e.get("pr") else None
        for c in commits:
            if c["ct"] < ts or not ESCAPE_RE.search(c["subject"]):
                continue
            if own and own in c["subject"]:
                continue
            hit = sorted(c["files"] & set(e["files"]))
            if hit:
                matches.append(
                    {
                        "area": e["area"],
                        "category": e["category"],
                        "tier": e["tier"],
                        "decision": e["decision"],
                        "pr": e.get("pr"),
                        "head_sha": e["head_sha"],
                        "later_sha": c["sha"],
                        "later_subject": c["subject"],
                        "files": hit,
                    }
                )
    if args.json:
        print(json.dumps(matches, indent=2))
        return 0
    print(
        f"{len(entries)} ledger entries, {len(matches)} later revert/fix matches (weak label: subject keyword + file overlap)"
    )
    for m in matches:
        print(
            f"  PR {m['pr']} {m['area']} {m['tier']}/{m['decision']} @ {m['head_sha'][:12]} <- {m['later_sha'][:12]} {m['later_subject']}"
        )
    return 0


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="review-leverage", description=__doc__.splitlines()[0]
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("rank", help="rank review areas of a PR or branch")
    r.add_argument("--pr", help="PR number or URL (needs gh)")
    r.add_argument("--base", help="base ref (default: origin default branch)")
    r.add_argument("--head", default="HEAD", help="head ref (default: HEAD)")
    r.add_argument("--repo", default=".", help="repository path")
    r.add_argument("--json", action="store_true", help="print the full run as JSON")
    r.set_defaults(func=cmd_rank)
    rec = sub.add_parser("record", help="record one human decision")
    rec.add_argument("--run", required=True)
    rec.add_argument("--area", required=True)
    rec.add_argument("--decision", required=True)
    rec.add_argument("--note")
    rec.set_defaults(func=cmd_record)
    c = sub.add_parser("close", help="record skipped areas and close the run")
    c.add_argument("--run", required=True)
    c.set_defaults(func=cmd_close)
    o = sub.add_parser(
        "outcomes", help="match ledger entries to later reverts and fixes"
    )
    o.add_argument("--repo", default=".")
    o.add_argument("--days", type=int, default=90)
    o.add_argument("--json", action="store_true")
    o.set_defaults(func=cmd_outcomes)
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return args.func(args)
    except UsageError as exc:
        print(f"review-leverage: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
