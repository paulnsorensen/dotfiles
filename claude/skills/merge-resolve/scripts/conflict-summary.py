#!/usr/bin/env python3
"""Structured summary of merge conflicts for Claude to consume.

Parses conflict markers in all conflicted files and outputs a machine-friendly
report: file, hunk number, line range, ours/theirs/base content, and context.

Usage:
    python3 conflict-summary.py                    # all conflicted files
    python3 conflict-summary.py path/to/file.rs    # specific file(s)
    python3 conflict-summary.py --json             # JSON output for scripting
    python3 conflict-summary.py --context 5        # show 5 lines of context around each hunk
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from git_utils import check_mergiraf_support, get_conflicted_files


MARKER_OURS = "<<<<<<< "
MARKER_BASE = "||||||| "
MARKER_SEP = "======="
MARKER_THEIRS = ">>>>>>> "


def _collect_lines(lines, i, stop_check):
    collected = []
    while i < len(lines) and not stop_check(lines[i]):
        collected.append(lines[i])
        i += 1
    return collected, i


def _parse_single_hunk(lines, i, hunk_number):
    hunk_start = i + 1  # 1-indexed
    label_ours = lines[i].rstrip("\n")[len(MARKER_OURS):]
    i += 1

    ours_lines, i = _collect_lines(
        lines, i,
        lambda l: l.startswith(MARKER_BASE) or l.startswith(MARKER_SEP),
    )

    base_lines = None
    if i < len(lines) and lines[i].startswith(MARKER_BASE):
        i += 1
        base_lines, i = _collect_lines(lines, i, lambda l: l.startswith(MARKER_SEP))

    if i < len(lines) and lines[i].startswith(MARKER_SEP):
        i += 1

    theirs_lines, i = _collect_lines(lines, i, lambda l: l.startswith(MARKER_THEIRS))

    label_theirs = ""
    if i < len(lines):
        label_theirs = lines[i].rstrip("\n")[len(MARKER_THEIRS):]
        hunk_end = i + 1  # 1-indexed
        i += 1
    else:
        hunk_end = i

    hunk = {
        "hunk": hunk_number,
        "lines": f"{hunk_start}-{hunk_end}",
        "start": hunk_start,
        "end": hunk_end,
        "label_ours": label_ours,
        "label_theirs": label_theirs,
        "ours": "".join(ours_lines),
        "ours_lines": len(ours_lines),
        "theirs": "".join(theirs_lines),
        "theirs_lines": len(theirs_lines),
        "base": "".join(base_lines) if base_lines is not None else None,
    }
    return hunk, i


def parse_conflicts(filepath):
    with open(filepath) as f:
        lines = f.readlines()

    hunks = []
    i = 0

    while i < len(lines):
        if not lines[i].startswith(MARKER_OURS):
            i += 1
            continue
        hunk, i = _parse_single_hunk(lines, i, len(hunks) + 1)
        hunks.append(hunk)

    return hunks, lines


def get_context(all_lines, hunk, n_context):
    before_start = max(0, hunk["start"] - 1 - n_context)
    before_end = hunk["start"] - 1
    after_start = hunk["end"]
    after_end = min(len(all_lines), after_start + n_context)

    before = "".join(all_lines[before_start:before_end])
    after = "".join(all_lines[after_start:after_end])
    return before.rstrip("\n"), after.rstrip("\n")


def _format_hunk(h, all_lines, context_lines):
    parts = [f"\n### Hunk {h['hunk']}  (lines {h['lines']})"]

    before_ctx = ""
    after_ctx = ""
    if context_lines > 0:
        before_ctx, after_ctx = get_context(all_lines, h, context_lines)
        if before_ctx:
            parts.append(f"  context before:\n    {before_ctx.replace(chr(10), chr(10) + '    ')}")

    parts.append(f"  ours ({h['label_ours']}, {h['ours_lines']} lines):")
    for line in h["ours"].splitlines():
        parts.append(f"    + {line}")

    if h["base"] is not None:
        parts.append(f"  base:")
        for line in h["base"].splitlines():
            parts.append(f"    ~ {line}")

    parts.append(f"  theirs ({h['label_theirs']}, {h['theirs_lines']} lines):")
    for line in h["theirs"].splitlines():
        parts.append(f"    - {line}")

    if after_ctx:
        parts.append(f"  context after:\n    {after_ctx.replace(chr(10), chr(10) + '    ')}")

    return parts


def format_text(files_data, context_lines):
    parts = []

    for fd in files_data:
        path = fd["file"]
        hunks = fd["hunks"]
        all_lines = fd["all_lines"]
        lang = fd["lang"]
        mergiraf = fd["mergiraf_supported"]

        header = f"## {path}  ({lang})"
        if mergiraf:
            header += " [mergiraf: yes]"
        else:
            header += " [mergiraf: no — use conflict-pick.py]"
        header += f"  [{len(hunks)} conflict(s)]"
        parts.append(header)

        for h in hunks:
            parts.extend(_format_hunk(h, all_lines, context_lines))

        parts.append("")

    return "\n".join(parts)


def format_json(files_data):
    output = []
    for fd in files_data:
        file_entry = {
            "file": fd["file"],
            "lang": fd["lang"],
            "mergiraf_supported": fd["mergiraf_supported"],
            "conflict_count": len(fd["hunks"]),
            "hunks": [],
        }
        for h in fd["hunks"]:
            file_entry["hunks"].append({
                "hunk": h["hunk"],
                "lines": h["lines"],
                "start": h["start"],
                "end": h["end"],
                "label_ours": h["label_ours"],
                "label_theirs": h["label_theirs"],
                "ours": h["ours"],
                "theirs": h["theirs"],
                "base": h["base"],
            })
        output.append(file_entry)
    return json.dumps(output, indent=2)


def detect_lang(path):
    ext = os.path.splitext(path)[1]
    lang_map = {
        ".rs": "Rust", ".py": "Python", ".ts": "TypeScript", ".tsx": "TSX",
        ".js": "JavaScript", ".jsx": "JSX", ".go": "Go", ".java": "Java",
        ".rb": "Ruby", ".c": "C", ".cpp": "C++", ".cs": "C#", ".kt": "Kotlin",
        ".sh": "Shell", ".json": "JSON", ".yaml": "YAML", ".yml": "YAML",
        ".toml": "TOML", ".md": "Markdown", ".html": "HTML", ".xml": "XML",
        ".sql": "SQL", ".lua": "Lua", ".ex": "Elixir", ".nix": "Nix",
        ".tf": "Terraform", ".hcl": "HCL", ".swift": "Swift",
    }
    return lang_map.get(ext, ext or "unknown")


def _load_files_data(targets):
    files_data = []
    for path in targets:
        if not os.path.exists(path):
            print(f"warning: {path} not found, skipping", file=sys.stderr)
            continue
        hunks, all_lines = parse_conflicts(path)
        if not hunks:
            continue
        files_data.append({
            "file": path,
            "lang": detect_lang(path),
            "mergiraf_supported": check_mergiraf_support(path),
            "hunks": hunks,
            "all_lines": all_lines,
        })
    return files_data


def _print_header(files_data, total_hunks):
    total_files = len(files_data)
    mergiraf_yes = sum(1 for fd in files_data if fd["mergiraf_supported"])
    mergiraf_no = total_files - mergiraf_yes
    print(f"# Conflict Summary: {total_files} file(s), {total_hunks} hunk(s)")
    print(f"#   mergiraf-supported: {mergiraf_yes}  |  unsupported: {mergiraf_no}")
    if mergiraf_yes > 0:
        print(f"#   → try: python3 <skill>/scripts/batch-resolve.py --dry-run")
    if mergiraf_no > 0:
        print(f"#   → try: python3 <skill>/scripts/conflict-pick.py <file> --ours|--theirs")
    print()


def main():
    parser = argparse.ArgumentParser(description="Structured conflict summary for Claude")
    parser.add_argument("files", nargs="*", help="Specific files (default: all conflicted)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--context", type=int, default=3, help="Lines of context around each hunk (default: 3)")
    args = parser.parse_args()

    targets = args.files if args.files else get_conflicted_files()
    if not targets:
        print("No conflicted files found.")
        return

    files_data = _load_files_data(targets)

    if not files_data:
        print("No conflict markers found in the specified files.")
        return

    total_hunks = sum(len(fd["hunks"]) for fd in files_data)

    if args.json:
        print(format_json(files_data))
    else:
        _print_header(files_data, total_hunks)
        print(format_text(files_data, args.context))


if __name__ == "__main__":
    main()
