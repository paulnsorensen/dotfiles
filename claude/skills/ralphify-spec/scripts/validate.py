#!/usr/bin/env python3
"""
Validate a RALPH.md against the ralphify v0.3.0 schema.

Catches the failure modes that parse but break at runtime:
- shell metacharacters in commands[].run (shlex.split fails silently)
- undeclared {{ commands.X }} or {{ args.X }} placeholders (in body or run)
- duplicate or malformed command/arg names
- missing required `agent` field or agent binary off PATH
- `timeout: true` (bool slipping through int check)

Exits 0 on clean (warnings allowed), 1 on errors, 2 on environment problems.
Run via: `uv run --with pyyaml python validate.py <path/to/RALPH.md>`
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "validate.py: PyYAML not available. Run via "
        "`uv run --with pyyaml python validate.py <path>`.\n"
    )
    sys.exit(2)

NAME_RE = re.compile(r"^[a-zA-Z0-9_-]+$")
SHELL_META = ("|", "&&", "||", ";", ">", "<", "`", "$(")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
PLACEHOLDER_RE = re.compile(r"\{\{\s*(commands|args|ralph)\.([a-zA-Z0-9_-]+)\s*\}\}")
RALPH_META = {"name", "iteration", "max_iterations"}


def _split_frontmatter(text: str) -> tuple[dict, str]:
    """Match ralphify's _extract_frontmatter_block: tolerate trailing whitespace
    on the closing `---` line and tolerate EOF without a trailing newline."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip() != "---":
        raise ValueError("RALPH.md must start with YAML frontmatter delimited by ---")
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            fm = yaml.safe_load("".join(lines[1:i])) or {}
            body = "".join(lines[i + 1 :])
            return fm, body
    raise ValueError("RALPH.md frontmatter is not closed with ---")


def _validate_agent(fm: dict) -> list[str]:
    errors: list[str] = []
    agent = fm.get("agent")
    if not agent or not isinstance(agent, str) or not agent.strip():
        errors.append("frontmatter `agent` is required and must be a non-empty string")
        return errors
    first_token = agent.split()[0]
    if shutil.which(first_token) is None:
        errors.append(
            f"agent binary `{first_token}` not on PATH — ralphify will refuse to start"
        )
    return errors


def _validate_command(i: int, cmd: object) -> tuple[list[str], str | None]:
    errors: list[str] = []
    if not isinstance(cmd, dict):
        errors.append(f"commands[{i}] must be a mapping")
        return errors, None
    name = cmd.get("name")
    run = cmd.get("run")
    if not name or not isinstance(name, str):
        errors.append(f"commands[{i}].name is required")
        return errors, None
    if not NAME_RE.match(name):
        errors.append(f"commands[{i}].name `{name}` must match [a-zA-Z0-9_-]+")
    if not run or not isinstance(run, str):
        errors.append(f"commands[{i}].run is required")
        return errors, name
    for meta in SHELL_META:
        if meta in run:
            errors.append(
                f"commands[{i}].run contains shell metacharacter `{meta}` — "
                f"move to a script and reference as ./script.sh"
            )
            break
    timeout = cmd.get("timeout")
    if timeout is not None:
        # bool is an int subclass — ralphify guards against `timeout: true` and
        # we have to too, otherwise the int/float check passes silently.
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0:
            errors.append(f"commands[{i}].timeout must be a positive number")
    return errors, name


def _validate_commands(fm: dict) -> tuple[list[str], set[str]]:
    errors: list[str] = []
    declared: set[str] = set()
    for i, cmd in enumerate(fm.get("commands") or []):
        cmd_errors, name = _validate_command(i, cmd)
        errors.extend(cmd_errors)
        if name is not None:
            if name in declared:
                errors.append(f"commands[{i}].name `{name}` is not unique")
            declared.add(name)
    return errors, declared


def _validate_args(fm: dict) -> tuple[list[str], set[str]]:
    errors: list[str] = []
    declared: set[str] = set()
    for i, arg in enumerate(fm.get("args") or []):
        if not isinstance(arg, str):
            errors.append(f"args[{i}] must be a string")
            continue
        if not NAME_RE.match(arg):
            errors.append(f"args[{i}] `{arg}` must match [a-zA-Z0-9_-]+")
        if arg in declared:
            errors.append(f"args[{i}] `{arg}` is not unique")
        declared.add(arg)
    return errors, declared


def _check_placeholder(
    kind: str,
    name: str,
    declared_commands: set[str],
    declared_args: set[str],
    where: str,
) -> str | None:
    if kind == "commands" and name not in declared_commands:
        return f"{where} references {{{{ commands.{name} }}}} but no command named `{name}` is declared"
    if kind == "args" and name not in declared_args:
        return f"{where} references {{{{ args.{name} }}}} but no arg named `{name}` is declared"
    if kind == "ralph" and name not in RALPH_META:
        return f"{where} references {{{{ ralph.{name} }}}} — only {sorted(RALPH_META)} are valid"
    return None


def _validate_placeholders(
    body: str,
    commands: list,
    declared_commands: set[str],
    declared_args: set[str],
) -> tuple[list[str], set[str], set[str]]:
    errors: list[str] = []
    referenced_commands: set[str] = set()
    referenced_args: set[str] = set()

    body_no_comments = HTML_COMMENT_RE.sub("", body)
    for match in PLACEHOLDER_RE.finditer(body_no_comments):
        kind, name = match.group(1), match.group(2)
        if kind == "commands":
            referenced_commands.add(name)
        elif kind == "args":
            referenced_args.add(name)
        msg = _check_placeholder(kind, name, declared_commands, declared_args, "body")
        if msg:
            errors.append(msg)

    for i, cmd in enumerate(commands):
        if not isinstance(cmd, dict) or not isinstance(cmd.get("run"), str):
            continue
        for match in PLACEHOLDER_RE.finditer(cmd["run"]):
            kind, name = match.group(1), match.group(2)
            if kind == "args":
                referenced_args.add(name)
            elif kind == "commands":
                referenced_commands.add(name)
            msg = _check_placeholder(
                kind, name, declared_commands, declared_args, f"commands[{i}].run"
            )
            if msg:
                errors.append(msg)

    return errors, referenced_commands, referenced_args


def validate(path: Path) -> tuple[list[str], list[str]]:
    text = path.read_text()
    try:
        fm, body = _split_frontmatter(text)
    except ValueError as e:
        return [str(e)], []

    errors: list[str] = []
    warnings: list[str] = []

    errors.extend(_validate_agent(fm))
    cmd_errors, declared_commands = _validate_commands(fm)
    errors.extend(cmd_errors)
    arg_errors, declared_args = _validate_args(fm)
    errors.extend(arg_errors)

    placeholder_errors, ref_cmds, ref_args = _validate_placeholders(
        body, fm.get("commands") or [], declared_commands, declared_args
    )
    errors.extend(placeholder_errors)

    for name in declared_commands - ref_cmds:
        warnings.append(f"command `{name}` is declared but never referenced")
    for name in declared_args - ref_args:
        warnings.append(f"arg `{name}` is declared but never referenced")

    return errors, warnings


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: validate.py <path/to/RALPH.md>\n")
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        sys.stderr.write(f"validate.py: {path} not found\n")
        return 2
    errors, warnings = validate(path)
    for w in warnings:
        sys.stderr.write(f"warn: {w}\n")
    for e in errors:
        sys.stderr.write(f"error: {e}\n")
    if errors:
        sys.stderr.write(f"\n{len(errors)} error(s), {len(warnings)} warning(s)\n")
        return 1
    sys.stderr.write(f"ok ({len(warnings)} warning(s))\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
