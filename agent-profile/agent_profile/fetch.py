"""fetch.py — external (GitHub-fetched) skill install via ``npx skills add``.

Spec curd 4 / decision D3: ``source:`` skills are fetched by shelling out to
the Vercel ``skills`` CLI (``npx skills add``), which shallow-clones the source
repo once and copies the selected skills into each agent's skill dir. ``path:``
(local-tree) skills are unchanged: the renderers copy them into the harness
skill dirs, so they never reach this module.

Why ``npx skills`` over ``gh skill install``: ``gh`` fetched every file of every
skill via individual GitHub blob-API calls — files × skills × harnesses
round-trips, any one of which could reset mid-stream and abort the whole sync.
``npx skills add`` does a single ``git clone --depth 1`` per repo and installs
to every requested agent in one invocation, collapsing the network surface to
one connection per source.

The invocation::

    npx skills add <repo>[@<ref>] --skill <name|*> [--skill <name>...] \
        --agent <id> [--agent <id>...] -g --copy -y

``-g`` installs at user (global) scope; ``--copy`` copies the files (rather than
symlinking into the agent dirs, preserving the previous copy-and-overwrite
behaviour); ``-y`` runs non-interactively. ``--skill '*'`` installs every skill
in the repo (native auto-discovery — no GitHub-API listing needed).

Multiple agents and multiple explicit skills are each passed as *repeated*
flags: the CLI rejects comma/space-joined values, and — dangerously — exits 0
having installed nothing for a bad ``--agent`` value. Harness names are
therefore mapped to known agent IDs (failing loud on an unknown one) before the
call, so a bad agent never reaches ``npx``.

``<repo>@<ref>`` pins to a git ref; the CLI maps it to ``git clone --branch
<ref>``, which accepts branch and tag names but not bare commit SHAs.

A ``runner`` callable is injected so the fetch is unit-testable without spawning
``npx``; the default runs the real subprocess.
"""

from __future__ import annotations

import subprocess
from typing import Any, Callable

# ap harness name -> `skills` CLI `--agent` ID. (Identical to the IDs the
# retired `gh skill` path used.) claude and copilot differ from their ap names.
SKILL_AGENT = {
    "claude": "claude-code",
    "codex": "codex",
    "cursor": "cursor",
    "copilot": "github-copilot",
    "opencode": "opencode",
}

Runner = Callable[[list[str]], int]


class SkillFetchError(Exception):
    """Raised when a skill cannot be fetched (unknown harness, or a non-zero
    ``npx skills add`` exit)."""


def skill_agent_for(harness: str) -> str:
    """Map an ``ap`` harness name to its ``skills`` CLI ``--agent`` ID. Fails
    loud on an unknown harness rather than passing a bogus agent to
    ``npx skills add`` — which would exit 0 having installed nothing (a silent
    no-op)."""
    try:
        return SKILL_AGENT[harness]
    except KeyError:
        raise SkillFetchError(
            f"ap: unknown harness '{harness}' for skill fetch "
            f"(valid: {', '.join(sorted(SKILL_AGENT))})"
        )


def _default_runner(argv: list[str]) -> int:
    return subprocess.run(argv, check=False).returncode


def fetch_external_source(
    source: str,
    names: list[str] | None,
    pin: str | None,
    harnesses: list[str],
    runner: Runner | None = None,
) -> None:
    """Install skills from ``source`` into every harness in ``harnesses`` with a
    single ``npx skills add`` (one shallow clone, all agents at once).

    ``names`` lists the explicit skills to install; ``None`` or empty installs
    every skill in the repo (``--skill '*'``). ``pin`` appends ``@<ref>`` to the
    repo spec (branch/tag — not a bare SHA). A non-zero exit fails loud."""
    if not harnesses:
        return
    # Resolve agents first: an unknown harness raises before we build/run argv,
    # so a bad agent never reaches npx (where it would silently no-op at exit 0).
    agents = [skill_agent_for(h) for h in harnesses]

    run = runner or _default_runner
    spec = f"{source}@{pin}" if pin else source
    argv = ["npx", "skills", "add", spec]
    if names:
        for n in sorted(names):
            argv += ["--skill", n]
    else:
        argv += ["--skill", "*"]
    for agent in agents:
        argv += ["--agent", agent]
    argv += ["-g", "--copy", "-y"]

    rc = run(argv)
    if rc != 0:
        raise SkillFetchError(
            f"ap: npx skills add failed for '{spec}' "
            f"-> {', '.join(harnesses)} (exit {rc})"
        )


def external_skills(skills: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Select the ``source:`` (GitHub-fetched) skill items from a manifest's
    skill list. ``path:`` (local-tree) items are excluded — they are copied by
    the renderers, not fetched."""
    return [s for s in skills if s.get("source")]
