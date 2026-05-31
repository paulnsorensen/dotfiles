"""parse.py — profile.yaml -> Manifest, with include resolution.

Behavioral port of agent-profile/lib/parse.sh. A profile is a directory
holding ``profile.yaml`` plus payload files (agents/, skills/, commands/,
hooks/). :func:`parse_manifest` returns a fully-resolved :class:`Manifest`:
arrays from included profiles are concatenated (includes first, so the
outer profile's items appear last), each item carries a ``_source_dir``
pointing at the profile dir that owns its payload files.

Parity notes (must match parse.sh observably):

- ``name`` and every ``item.name`` must match ``[A-Za-z0-9._-]+`` and must
  not be the bare strings ``.`` or ``..``.
- Path-like fields (``body_path``, ``path``, ``script``) must be relative
  and contain no ``..`` path component.
- Legacy ``fallback`` field on each item is stripped at parse time.
- ``settings`` deep-merges; ``permissions_allow`` is unioned and sorted
  (jq ``unique``), then dropped entirely when empty.
- Top-level ``name``/``description`` come from the outermost profile, not
  the include accumulator.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from agent_profile._validate import (
    ParseError,
    _validate_name,
    _validate_relpath,
)
from agent_profile.env import load_dotenv
from agent_profile.ingest import expand_registries

_ITEM_SECTIONS = ("mcps", "agents", "skills", "commands", "hooks")


@dataclass
class Manifest:
    """A fully-resolved profile manifest (post-include-merge).

    Mirrors the JSON document parse.sh emits. Renderers read the item
    lists and ``settings``; ``_source_dir`` on each item resolves payload
    files against the owning profile dir.
    """

    name: str
    description: str = ""
    mcps: list[dict[str, Any]] = field(default_factory=list)
    agents: list[dict[str, Any]] = field(default_factory=list)
    skills: list[dict[str, Any]] = field(default_factory=list)
    commands: list[dict[str, Any]] = field(default_factory=list)
    hooks: list[dict[str, Any]] = field(default_factory=list)
    settings: dict[str, Any] = field(default_factory=dict)
    # Launch-overlay / isolation (spec curd 6). These come from the
    # outermost profile only (like name/description) — isolation is a
    # property of the profile you launch, not of its includes.
    isolated: bool = False
    system_prompt: str | None = None
    tools: list[str] = field(default_factory=list)
    permissions_deny: list[str] = field(default_factory=list)
    permissions_allow: list[str] = field(default_factory=list)
    enabled_plugins: dict[str, bool] = field(default_factory=dict)
    env: dict[str, str] = field(default_factory=dict)
    extra_args: list[str] = field(default_factory=list)
    # Install-time fields (curd: global profile). Outer-profile only, like
    # the launch-overlay fields above. ``target_default`` is consulted by
    # the CLI when ``--target`` is not passed; ``marketplaces`` is read by
    # the claude renderer to register entries in ``extraKnownMarketplaces``
    # under the live settings.json (matching how ``enabled_plugins`` lands
    # in ``enabledPlugins``). ``${VAR}`` refs (``$HOME``, ``${DOTFILES_DIR}``)
    # expand at use-time, not parse-time.
    target_default: str | None = None
    marketplaces: dict[str, str] = field(default_factory=dict)
    # MCP registration scope (claude renderer only). ``"plugin"`` (default)
    # writes the bundled plugin's ``.mcp.json`` (plugin-scoped tool names
    # ``mcp__plugin_<profile>_<server>__*``). ``"user"`` registers each
    # server at user scope via ``claude mcp add --scope user`` (bare tool
    # names ``mcp__<server>__*``) and skips the plugin ``.mcp.json``. Other
    # harnesses already write a single bare user-level config and ignore
    # this field. Outer-profile only, like the install fields above.
    mcp_scope: str = "plugin"

    def to_dict(self) -> dict[str, Any]:
        """Serialize to the same JSON shape parse.sh emits (used for the
        manifest ``merged_json`` cache and ``describe``)."""
        return {
            "mcps": self.mcps,
            "agents": self.agents,
            "skills": self.skills,
            "commands": self.commands,
            "hooks": self.hooks,
            "settings": self.settings,
            "name": self.name,
            "description": self.description,
            "mcp_scope": self.mcp_scope,
        }


def parse_one(profile_dir: Path) -> dict[str, Any]:
    """Read one profile.yaml, validate, return normalized dict.

    Each item in mcps/agents/skills/commands/hooks gets ``_source_dir``
    and has its ``fallback`` field stripped. Absent sections default to
    empty list/object. Port of ``ap_parse_one``.
    """
    manifest_path = profile_dir / "profile.yaml"
    if not manifest_path.is_file():
        raise ParseError(f"ap_parse_one: {manifest_path} not found")

    raw = yaml.safe_load(manifest_path.read_text()) or {}
    if not isinstance(raw, dict):
        raise ParseError(
            f"ap_parse_one: {manifest_path} must be a YAML mapping"
        )

    name = raw.get("name") or ""
    if not name:
        raise ParseError(
            f"ap_parse_one: {manifest_path} is missing required field 'name'"
        )
    _validate_name("profile name", str(name), str(manifest_path))

    for inc in raw.get("include") or []:
        _validate_name("include", str(inc), str(manifest_path))

    for section in _ITEM_SECTIONS:
        for item in raw.get(section) or []:
            item_name = item.get("name") if isinstance(item, dict) else None
            if item_name:
                _validate_name("item name", str(item_name), str(manifest_path))

    for section in ("agents", "commands"):
        for item in raw.get(section) or []:
            bp = item.get("body_path") if isinstance(item, dict) else None
            if bp:
                _validate_relpath("body_path", str(bp), str(manifest_path))

    for item in raw.get("skills") or []:
        p = item.get("path") if isinstance(item, dict) else None
        if p:
            _validate_relpath("path", str(p), str(manifest_path))

    for item in raw.get("hooks") or []:
        s = item.get("script") if isinstance(item, dict) else None
        if s:
            _validate_relpath("script", str(s), str(manifest_path))

    scope = raw.get("mcp_scope")
    if scope is not None and scope not in ("plugin", "user"):
        raise ParseError(
            f"ap_parse_one: {manifest_path} has invalid mcp_scope "
            f"{scope!r} (expected 'plugin' or 'user')"
        )

    sd = str(profile_dir)

    def _decorate(items: list[Any]) -> list[dict[str, Any]]:
        out = []
        for item in items:
            if not isinstance(item, dict):
                raise ParseError(
                    f"ap_parse_one: {manifest_path} has a non-mapping "
                    f"entry in a section list: {item!r}"
                )
            entry = dict(item)
            entry.pop("fallback", None)
            entry["_source_dir"] = sd
            out.append(entry)
        return out

    reg = _expand_registries_directive(raw.get("registries"))

    return {
        "name": name,
        "description": raw.get("description") or "",
        "include": raw.get("include") or [],
        # Launch-overlay fields (curd 6) — carried verbatim from the outer
        # profile; not merged from includes.
        "isolated": bool(raw.get("isolated") or False),
        "system_prompt": raw.get("system_prompt") or None,
        "tools": list(raw.get("tools") or []),
        "permissions_deny": list(raw.get("permissions_deny") or []),
        "permissions_allow": list(raw.get("permissions_allow") or []),
        "enabled_plugins": dict(raw.get("enabled_plugins") or {}),
        "env": dict(raw.get("env") or {}),
        "extra_args": list(raw.get("extra_args") or []),
        "target_default": raw.get("target_default") or None,
        "marketplaces": dict(raw.get("marketplaces") or {}),
        "mcp_scope": raw.get("mcp_scope") or "plugin",
        # Registry-derived items come first; inline items append (matching
        # the include "outer last" convention so an inline override on a
        # name-collision wins on scalar/object merges downstream).
        "mcps": reg["mcps"] + _decorate(raw.get("mcps") or []),
        "agents": reg["agents"] + _decorate(raw.get("agents") or []),
        "skills": reg["skills"] + _decorate(raw.get("skills") or []),
        "commands": _decorate(raw.get("commands") or []),
        "hooks": reg["hooks"] + _decorate(raw.get("hooks") or []),
        "settings": raw.get("settings") or {},
    }


def _repo_root() -> Path:
    """The dotfiles repo root that holds the three registries + ``.env``.

    Mirrors :func:`agent_profile.discover.search_roots` — ``DOTFILES_DIR``
    with the same ``$HOME/Dev/dotfiles`` default."""
    return Path(os.environ.get("DOTFILES_DIR") or str(Path.home() / "Dev/dotfiles"))


def _expand_registries_directive(
    directive: Any,
) -> dict[str, list[dict[str, Any]]]:
    """Expand a profile's ``registries:`` directive into item lists.

    Returns empty lists when the directive is absent. Reads the registries
    relative to the dotfiles repo root and resolves ``${VAR}`` env refs from
    ``$DOTFILES_DIR/.env`` (spec D4). The registry items carry the repo root
    as their ``_source_dir`` (not the profile dir) since their payload files
    live under the repo, not the profile."""
    if not directive:
        return {"mcps": [], "agents": [], "skills": [], "hooks": []}
    if not isinstance(directive, dict):
        raise ParseError(
            "ap_parse_one: 'registries' must be a mapping of "
            "section -> registry path(s)"
        )
    repo_root = _repo_root()
    dotenv = load_dotenv(repo_root / ".env")
    return expand_registries(directive, repo_root, dotenv)


def _merge_two(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    """Concatenate item arrays, deep-merge settings.

    ``permissions_allow`` is unioned then sorted+deduped (jq ``unique``
    sorts), and dropped when the result is empty. Port of ``_ap_merge_two``.
    """
    a_settings = a.get("settings") or {}
    b_settings = b.get("settings") or {}
    # jq's `*` recursive merge: b wins on scalar/object collisions.
    settings = {**a_settings, **b_settings}

    perms = sorted(
        set(a_settings.get("permissions_allow") or [])
        | set(b_settings.get("permissions_allow") or [])
    )
    if perms:
        settings["permissions_allow"] = perms
    else:
        settings.pop("permissions_allow", None)

    return {
        "mcps": a.get("mcps", []) + b.get("mcps", []),
        "agents": a.get("agents", []) + b.get("agents", []),
        "skills": a.get("skills", []) + b.get("skills", []),
        "commands": a.get("commands", []) + b.get("commands", []),
        "hooks": a.get("hooks", []) + b.get("hooks", []),
        "settings": settings,
    }


def _parse_with_includes(
    profile_dir: Path, visited: list[str], find_profile_dir: Any
) -> dict[str, Any]:
    """DFS over the include graph; cycle errors loudly.

    ``visited`` tracks the current resolution stack by absolute path. The
    bash uses subshell recursion, so cycle detection is current-stack
    scoped (a diamond DAG is allowed). We replicate that by passing a
    fresh copy of ``visited`` into each branch.
    """
    canonical = str(profile_dir)
    if canonical in visited:
        raise ParseError(
            f"ap_parse_manifest: include cycle detected at {canonical}"
        )
    visited = visited + [canonical]

    self_ = parse_one(profile_dir)

    merged: dict[str, Any] = {
        "mcps": [],
        "agents": [],
        "skills": [],
        "commands": [],
        "hooks": [],
        "settings": {},
    }

    for inc in self_.get("include") or []:
        inc_dir = find_profile_dir(inc)
        if inc_dir is None:
            raise ParseError(
                f"ap_parse_manifest: include '{inc}' not found "
                f"(from {canonical})"
            )
        inc_json = _parse_with_includes(inc_dir, visited, find_profile_dir)
        merged = _merge_two(merged, inc_json)

    merged = _merge_two(merged, self_)
    merged["name"] = self_["name"]
    merged["description"] = self_["description"]
    # Launch-overlay fields belong to the outermost profile (not merged
    # from includes), mirroring name/description.
    for key in (
        "isolated",
        "system_prompt",
        "tools",
        "permissions_deny",
        "permissions_allow",
        "enabled_plugins",
        "env",
        "extra_args",
        "target_default",
        "marketplaces",
        "mcp_scope",
    ):
        merged[key] = self_[key]
    return merged


def parse_manifest(profile_dir: Path, find_profile_dir: Any = None) -> Manifest:
    """Resolve a profile (with includes) into a :class:`Manifest`.

    ``find_profile_dir`` maps an include name to its profile dir (returns
    ``None`` if not found). Defaults to :func:`agent_profile.discover.find_profile_dir`
    bound to the current search roots. Port of ``ap_parse_manifest``.
    """
    if find_profile_dir is None:
        from agent_profile.discover import find_profile_dir as _fpd

        find_profile_dir = _fpd

    profile_dir = profile_dir.resolve()
    merged = _parse_with_includes(profile_dir, [], find_profile_dir)
    return Manifest(
        name=merged["name"],
        description=merged["description"],
        mcps=merged["mcps"],
        agents=merged["agents"],
        skills=merged["skills"],
        commands=merged["commands"],
        hooks=merged["hooks"],
        settings=merged["settings"],
        isolated=merged["isolated"],
        system_prompt=merged["system_prompt"],
        tools=merged["tools"],
        permissions_deny=merged["permissions_deny"],
        permissions_allow=merged["permissions_allow"],
        enabled_plugins=merged["enabled_plugins"],
        env=merged["env"],
        extra_args=merged["extra_args"],
        target_default=merged["target_default"],
        marketplaces=merged["marketplaces"],
        mcp_scope=merged["mcp_scope"],
    )
