#!/usr/bin/env python3
"""Resolve conflict markers in a file by choosing ours or theirs per hunk.

Useful for file types mergiraf doesn't support (shell scripts, SQL, .gitignore,
Markdown) where the conflict is simple enough to resolve with a pick strategy
rather than a full structural merge.

Usage:
    python3 conflict-pick.py <file> --ours           # keep all our hunks
    python3 conflict-pick.py <file> --theirs          # keep all their hunks
    python3 conflict-pick.py <file> --interactive     # prompt per hunk
    python3 conflict-pick.py <file> --grep PATTERN --ours   # ours for matching hunks
    python3 conflict-pick.py <file> --grep PATTERN --theirs # theirs for matching hunks

After resolving, stage the file with: git add <file>
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from git_utils import has_conflict_markers

MARKER_OURS_RE = re.compile(r"^<<<<<<< (.+)$")
MARKER_BASE_RE = re.compile(r"^\|\|\|\|\|\|\| (.+)$")  # zdiff3 base marker
MARKER_SEP_RE = re.compile(r"^=======$")
MARKER_THEIRS_RE = re.compile(r"^>>>>>>> (.+)$")


def _collect_lines(lines, i, stop_check):
    collected = []
    while i < len(lines) and not stop_check(lines[i]):
        collected.append(lines[i])
        i += 1
    return collected, i


def _parse_one_conflict(lines, i):
    m = MARKER_OURS_RE.match(lines[i])
    if not m:
        return None, i + 1
    label_ours = m.group(1)
    i += 1

    ours_lines, i = _collect_lines(
        lines, i,
        lambda l: bool(MARKER_BASE_RE.match(l) or MARKER_SEP_RE.match(l)),
    )

    base_lines = None
    label_base = "base"
    if i < len(lines):
        mb = MARKER_BASE_RE.match(lines[i])
        if mb:
            label_base = mb.group(1)
            i += 1
            base_lines, i = _collect_lines(lines, i, lambda l: bool(MARKER_SEP_RE.match(l)))

    if i < len(lines) and MARKER_SEP_RE.match(lines[i]):
        i += 1

    theirs_lines, i = _collect_lines(lines, i, lambda l: bool(MARKER_THEIRS_RE.match(l)))

    label_theirs = "theirs"
    if i < len(lines):
        m2 = MARKER_THEIRS_RE.match(lines[i])
        if m2:
            label_theirs = m2.group(1)
        i += 1

    seg = {
        "type": "conflict",
        "ours": "".join(ours_lines),
        "base": "".join(base_lines) if base_lines is not None else None,
        "theirs": "".join(theirs_lines),
        "label_ours": label_ours,
        "label_theirs": label_theirs,
        "label_base": label_base,
    }
    return seg, i


def parse_hunks(text):
    segments = []
    lines = text.splitlines(keepends=True)
    i = 0

    while i < len(lines):
        if not MARKER_OURS_RE.match(lines[i]):
            start = i
            while i < len(lines) and not MARKER_OURS_RE.match(lines[i]):
                i += 1
            segments.append({"type": "clean", "content": "".join(lines[start:i])})
            continue

        seg, i = _parse_one_conflict(lines, i)
        if seg is not None:
            segments.append(seg)

    return segments


def _resolve_hunk(seg, strategy, grep_pattern):
    ours = seg["ours"]
    theirs = seg["theirs"]

    if grep_pattern:
        combined = ours + theirs
        if not re.search(grep_pattern, combined, re.MULTILINE):
            return None  # pattern doesn't match — keep conflict

    if strategy == "interactive":
        choice = _prompt_interactive(seg)
        if choice == "o":
            return ours
        elif choice == "t":
            return theirs
        elif choice == "b" and seg["base"] is not None:
            return seg["base"]
        return None  # skipped

    if strategy == "ours":
        return ours
    if strategy == "theirs":
        return theirs
    return None


def apply_strategy(segments, strategy, grep_pattern=None):
    output = []
    conflict_count = 0
    resolved_count = 0

    for seg in segments:
        if seg["type"] == "clean":
            output.append(seg["content"])
            continue

        conflict_count += 1
        resolved = _resolve_hunk(seg, strategy, grep_pattern)
        if resolved is not None:
            output.append(resolved)
            resolved_count += 1
        else:
            output.append(_format_conflict(seg))

    return "".join(output), conflict_count, resolved_count


def _format_conflict(seg):
    parts = [f"<<<<<<< {seg['label_ours']}\n", seg["ours"]]
    if seg["base"] is not None:
        parts.append(f"||||||| {seg.get('label_base', 'base')}\n{seg['base']}")
    parts.append("=======\n")
    parts.append(seg["theirs"])
    parts.append(f">>>>>>> {seg['label_theirs']}\n")
    return "".join(parts)


def _prompt_interactive(seg):
    print(f"\n--- Conflict hunk ---")
    print(f"OURS ({seg['label_ours']}):")
    for line in seg["ours"].splitlines():
        print(f"  + {line}")
    print(f"THEIRS ({seg['label_theirs']}):")
    for line in seg["theirs"].splitlines():
        print(f"  - {line}")
    if seg["base"] is not None:
        print(f"BASE:")
        for line in seg["base"].splitlines():
            print(f"  ~ {line}")

    prompt = "(o)urs / (t)heirs"
    if seg["base"] is not None:
        prompt += " / (b)ase"
    prompt += " / (s)kip: "

    while True:
        choice = input(prompt).strip().lower()
        if choice in ("o", "t", "s") or (choice == "b" and seg["base"] is not None):
            return choice
        print("Please enter o, t, s" + (", or b" if seg["base"] else ""))


def _write_and_stage(filepath, resolved, remaining, no_add):
    import subprocess
    with open(filepath, "w") as f:
        f.write(resolved)
    if remaining == 0 and not no_add:
        result = subprocess.run(["git", "add", "--", filepath], capture_output=True, text=True)
        if result.returncode == 0:
            print(f"  staged: {filepath}")
        else:
            print(f"  git add failed: {result.stderr.strip()}", file=sys.stderr)
            return False
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Resolve conflict markers by choosing ours/theirs per hunk"
    )
    parser.add_argument("file", help="File with conflict markers")
    strategy_group = parser.add_mutually_exclusive_group(required=True)
    strategy_group.add_argument("--ours", action="store_true", help="Keep our version for all (or matched) hunks")
    strategy_group.add_argument("--theirs", action="store_true", help="Keep their version for all (or matched) hunks")
    strategy_group.add_argument("--interactive", action="store_true", help="Prompt for each hunk")
    parser.add_argument("--grep", metavar="PATTERN", help="Only apply strategy to hunks matching this regex")
    parser.add_argument("--dry-run", action="store_true", help="Print result without writing")
    parser.add_argument("--no-add", action="store_true", help="Don't git add after resolving")
    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(f"Error: {args.file} not found", file=sys.stderr)
        sys.exit(1)

    with open(args.file) as f:
        content = f.read()

    if not has_conflict_markers(content):
        print(f"{args.file}: no conflict markers found")
        sys.exit(0)

    segments = parse_hunks(content)

    if args.ours:
        strategy = "ours"
    elif args.theirs:
        strategy = "theirs"
    else:
        strategy = "interactive"

    resolved, total, n_resolved = apply_strategy(segments, strategy, grep_pattern=args.grep)

    remaining = total - n_resolved
    print(f"{args.file}: {total} conflict(s) — {n_resolved} resolved, {remaining} remaining")

    if args.dry_run:
        print("--- dry-run output ---")
        print(resolved)
        return

    staged_ok = _write_and_stage(args.file, resolved, remaining, args.no_add)
    sys.exit(1 if (remaining > 0 or not staged_ok) else 0)


if __name__ == "__main__":
    main()
