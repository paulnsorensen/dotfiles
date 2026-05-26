"""fetch.py — external (GitHub-fetched) skill install via ``gh skill install``.

Spec curd 4 / decision D3: ``source:`` skills are fetched by shelling out to
``gh skill install`` — no npx, no manual ``git clone``. ``path:`` (local-tree)
skills are unchanged: the renderers copy them into the harness skill dirs, so
they never reach this module.

The invocation mirrors the existing ``chezmoi/lib/install-external.sh``::

    gh skill install <repo> [<name>] --agent <gh-agent> --scope user --force [--pin <ref>]

``--scope user`` installs into the harness's own user-level skill dir (the
``ap`` profile install targets the harness config dir; gh owns the skill
placement under it). ``--force`` matches the registry's always-overwrite
contract.

The harness names ``ap`` uses (``claude``/``codex``/``cursor``/``copilot``/
``opencode``) differ from gh's ``--agent`` IDs for two harnesses; :data:`GH_AGENT`
maps them.

A ``runner`` callable is injected so the fetch is unit-testable without
spawning ``gh``; the default runs the real subprocess.
"""

from __future__ import annotations

import subprocess
from typing import Any, Callable

# ap harness name -> gh skill `--agent` ID. Most pass through; claude and
# copilot differ (verified against `gh skill install --help`).
GH_AGENT = {
    "claude": "claude-code",
    "codex": "codex",
    "cursor": "cursor",
    "copilot": "github-copilot",
    "opencode": "opencode",
}

Runner = Callable[[list[str]], int]


class SkillFetchError(Exception):
    """Raised when a skill cannot be fetched (unknown harness, or a non-zero
    ``gh skill install`` exit)."""


def gh_agent_for(harness: str) -> str:
    """Map an ``ap`` harness name to its ``gh skill --agent`` ID. Fails loud
    on an unknown harness rather than passing a bogus agent to ``gh``."""
    try:
        return GH_AGENT[harness]
    except KeyError:
        raise SkillFetchError(
            f"ap: unknown harness '{harness}' for skill fetch "
            f"(valid: {', '.join(sorted(GH_AGENT))})"
        )


def _default_runner(argv: list[str]) -> int:
    return subprocess.run(argv, check=False).returncode


def fetch_external_skill(
    source: str,
    name: str | None,
    pin: str | None,
    harness: str,
    runner: Runner | None = None,
) -> None:
    """Install one external skill into ``harness`` via ``gh skill install``.

    ``name`` is the optional explicit skill (omitted for a repo-level install
    that auto-discovers every skill in the repo). ``pin`` appends
    ``--pin <ref>`` for reproducible installs. A non-zero exit fails loud."""
    run = runner or _default_runner
    agent = gh_agent_for(harness)
    argv = ["gh", "skill", "install", source]
    if name:
        argv.append(name)
    argv += ["--agent", agent, "--scope", "user", "--force"]
    if pin:
        argv += ["--pin", pin]
    rc = run(argv)
    if rc != 0:
        target = f"{source} {name}".strip()
        raise SkillFetchError(
            f"ap: gh skill install failed for '{target}' -> {harness} "
            f"(exit {rc})"
        )


def external_skills(skills: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Select the ``source:`` (GitHub-fetched) skill items from a manifest's
    skill list. ``path:`` (local-tree) items are excluded — they are copied by
    the renderers, not fetched."""
    return [s for s in skills if s.get("source")]
