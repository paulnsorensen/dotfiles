"""fetch_sources_command.py — fetch external ``source:`` skills for a profile.

Spec decision: external ``source:`` fetching is split into its own
``ap fetch-sources <profile>`` command. It is the explicit network/package
step that runs BEFORE ``ap compile`` in the C-lite pipeline
(``ap fetch-sources live`` -> ``ap compile live`` -> drift gate ->
``ap apply-compiled``).

The command parses the profile manifest, selects its ``source:``
(GitHub-fetched) skills, and installs them at global scope via
``npx skills add`` (one shallow clone per source repo, all skill-supporting
harnesses in a single invocation) through the shared helpers in
:mod:`agent_profile.fetch`. It renders, compiles, and applies nothing — that
is the job of ``ap compile`` / ``ap apply-compiled``.

``path:`` (local-tree) skills never reach this command: the renderers copy
them at compile time.

The CLI route is wired separately; this module only exposes
:func:`cmd_fetch_sources` and :func:`fetch_sources`.
"""

from __future__ import annotations

from typing import Any

from agent_profile import discover
from agent_profile.parse import parse_manifest


class FetchSourcesError(Exception):
    """A handled ``ap fetch-sources`` failure (unknown profile, bad args, or a
    skill-fetch error). The CLI converts it to a stderr line + exit 1."""


def _usage() -> str:
    return "Usage: ap fetch-sources <profile>"


def _fetch_runner(argv: list[str]) -> int:
    """Default ``npx skills add`` runner. Indirected through a module-level
    name so tests can stub the fetch without spawning ``npx``."""
    from agent_profile.fetch import _default_runner

    return _default_runner(argv)


def fetch_sources(profile: str, out: Any = None) -> int:
    """Fetch every ``source:`` skill declared by ``profile`` into the
    skill-supporting harnesses via ``npx skills add`` (global scope).

    Returns ``0`` on success, including the no-op case where the profile
    declares no ``source:`` skills (the runner is never invoked). Raises
    :class:`FetchSourcesError` on an unknown profile or a fetch failure.
    Performs no compile or apply step.
    """
    from agent_profile.fetch import (
        SKILL_AGENT,
        SkillFetchError,
        external_skills,
        fetch_external_source,
        group_external_sources,
    )

    profile_dir = discover.find_profile_dir(profile)
    if profile_dir is None:
        raise FetchSourcesError(
            f"ap fetch-sources: profile '{profile}' not found"
        )

    manifest = parse_manifest(profile_dir)

    if not external_skills(manifest.skills):
        return 0

    # All skill-supporting harnesses (the canonical map in skill_agents.txt).
    # `npx skills add -g` installs globally regardless of harness, so a bare
    # `ap fetch-sources <profile>` populates every harness's skill store in one
    # shallow clone per source — the same default the retired install path used.
    harnesses = list(SKILL_AGENT)

    try:
        for source, names, pin in group_external_sources(manifest.skills):
            label = "*" if names is None else ", ".join(names)
            print(
                f"  fetching skills {source} ({label}) -> "
                f"{', '.join(harnesses)}",
                file=out,
            )
            fetch_external_source(source, names, pin, harnesses, _fetch_runner)
    except SkillFetchError as exc:
        raise FetchSourcesError(str(exc)) from exc
    except OSError as exc:
        raise FetchSourcesError(
            f"ap: cannot run npx ({exc}); is Node/npx installed?"
        ) from exc
    return 0


def cmd_fetch_sources(args: list[str], out_stream: Any) -> int:
    """CLI entry for ``ap fetch-sources <profile>``. Parses the profile name and
    delegates to :func:`fetch_sources`. Raises :class:`FetchSourcesError` on a
    missing or extra argument."""
    if not args:
        raise FetchSourcesError(_usage())
    profile = args[0]
    if not profile or profile.startswith("-"):
        raise FetchSourcesError(_usage())
    if len(args) > 1:
        raise FetchSourcesError(
            f"ap fetch-sources: unexpected argument '{args[1]}'"
        )
    return fetch_sources(profile, out=out_stream)
