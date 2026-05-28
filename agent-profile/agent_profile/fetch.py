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

    npx --yes skills add <repo>[@<ref>] --skill <name|*> [--skill <name>...] \
        --agent <id> [--agent <id>...] -g --copy -y

``npx --yes`` auto-installs the ``skills`` CLI without a prompt (required for
non-interactive contexts like the chezmoi ``run_onchange``); ``-g`` installs at
user (global) scope; ``--copy`` copies the files (rather than symlinking into
the agent dirs, preserving the previous copy-and-overwrite behaviour); ``-y``
runs the ``skills`` CLI itself non-interactively. ``--skill '*'`` installs every
skill in the repo (native auto-discovery — no GitHub-API listing needed).

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
from pathlib import Path
from typing import Any, Callable


def _load_skill_agents() -> dict[str, str]:
    """Load the canonical ap-harness -> ``skills`` CLI ``--agent`` ID map from
    ``skill_agents.txt``. ``chezmoi/lib/install-external.sh`` reads the same
    file (extracting the VALUES as ``KNOWN_AGENTS``), so adding a harness
    there makes it valid in both fetch paths and drift between them is
    impossible."""
    path = Path(__file__).with_name("skill_agents.txt")
    mapping: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, val = line.partition("=")
        if not sep:
            continue  # malformed line — skip, fail-loud at use site if used
        mapping[key.strip()] = val.strip()
    return mapping


# ap harness name -> `skills` CLI `--agent` ID. (Identical to the IDs the
# retired `gh skill` path used.) claude and copilot differ from their ap names.
SKILL_AGENT = _load_skill_agents()

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
    # `npx --yes` auto-installs the `skills` CLI without prompting; required so
    # the chezmoi run_onchange (non-interactive TTY) doesn't fall over on a
    # fresh machine where the CLI isn't yet cached. Sibling paths
    # (install-external.sh, zsh aliases) use --yes too — keep parity.
    argv = ["npx", "--yes", "skills", "add", spec]
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
