#!/usr/bin/env python3
"""bash-shorten — apply high-confidence rewrites from the bash-shortening skill.

ast-grep (`sg`) is a hard requirement. Structural patterns route through
ast-grep first using the rule pack at scripts/sg-rules/; remaining
regex-only rules run after. If `sg` is not on PATH, the script exits
with a friendly diagnostic — load the bash-shortening skill in whatever
agent harness you're in and apply the methodology by hand, or install
ast-grep:

  brew install ast-grep        # macOS / Linuxbrew
  cargo install ast-grep --bin sg

One opt-in extension:

- --include modernize : enable the off-by-default modernize rule group
  that suggests sd/rg in place of sed/grep for the most literal cases.
  Requires the target binary to be installed for the rewritten code to
  actually run.

Defaults to dry-run (prints a unified diff). Pass --apply to write.

  bash-shorten script.sh                            # dry-run, prints diff
  bash-shorten --apply script.sh                    # rewrite in place (atomic)
  bash-shorten --rules backticks,test-numeric script.sh
  bash-shorten --skip backticks script.sh
  bash-shorten --include modernize --apply file.sh  # also rewrite sed→sd, grep→rg
  bash-shorten --list                               # list all rules with examples
  bash-shorten --explain test-numeric               # show one rule in detail
  bash-shorten --self-test                          # run the embedded fixtures
  cat script.sh | bash-shorten -                    # stdin → stdout (no diff)

Opt-out directive (shellcheck-style). Mark regions the rewriter must leave
alone with a comment line — covers every rule. The keyword must be the whole
comment (trailing text is ignored), so write each directive on its own line:

  # bash-shorten: disable
  # bash-shorten: enable
  # bash-shorten: skip

`disable` starts a block left verbatim (omit `enable` to protect to EOF);
`enable` ends it; `skip` no-ops only the next line.

Always run `shellcheck` on the output. These rules are conservative but
not infallible; quoting edge cases at the boundary of regex matches can
still slip through. The script does not invoke shellcheck for you.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# rules.py and engine.py live next to this script; running
# `python3 bash-shorten.py` adds the script's directory to sys.path so
# the imports resolve. The pyright suppressions are for static analysis,
# which can't follow the sys.path tweak; the imports work at runtime and
# are exercised by the self-test and bats suite.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from engine import _sg_available, apply_rules, atomic_write, diff  # type: ignore[import-not-found]  # noqa: E402
from rules import KNOWN_GROUPS, RULES, RULES_BY_ID  # type: ignore[import-not-found]  # noqa: E402

# This module is a CLI script. Nothing here is part of a stable public
# API — invoke via `python3 bash-shorten.py` or the wrapper, not by
# importing internals. The bats suite only goes through the CLI.
__all__: list[str] = []


# --- Self-test ------------------------------------------------------------

# Negative cases — must round-trip unchanged through apply_rules.
_NEGATIVE_CASES: tuple[str, ...] = (
    # sed with regex metachars must not be touched
    "X=$(echo \"$S\" | sed 's/.*/x/')",
    "X=$(echo \"$S\" | sed 's/[abc]/x/')",
    # sed pattern with a `.` (regex metachar in sed, literal in bash glob)
    # must not be rewritten — semantics differ.
    "X=$(echo \"$S\" | sed 's/foo.bar/x/')",
    # combined-tests with nested brackets in arg must not be touched
    '[ "${arr[0]}" = "x" ] && [ "$Y" = "y" ]',
    # mkdir-guard with a different var inside must not be touched
    'if [ ! -d "$A" ]; then mkdir -p "$B"; fi',
    # backticks inside single-quoted strings stay literal — they are not
    # command substitution in bash and rewriting them would change the
    # string's bytes.
    "echo 'literal `text` here'",
    # backticks inside a quoted heredoc body are literal — bash leaves
    # <<'EOF' / <<"EOF" bodies uninterpreted, so the rewriter must skip.
    "cat <<'EOF'\nThis has `text` in it.\nEOF\n",
    # find -exec rm -r must NOT collapse to -delete: rm -r removes
    # non-empty dirs while find -delete refuses them without -depth.
    'find . -type d -exec rm -r {} \\;',
    # bash-shorten: disable/enable opts a region out of every rule (issue
    # #59). Lines between the directives are copied verbatim — here the
    # backtick command substitution survives untouched.
    "# bash-shorten: disable\nV=`pwd`\n# bash-shorten: enable\n",
    # bash-shorten: skip no-ops the single following line.
    "# bash-shorten: skip\nV=`pwd`\n",
)

# Custom positive tests for cat-file-pipe-grep (which has no static .examples)
_CAT_GREP_CASES: tuple[tuple[str, str], ...] = (
    ("cat /etc/hosts | grep localhost", "grep localhost /etc/hosts"),
    ("cat \"$LOG\" | grep -i error", "grep -i error \"$LOG\""),
)


def _check_fixture(
    label: str,
    src: str,
    want: str,
    all_ids: set[str],
) -> str | None:
    got, _ = apply_rules(src, all_ids)
    if got == want:
        return None
    return (
        f"[{label}] case failed\n"
        f"  input:    {src!r}\n"
        f"  expected: {want!r}\n"
        f"  got:      {got!r}"
    )


def self_test() -> int:
    all_ids = {r.id for r in RULES}
    cases: list[tuple[str, str, str]] = []
    for rule in RULES:
        cases.extend((rule.id, src, want) for src, want in rule.examples)
    cases.extend(("negative", src, src) for src in _NEGATIVE_CASES)
    cases.extend(("cat-file-pipe-grep", src, want) for src, want in _CAT_GREP_CASES)

    failures = [
        f for label, src, want in cases
        if (f := _check_fixture(label, src, want, all_ids)) is not None
    ]

    print(f"self-test: {len(cases) - len(failures)}/{len(cases)} passed")
    for f in failures:
        print(f"\nFAIL {f}", file=sys.stderr)
    return 0 if not failures else 1


# --- CLI ------------------------------------------------------------------


def _resolve_enabled(
    only: str | None,
    skip: str | None,
    include: str | None,
) -> set[str]:
    if only:
        ids = {s.strip() for s in only.split(",") if s.strip()}
        unknown = ids - set(RULES_BY_ID)
        if unknown:
            sys.exit(f"unknown rules: {', '.join(sorted(unknown))}")
        return ids

    # Default: enable only the "core" group. --include adds opt-in groups.
    active_groups = {"core"}
    if include:
        extra = {g.strip() for g in include.split(",") if g.strip()}
        unknown_groups = extra - KNOWN_GROUPS
        if unknown_groups:
            sys.exit(
                f"unknown groups: {', '.join(sorted(unknown_groups))} "
                f"(known: {', '.join(sorted(KNOWN_GROUPS))})"
            )
        active_groups |= extra

    enabled = {r.id for r in RULES if r.group in active_groups}
    if skip:
        skipped = {s.strip() for s in skip.split(",") if s.strip()}
        unknown = skipped - set(RULES_BY_ID)
        if unknown:
            sys.exit(f"unknown rules: {', '.join(sorted(unknown))}")
        enabled -= skipped
    return enabled


def _list_rules() -> int:
    width = max(len(r.id) for r in RULES)
    for r in RULES:
        sc = f" [{r.shellcheck_id}]" if r.shellcheck_id else ""
        group_tag = "" if r.group == "core" else f" ({r.group})"
        print(
            f"  {r.id:<{width}}  ex {r.source_example:<3}  "
            f"{r.description}{sc}{group_tag}"
        )
    print()
    print(
        "Groups: "
        + ", ".join(
            f"{g} ({sum(1 for r in RULES if r.group == g)} rules)"
            for g in sorted(KNOWN_GROUPS)
        )
    )
    print(
        "Default group is 'core'. Enable others with --include "
        "(e.g. --include modernize)."
    )
    return 0


def _explain(rule_id: str) -> int:
    r = RULES_BY_ID.get(rule_id)
    if r is None:
        print(f"unknown rule: {rule_id}", file=sys.stderr)
        return 1
    print(f"id:             {r.id}")
    print(f"source example: {r.source_example}")
    if r.shellcheck_id:
        print(f"shellcheck:     {r.shellcheck_id}")
    print(f"description:    {r.description}")
    print(f"pattern:        {r.pattern.pattern}")
    if r.notes:
        print(f"notes:          {r.notes}")
    if r.examples:
        print("examples:")
        for src, want in r.examples:
            print(f"  - {src}")
            print(f"      → {want}")
    return 0


def _build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="bash-shorten",
        description="Apply high-confidence rewrites from the bash-shortening skill.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Defaults to dry-run (prints unified diff). Pass --apply to write back.\n"
            "Opt out regions with a '# bash-shorten: disable' / 'enable' block or\n"
            "'# bash-shorten: skip' for the next line.\n"
            "Always run shellcheck on the output."
        ),
    )
    ap.add_argument("file", nargs="?", help="bash script to rewrite (or '-' for stdin)")
    ap.add_argument("--apply", action="store_true", help="write the rewritten file in place")
    ap.add_argument("--rules", help="comma-separated rule IDs to apply (default: all in active groups)")
    ap.add_argument("--skip", help="comma-separated rule IDs to disable")
    ap.add_argument(
        "--include",
        help="comma-separated opt-in rule groups to enable (default: core only). "
             "Known: core, modernize.",
    )
    ap.add_argument("--list", action="store_true", help="list all rules and exit")
    ap.add_argument("--explain", metavar="ID", help="describe one rule and exit")
    ap.add_argument("--self-test", action="store_true", help="run embedded fixtures and exit")
    return ap


_SG_MISSING_DIAGNOSTIC = (
    "bash-shorten requires ast-grep (`sg`) on PATH.\n"
    "\n"
    "Install one of:\n"
    "  brew install ast-grep\n"
    "  cargo install ast-grep --bin sg\n"
    "\n"
    "Or skip the script entirely and follow the reference-driven\n"
    "methodology in skills/bash-shortening/SKILL.md — see its\n"
    "'Parallel sweep — worker contract' and 'Categories' sections for the\n"
    "per-category review workflow (no separate analyzer binary exists)."
)


def _run_stdin(enabled: set[str]) -> int:
    text = sys.stdin.read()
    new_text, counts = apply_rules(text, enabled)
    sys.stdout.write(new_text)
    for rid, n in counts.items():
        print(f"# applied {rid}: {n}", file=sys.stderr)
    return 0


def _run_file(path: Path, enabled: set[str], apply: bool) -> int:
    text = path.read_text(encoding="utf-8")
    new_text, counts = apply_rules(text, enabled)
    if not counts:
        print(f"{path}: no rewrites applicable", file=sys.stderr)
        return 0
    if apply:
        atomic_write(path, new_text)
        for rid, n in counts.items():
            print(f"{path}: applied {rid} ×{n}", file=sys.stderr)
        return 0
    print(diff(text, new_text, str(path)))
    print(file=sys.stderr)
    for rid, n in counts.items():
        print(f"# would apply {rid}: ×{n}", file=sys.stderr)
    print("# (dry-run — pass --apply to write)", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = _build_arg_parser()
    args = ap.parse_args(argv)

    if args.list:
        return _list_rules()
    if args.explain:
        return _explain(args.explain)
    if args.self_test:
        if not _sg_available():
            sys.exit(_SG_MISSING_DIAGNOSTIC)
        return self_test()
    if not args.file:
        ap.error("a file is required (or '-' for stdin)")

    if not _sg_available():
        sys.exit(_SG_MISSING_DIAGNOSTIC)

    enabled = _resolve_enabled(args.rules, args.skip, args.include)

    if args.file == "-":
        if args.apply:
            ap.error("--apply is incompatible with stdin")
        return _run_stdin(enabled)

    path = Path(args.file)
    if not path.is_file():
        sys.exit(f"not a file: {path}")
    return _run_file(path, enabled, args.apply)


if __name__ == "__main__":
    sys.exit(main())
