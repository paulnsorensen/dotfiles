#!/usr/bin/env python3
"""Enforce token ceilings for repo-owned agent instruction sources."""

from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path

import tiktoken


DISCOVERY_PATTERNS = (
    "AGENTS.md",
    "CLAUDE.md",
    "agent-profile/AGENTS.md",
    "agents/AGENTS.md",
    "agents/RTK.md",
    "agents/preamble.md",
    "profiles/*/AGENTS.md",
    "profiles/*/CLAUDE.md",
    "chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md",
    "chezmoi/dot_pi/private_agent/APPEND_SYSTEM.md",
    ".github/copilot-instructions.md",
    ".github/instructions/*.instructions.md",
)


def discover_sources(root: Path) -> set[str]:
    return {
        path.relative_to(root).as_posix()
        for pattern in DISCOVERY_PATTERNS
        for path in root.glob(pattern)
        if path.is_file()
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("--root", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = args.config.resolve()
    root = (args.root or config_path.parent.parent).resolve()
    config = tomllib.loads(config_path.read_text())
    encodings = config.get("encodings", [])
    sources = config.get("source", [])
    stacks = config.get("stack", [])
    errors: list[str] = []

    if config.get("version") != 1:
        errors.append("config version must be 1")
    if encodings != ["o200k_base", "cl100k_base"]:
        errors.append("encodings must be o200k_base and cl100k_base")

    source_by_path = {entry["path"]: entry for entry in sources}
    if len(source_by_path) != len(sources):
        errors.append("source paths must be unique")

    discovered = discover_sources(root)
    declared = set(source_by_path)
    for path in sorted(discovered - declared):
        errors.append(f"unbudgeted instruction source: {path}")
    for path in sorted(declared - discovered):
        errors.append(f"declared instruction source is missing: {path}")

    tokenizers = {name: tiktoken.get_encoding(name) for name in encodings}
    texts: dict[str, str] = {}
    for path in sorted(declared & discovered):
        text = (root / path).read_text()
        texts[path] = text
        limit = source_by_path[path]["max_tokens"]
        counts = {
            name: len(tokenizer.encode(text, disallowed_special=()))
            for name, tokenizer in tokenizers.items()
        }
        print(
            f"source {path}: "
            + " ".join(f"{name}={count}" for name, count in counts.items())
            + f" max={limit}"
        )
        for name, count in counts.items():
            if count > limit:
                errors.append(f"{path} exceeds {name} budget: {count} > {limit}")

    stack_names = [entry["name"] for entry in stacks]
    if len(set(stack_names)) != len(stack_names):
        errors.append("stack names must be unique")
    for stack in stacks:
        name = stack["name"]
        paths = stack["sources"]
        unknown = [path for path in paths if path not in declared]
        if unknown:
            errors.append(f"stack {name} has unknown sources: {', '.join(unknown)}")
            continue
        if any(path not in texts for path in paths):
            continue
        text = "\n".join(texts[path] for path in paths)
        limit = stack["max_tokens"]
        counts = {
            encoding: len(tokenizer.encode(text, disallowed_special=()))
            for encoding, tokenizer in tokenizers.items()
        }
        print(
            f"stack {name}: "
            + " ".join(f"{encoding}={count}" for encoding, count in counts.items())
            + f" max={limit}"
        )
        for encoding, count in counts.items():
            if count > limit:
                errors.append(f"stack {name} exceeds {encoding} budget: {count} > {limit}")

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
