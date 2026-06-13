"""ingest.py — expand a ``registries:`` directive into profile item lists.

The ``base`` profile (spec curd 1) declares::

    registries:
      mcps:   agents/mcp/registry.yaml
      skills: [skills/_registry.yaml, skills/]
      hooks:  agents/hooks/registry.yaml
      plugins: agents/plugins/registry.yaml

instead of inline ``mcps:`` / ``skills:`` / ``hooks:`` lists. This module is
the *only* reader of the four separate registries — they stay the per-type
edit surface (``mcp-edit`` / ``hook-edit`` / ``skill-edit`` / ``plugin-edit``);
``base`` just unions them.

:func:`expand_registries` reads each declared registry relative to the repo
root, normalizes every entry into a profile *item* (the registry entry IS a
profile item — no translation layer), stamps ``_source_dir`` so payload
files resolve against the repo root, **validates** ``${VAR}`` env refs
without substituting them (MCP-secret-passthrough — the literal ``${VAR}``
rides through to each renderer so the harness expands it at launch and no
secret is baked to disk), and drops ``optional`` MCPs whose referenced
credential is unset (parity with the bash ``optional`` skip).

Registry shapes consumed:

  - **MCP** (``mcps: {name: {command, args, env, scope, gate_unless,
    optional, harnesses, description}}``) — a mapping keyed by name; each
    value becomes an item with ``name`` folded in. Carries the curd-2 parity
    fields (``scope``, ``gate_unless``, ``args_by_harness``) through verbatim
    for the renderers to consume.
  - **Hook** (``hooks: {name: {event, script, shared_assets, matcher,
    timeout, harnesses, description}}``) — same name-keyed mapping shape.
  - **Skills** — two sources unioned: the external ``_registry.yaml``
    (``sources: {OWNER/REPO: {description, pin, skills}}``) yields ``source:``
    items (one per explicitly-named skill, or one per repo when names are
    auto-discovered downstream), and the local ``skills/`` tree yields
    ``path:`` items for every ``<name>/SKILL.md`` present.
  - **Plugins** (``plugins: {name: {path, harnesses, claude_native, gate_unless,
    description}}``) — a 5th registry that auto-decomposes each plugin's payload
    (``path``) into MCP + skills items. ``_source_dir`` on every emitted item
    is stamped at the **plugin payload root**, not the repo root, so renderers
    resolve payload files correctly. Claude-native entries additionally produce
    a ``native_plugins`` record so the claude renderer can register the
    marketplace.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from agent_profile.env import (
    EnvResolutionError,
    first_unset_var,
    resolve_item_env,
)


def _as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    return list(value)


def _load_yaml_mapping(path: Path) -> dict[str, Any]:
    raw = yaml.safe_load(path.read_text()) or {}
    return raw if isinstance(raw, dict) else {}


def _expand_mcps(
    path: Path, source_dir: str, dotenv: dict[str, str]
) -> list[dict[str, Any]]:
    """Normalize the MCP registry mapping into a profile item list.

    Each named entry becomes ``{name, ...fields, _source_dir}``. ``env``
    blocks are **validated but not substituted**: the literal ``${VAR}`` is
    carried through to the renderers so each harness expands it at launch and
    no secret is baked into a rendered config file (the MCP-secret-passthrough
    spec). An ``optional`` MCP whose referenced ``${VAR}`` is unset is dropped
    non-fatally; a non-``optional`` MCP with an unset ref still fails loud at
    ingest (catches a typo'd var) — without substituting the value."""
    data = _load_yaml_mapping(path)
    mcps = data.get("mcps") or {}
    out: list[dict[str, Any]] = []
    for name, body in mcps.items():
        if not isinstance(body, dict):
            continue
        item: dict[str, Any] = {"name": name, **body, "_source_dir": source_dir}
        unset = first_unset_var(item, dotenv)
        if unset is not None:
            if item.get("optional"):
                continue
            raise EnvResolutionError(
                f"ap: env var ${{{unset}}} is unset (referenced by MCP "
                f"'{name}'; set it in .env or mark the item optional)"
            )
        out.append(item)
    return out


def _expand_hooks(
    path: Path, source_dir: str, dotenv: dict[str, str]
) -> list[dict[str, Any]]:
    """Normalize the hook registry mapping into a profile item list."""
    data = _load_yaml_mapping(path)
    hooks = data.get("hooks") or {}
    out: list[dict[str, Any]] = []
    for name, body in hooks.items():
        if not isinstance(body, dict):
            continue
        item = {"name": name, **body, "_source_dir": source_dir}
        out.append(resolve_item_env(item, dotenv))
    return out


def _expand_agents(
    path: Path, source_dir: str
) -> list[dict[str, Any]]:
    """Normalize the agent registry mapping into a profile item list.

    Same name-keyed shape as the MCP/hook registries: each ``<name>: {...}``
    entry becomes ``{name, ...fields, _source_dir}`` with ``_source_dir`` set
    to the repo root so ``body_path`` (e.g. ``agents/agent_definitions/<name>.md``)
    resolves against the repo, not the profile dir. No env resolution — agent
    metadata carries no ``${VAR}`` refs."""
    data = _load_yaml_mapping(path)
    agents = data.get("agents") or {}
    out: list[dict[str, Any]] = []
    for name, body in agents.items():
        if not isinstance(body, dict):
            continue
        out.append({"name": name, **body, "_source_dir": source_dir})
    return out


def _expand_external_skills(
    path: Path, source_dir: str
) -> list[dict[str, Any]]:
    """Normalize ``_registry.yaml`` ``sources:`` into ``source:`` skill items.

    A source with an explicit ``skills:`` list yields one item per named
    skill (each carrying the shared ``pin``); a source without one yields a
    single repo-level item that fetches every skill in the repo via
    ``npx skills add --skill '*'`` (the CLI's native auto-discovery)."""
    data = _load_yaml_mapping(path)
    sources = data.get("sources") or {}
    out: list[dict[str, Any]] = []
    for repo, body in sources.items():
        if body is None:
            body = {}  # bare `owner/repo:` → repo-level auto-discovery
        elif not isinstance(body, dict):
            continue  # malformed non-mapping body (typo) — skip, as MCP/hook readers do
        pin = body.get("pin")
        names = _as_list(body.get("skills"))
        if names:
            for name in names:
                item: dict[str, Any] = {
                    "name": name,
                    "source": repo,
                    "_source_dir": source_dir,
                }
                if pin:
                    item["pin"] = pin
                out.append(item)
        else:
            item = {"source": repo, "_source_dir": source_dir}
            if pin:
                item["pin"] = pin
            out.append(item)
    return out


def _expand_local_skills(
    tree: Path, source_dir: str
) -> list[dict[str, Any]]:
    """Yield a ``path:`` skill item for every ``<name>/SKILL.md`` under
    the local skills tree, in sorted name order. Dirs lacking ``SKILL.md``
    are not skills and are skipped."""
    out: list[dict[str, Any]] = []
    if not tree.is_dir():
        return out
    rel_root = tree.name
    for child in sorted(tree.iterdir()):
        if not child.is_dir():
            continue
        if not (child / "SKILL.md").is_file():
            continue
        out.append(
            {
                "name": child.name,
                "path": f"{rel_root}/{child.name}",
                "_source_dir": source_dir,
            }
        )
    return out


def _expand_skills(
    paths: list[str], repo_root: Path, source_dir: str
) -> list[dict[str, Any]]:
    """Union external (``_registry.yaml``) and local-tree skill items.

    Each declared skills path is either a file (the external registry) or a
    directory (the local tree); they are dispatched by suffix/kind."""
    out: list[dict[str, Any]] = []
    for rel in paths:
        target = repo_root / rel
        if rel.endswith(".yaml") or rel.endswith(".yml"):
            out.extend(_expand_external_skills(target, source_dir))
        else:
            out.extend(_expand_local_skills(target, source_dir))
    return out


def _resolve_plugin_path(path_str: str, repo_root: Path) -> Path:
    """Resolve a plugin ``path`` value to an absolute Path.

    Supports ``~``-expansion (home-relative), ``/``-absolute paths,
    and repo-relative paths. Mirrors the resolution in ``sync.sh``.
    """
    import os
    expanded = os.path.expandvars(os.path.expanduser(str(path_str)))
    p = Path(expanded)
    if p.is_absolute():
        return p
    return repo_root / expanded


def _expand_plugins(
    path: Path,
    repo_root: Path,
    dotenv: dict[str, str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """Decompose every plugin in ``agents/plugins/registry.yaml`` into its
    constituent primitives.

    Returns a tuple ``(mcps, skills, native_plugins)``:

    - ``mcps`` — one MCP item per server declared in the plugin's
      ``.mcp.json``, carrying the registry entry's ``harnesses`` and
      ``gate_unless``, and with ``_source_dir`` at the **payload root**.
    - ``skills`` — one ``path:`` skill item per ``<name>/SKILL.md`` found
      under ``<payload>/skills/``, with ``_source_dir`` at the **payload
      root** (not the repo root — this is the highest-risk correctness
      rule: renderers resolve ``Path(item['_source_dir']) / item['path']``).
    - ``native_plugins`` — one descriptor dict per ``claude_native: true``
      entry, carrying ``name``, ``claude_native``, ``payload_root``, and
      ``description`` so the claude renderer can register the marketplace.
    """
    import json as _json
    data = _load_yaml_mapping(path)
    plugins = data.get("plugins") or {}
    out_mcps: list[dict[str, Any]] = []
    out_skills: list[dict[str, Any]] = []
    out_native: list[dict[str, Any]] = []

    for name, body in plugins.items():
        if not isinstance(body, dict):
            continue
        path_str = body.get("path")
        if not path_str:
            continue
        payload_root = _resolve_plugin_path(str(path_str), repo_root)
        source_dir = str(payload_root)
        harnesses: list[str] = _as_list(body.get("harnesses"))
        gate_unless = body.get("gate_unless")
        claude_native = bool(body.get("claude_native", False))
        description = body.get("description") or ""

        # ── MCP decomposition from .mcp.json ──
        mcp_file = payload_root / ".mcp.json"
        if mcp_file.is_file():
            try:
                raw_mcp = _json.loads(mcp_file.read_text())
            except Exception:
                raw_mcp = {}
            for server_name, server_body in (raw_mcp.get("mcpServers") or {}).items():
                if not isinstance(server_body, dict):
                    continue
                item: dict[str, Any] = {
                    "name": server_name,
                    "command": server_body.get("command", ""),
                    "_source_dir": source_dir,
                }
                if server_body.get("args") is not None:
                    item["args"] = server_body["args"]
                if server_body.get("env") is not None:
                    item["env"] = server_body["env"]
                # DEDUP: for claude_native plugins, remove claude from decomposed
                # MCP harnesses — Claude gets the plugin via native marketplace
                # install (mcp__plugin_<name>_<server>__*), not bare user MCP.
                effective_harnesses = harnesses
                if claude_native and harnesses:
                    effective_harnesses = [h for h in harnesses if h != "claude"]
                if effective_harnesses:
                    item["harnesses"] = effective_harnesses
                elif harnesses and not effective_harnesses:
                    # All harnesses were claude-only; emit empty list so the
                    # item exists but renderers' harnesses-filter skips it.
                    item["harnesses"] = []
                if gate_unless:
                    item["gate_unless"] = gate_unless
                out_mcps.append(item)

        # ── Skills decomposition from skills/ tree ──
        # Reuse _expand_local_skills but with the payload root as the tree.
        # _expand_local_skills stamps source_dir from its parameter; it uses
        # tree.name as the rel_root prefix, so 'path' becomes 'skills/<name>'.
        skills_tree = payload_root / "skills"
        plugin_skills = _expand_local_skills(skills_tree, source_dir)
        if claude_native:
            for skill in plugin_skills:
                skill["_from_native_plugin"] = True
        out_skills.extend(plugin_skills)

        # ── Native plugin descriptor (claude renderer pass) ──
        if claude_native:
            out_native.append(
                {
                    "name": name,
                    "claude_native": True,
                    "payload_root": source_dir,
                    "description": description,
                }
            )

    return out_mcps, out_skills, out_native


def expand_registries(
    directive: dict[str, Any],
    repo_root: Path,
    dotenv: dict[str, str],
) -> dict[str, list[dict[str, Any]]]:
    """Expand a ``registries:`` directive into item lists.

    Returns ``{mcps, agents, skills, hooks, native_plugins}`` where each
    item carries ``_source_dir``.  Plugin-derived items stamp ``_source_dir``
    at the **plugin payload root** (not ``repo_root``) — every renderer
    resolves payload files via ``Path(item["_source_dir"]) / path``.

    ``directive`` maps each section to a registry path (or, for skills, a
    list of paths: the external registry plus the local tree). ``dotenv``
    resolves ``${VAR}`` env refs at ingest (spec D4). Sections absent from
    the directive yield empty lists."""
    repo_root = Path(repo_root)
    source_dir = str(repo_root)
    out: dict[str, list[dict[str, Any]]] = {
        "mcps": [],
        "agents": [],
        "skills": [],
        "hooks": [],
        "native_plugins": [],
    }

    mcps_path = directive.get("mcps")
    if mcps_path:
        out["mcps"] = _expand_mcps(repo_root / mcps_path, source_dir, dotenv)

    agents_path = directive.get("agents")
    if agents_path:
        out["agents"] = _expand_agents(repo_root / agents_path, source_dir)

    hooks_path = directive.get("hooks")
    if hooks_path:
        out["hooks"] = _expand_hooks(repo_root / hooks_path, source_dir, dotenv)

    skills_paths = _as_list(directive.get("skills"))
    if skills_paths:
        out["skills"] = _expand_skills(skills_paths, repo_root, source_dir)

    plugins_path = directive.get("plugins")
    if plugins_path:
        plugin_mcps, plugin_skills, native = _expand_plugins(
            repo_root / plugins_path, repo_root, dotenv
        )
        # Skill-name collision check: fail loud if any plugin skill name
        # collides with an already-collected skill name.
        from agent_profile._validate import ParseError
        existing_names = {s["name"] for s in out["skills"] if s.get("name")}
        for skill in plugin_skills:
            sn = skill.get("name")
            if sn and sn in existing_names:
                raise ParseError(
                    f"ap: plugin skill name collision: '{sn}' is already"
                    " present in the skills registry. Rename the plugin"
                    " skill or the registry entry."
                )
            if sn:
                existing_names.add(sn)
        out["mcps"].extend(plugin_mcps)
        out["skills"].extend(plugin_skills)
        out["native_plugins"].extend(native)

    return out
