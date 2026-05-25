"""shared.py — cross-harness shared-path writers.

Behavioral port of agent-profile/lib/shared_writer.sh. Several harnesses
read the same on-disk file shapes:

  - ``.claude/agents/<n>.md``   -> Claude (via plugin), opencode, Cursor
  - ``.agents/skills/<n>/``     -> Codex, opencode, Cursor

Each writer appends every file it writes (relative to ``target``) to the
caller-supplied ``out_files`` accumulator, deduping, so the install
manifest tracks them and uninstall is exact. In the bash this was the
global ``_AP_OUT_FILES``; here it is an explicit ``list[str]`` the
renderer resets per-harness.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any


def track_file(out_files: list[str], rel: str) -> None:
    """Append ``rel`` to ``out_files`` if absent. Port of ``_ap_track_file``."""
    if rel not in out_files:
        out_files.append(rel)


def _frontmatter_lines(frontmatter: dict[str, Any]) -> list[str]:
    """Render a flat dict as ``key: value`` YAML lines (jq ``to_entries``
    preserves insertion order; values are stringified scalars)."""
    return [f"{k}: {v}" for k, v in frontmatter.items()]


def write_shared_claude_agent(
    target: Path,
    name: str,
    body_path: Path,
    frontmatter: dict[str, Any] | None,
    out_files: list[str],
) -> None:
    """Write ``.claude/agents/<name>.md`` under ``target``.

    Body is read from ``body_path``. If ``frontmatter`` is non-empty,
    render it as ``---\\n...\\n---\\n`` at the top. Idempotent on content.
    Port of ``ap_write_shared_claude_agent``.
    """
    rel = f".claude/agents/{name}.md"
    abs_path = Path(str(target).rstrip("/")) / rel

    if not body_path.is_file():
        raise FileNotFoundError(
            f"ap_write_shared_claude_agent: body not found: {body_path}"
        )

    abs_path.parent.mkdir(parents=True, exist_ok=True)
    parts: list[str] = []
    if frontmatter:
        parts.append("---\n")
        parts.append("\n".join(_frontmatter_lines(frontmatter)) + "\n")
        parts.append("---\n")
    parts.append(body_path.read_text())
    abs_path.write_text("".join(parts))

    track_file(out_files, rel)


def copy_shared_skill(
    target: Path, name: str, source_dir: Path, out_files: list[str]
) -> None:
    """Copy a skill tree into the shared ``.agents/skills/<name>/`` path.
    Port of ``ap_copy_shared_skill``."""
    rel = f".agents/skills/{name}"
    abs_path = Path(str(target).rstrip("/")) / rel

    if not source_dir.is_dir():
        raise NotADirectoryError(
            f"ap_copy_shared_skill: source not a dir: {source_dir}"
        )

    if abs_path.exists():
        shutil.rmtree(abs_path)
    abs_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_dir, abs_path)

    track_file(out_files, rel)


_OVERRIDE_SUBDIRS = {
    "agent": "agents",
    "agents": "agents",
    "agent_singular": "agent",
    "opencode_agent": "agent",
    "command": "commands",
    "commands": "commands",
}


def render_model_override(
    target: Path,
    harness: str,
    kind: str,
    name: str,
    body_path: Path,
    model: str,
    out_files: list[str],
) -> None:
    """Render a per-harness ``model: <value>`` override file.

    Writes ``.<harness>/<subdir>/<name>.md`` with a ``model:`` frontmatter
    line prepended to the body. The ``inherit`` sentinel (or empty model)
    writes nothing. Port of ``ap_render_model_override``.
    """
    if model in ("inherit", ""):
        return

    if not body_path.is_file():
        raise FileNotFoundError(
            f"ap_render_model_override: body not found: {body_path}"
        )

    subdir = _OVERRIDE_SUBDIRS.get(kind)
    if subdir is None:
        raise ValueError(f"ap_render_model_override: unknown kind '{kind}'")

    rel = f".{harness}/{subdir}/{name}.md"
    abs_path = Path(str(target).rstrip("/")) / rel

    abs_path.parent.mkdir(parents=True, exist_ok=True)
    abs_path.write_text(f"---\nmodel: {model}\n---\n" + body_path.read_text())

    track_file(out_files, rel)
