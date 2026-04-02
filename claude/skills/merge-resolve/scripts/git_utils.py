#!/usr/bin/env python3
import subprocess

CONFLICT_MARKER = "<<<<<<< "


def get_conflicted_files():
    result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=U"],
        capture_output=True, text=True, timeout=10, check=True,
    )
    return [f for f in result.stdout.strip().splitlines() if f]


def check_mergiraf_support(path):
    result = subprocess.run(
        ["git", "check-attr", "merge", "--", path],
        capture_output=True, text=True, timeout=5, check=True,
    )
    return "mergiraf" in result.stdout


def has_conflict_markers(content):
    return CONFLICT_MARKER in content
