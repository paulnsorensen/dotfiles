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


def strip_frontmatter(text: str) -> str:
    """Return ``text`` with a leading ``---``/``---`` YAML frontmatter block
    removed.

    A block is recognised only when the very first line is exactly ``---``;
    it ends at the next line that is exactly ``---``. Bodies that do not open
    with a frontmatter block — or whose opener is never closed — are returned
    unchanged, so a body that merely starts with a horizontal rule is never
    truncated. Used to keep already-frontmattered agent bodies from emitting a
    second frontmatter block (or leaking frontmatter into codex's
    ``developer_instructions``) when a renderer prepends its own."""
    if not text.startswith("---"):
        return text
    lines = text.splitlines(keepends=True)
    if lines[0].rstrip("\r\n") != "---":
        return text
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r\n") == "---":
            return "".join(lines[i + 1:])
    return text


# Tools whose presence means an agent can modify files. Used to derive
# read-only intent for harnesses that sandbox by capability (codex
# ``sandbox_mode``, opencode ``permission.edit``) rather than by an explicit
# tool list. Includes the MCP write surfaces — tilth's writer and serena's
# symbol-edit tools — not just the built-in editors, so an agent that bans
# ``Write`` but keeps ``mcp__tilth__tilth_write`` is not mistaken for
# read-only.
_WRITE_TOOLS = frozenset({
    "Edit",
    "Write",
    "MultiEdit",
    "NotebookEdit",
    "mcp__tilth__tilth_write",
    "mcp__serena__replace_symbol_body",
    "mcp__serena__insert_before_symbol",
    "mcp__serena__insert_after_symbol",
    "mcp__serena__replace_content",
    "mcp__serena__rename_symbol",
    "mcp__serena__safe_delete_symbol",
})


def _grants_write(tool: str) -> bool:
    """True when a tool entry confers a file-write capability.

    Matches an exact write tool or a trailing-``*`` wildcard (e.g.
    ``mcp__serena__*``) that subsumes one — registries grant whole MCP
    servers by glob, so a literal set-membership check would miss them."""
    if tool in _WRITE_TOOLS:
        return True
    if tool.endswith("*"):
        prefix = tool[:-1]
        return any(w.startswith(prefix) for w in _WRITE_TOOLS)
    return False


def agent_is_read_only(item: dict[str, Any]) -> bool:
    """True when an agent's tool config forbids file writes.

    Read-only when the agent either disallows a write tool
    (``disallowedTools``) or declares a ``tools`` whitelist that contains no
    write tool. A wildcard grant such as ``mcp__serena__*`` counts as a write
    tool (it subsumes serena's editors). An agent that declares neither signal
    is treated as writable (no sandbox imposed)."""
    if any(_grants_write(t) for t in item.get("disallowedTools") or ()):
        return True
    tools = item.get("tools") or ()
    return bool(tools) and not any(_grants_write(t) for t in tools)


def claude_agent_frontmatter(item: dict[str, Any]) -> dict[str, str]:
    """Build the frontmatter dict for the shared ``.claude/agents/<n>.md`` file.

    This file is read by Claude *and* Cursor, and — critically — Claude
    resolves it at user scope (``~/.claude/agents/``, priority 4), which wins
    over the same agent in a plugin tree (priority 5). So the shared file is
    the one Claude actually honors and must carry the full Claude metadata,
    not a model-neutral subset: ``model`` (claude), ``color``, ``effort`` and
    ``skills`` are all honored sub-agent frontmatter fields. Cursor reads the
    same file and ignores the fields it does not recognise; a Cursor-specific
    model still overrides via ``.cursor/agents/<n>.md`` when ``models.cursor``
    is set.

    Values are pre-stringified so :func:`_frontmatter_lines` emits clean YAML:
    ``tools`` as a CSV string, ``disallowedTools`` / ``skills`` as ``[a, b]``
    flow sequences, the rest as scalars. Empty fields are omitted."""
    fm: dict[str, str] = {"name": item["name"]}
    desc = item.get("description") or ""
    if desc:
        fm["description"] = desc
    tools = item.get("tools") or []
    if tools:
        fm["tools"] = ", ".join(tools)
    disallowed = item.get("disallowedTools") or []
    if disallowed:
        fm["disallowedTools"] = f"[{', '.join(disallowed)}]"
    model = (item.get("models") or {}).get("claude") or ""
    if model:
        fm["model"] = model
    color = item.get("color") or ""
    if color:
        fm["color"] = color
    effort = item.get("effort") or ""
    if effort:
        fm["effort"] = effort
    skills = item.get("skills") or []
    if skills:
        fm["skills"] = f"[{', '.join(skills)}]"
    return fm


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
    parts.append(strip_frontmatter(body_path.read_text()))
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


def write_shared_claude_skill(
    target: Path, name: str, source_dir: Path, out_files: list[str]
) -> None:
    """Copy a skill tree into the shared ``~/.claude/skills/<name>/`` path.

    Claude resolves user-scope skills (``~/.claude/skills/``, priority 4)
    ahead of plugin-scoped skills (priority 5), so writing here means the
    skill is available without a plugin and without duplicating it in the
    plugin tree — the same rationale as ``write_shared_claude_agent``.
    Port of ``ap_write_shared_claude_skill``.
    """
    rel = f".claude/skills/{name}"
    abs_path = Path(str(target).rstrip("/")) / rel

    if not source_dir.is_dir():
        raise NotADirectoryError(
            f"ap_write_shared_claude_skill: source not a dir: {source_dir}"
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
    abs_path.write_text(
        f"---\nmodel: {model}\n---\n" + strip_frontmatter(body_path.read_text())
    )

    track_file(out_files, rel)
