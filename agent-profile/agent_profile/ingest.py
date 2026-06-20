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

import logging
import subprocess
from pathlib import Path, PurePosixPath
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


def _resolve_market_relative(base: Path, rel: object, *, kind: str, plugin: str) -> Path:
    """Join a marketplace-relative POSIX path (``source`` or ``metadata.pluginRoot``)
    onto ``base``.

    Normalizes via ``PurePosixPath`` — ``lstrip("./")`` is a char-set strip, not a
    prefix strip, so it mangles dot-prefixed names. Absolute paths and ``..``
    traversal are rejected loud rather than silently collapsed. An empty ``rel``
    resolves to ``base`` unchanged.
    """
    from agent_profile._validate import ParseError

    if not isinstance(rel, str):
        raise ParseError(
            f"ap: plugin '{plugin}': marketplace.json {kind} must be a string, "
            f"got {type(rel).__name__}."
        )
    rel_path = PurePosixPath(rel)
    if rel_path.is_absolute() or ".." in rel_path.parts:
        raise ParseError(
            f"ap: plugin '{plugin}': marketplace.json {kind} {rel!r} "
            f"must be a relative path without '..' components."
        )
    return base.joinpath(*rel_path.parts) if rel_path.parts else base


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


def _resolve_git_plugin(url: str, branch: str, cache_dir: Path) -> Path:
    """Clone or refresh a git plugin repo into ``cache_dir``.

    Shallow clone on first visit; fetch+reset on subsequent visits. If the
    network fails but a populated cache exists, warns and returns the cache
    (so ``ap install base`` does not abort on non-primary machines with no
    network access to the repo). If neither clone nor cache yields content,
    the caller's marketplace.json check will raise ``ParseError``.

    Returns ``cache_dir`` (the marketplace root for this plugin).
    """
    log = logging.getLogger(__name__)
    if cache_dir.is_dir() and any(cache_dir.iterdir()):
        # Refresh existing cache.
        try:
            subprocess.run(
                ["git", "fetch", "--depth", "1", "origin", branch],
                cwd=cache_dir,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "reset", "--hard", f"origin/{branch}"],
                cwd=cache_dir,
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as exc:
            log.warning(
                "ap: git plugin refresh failed for %s branch %s — using cached copy. "
                "Error: %s",
                url,
                branch,
                exc.stderr.decode(errors="replace").strip() if exc.stderr else str(exc),
            )
    else:
        # Fresh clone.
        cache_dir.parent.mkdir(parents=True, exist_ok=True)
        try:
            subprocess.run(
                ["git", "clone", "--depth", "1", "--branch", branch, url, str(cache_dir)],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as exc:
            # No cache — let marketplace.json check below raise ParseError.
            log.warning(
                "ap: git plugin clone failed for %s branch %s — no cache available. "
                "Error: %s",
                url,
                branch,
                exc.stderr.decode(errors="replace").strip() if exc.stderr else str(exc),
            )
    return cache_dir


def _expand_plugins(
    path: Path,
    repo_root: Path,
    dotenv: dict[str, str],
    cache_root: Path | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """Decompose every plugin in ``agents/plugins/registry.yaml`` into its
    constituent primitives.

    Path model (mirrors real milknado layout):
      - ``path:`` in the registry is the **marketplace root** — the directory
        that contains ``.claude-plugin/marketplace.json``.
      - Each ``plugins[].source`` entry in marketplace.json resolves a **payload
        root** relative to the marketplace root; ``.mcp.json`` and ``skills/``
        live at the payload root.
      - ``_source_dir`` on every emitted item is stamped at the **payload root**
        (not the marketplace root), since renderers resolve payload files via
        ``Path(item['_source_dir']) / item['path']``.

    Returns a tuple ``(mcps, skills, native_plugins)``:

    - ``mcps`` — one MCP item per server in each payload's ``.mcp.json``.
    - ``skills`` — one ``path:`` skill item per ``<name>/SKILL.md`` found
      under ``<payload>/skills/``, with ``_source_dir`` at the payload root.
    - ``native_plugins`` — one descriptor dict per ``claude_native: true``
      entry, carrying ``marketplace_root``, ``marketplace_name`` (from
      marketplace.json), and ``description`` for the claude renderer.
    """
    import json as _json
    from agent_profile._validate import ParseError
    data = _load_yaml_mapping(path)
    plugins = data.get("plugins") or {}
    out_mcps: list[dict[str, Any]] = []
    out_skills: list[dict[str, Any]] = []
    out_native: list[dict[str, Any]] = []
    _cache_root = cache_root or (Path.home() / ".cache" / "ap" / "plugins")

    for name, body in plugins.items():
        if not isinstance(body, dict):
            continue

        # ── Validate source: exactly one of git: or path: ──
        path_str = body.get("path")
        git_url = body.get("git")
        if bool(path_str) == bool(git_url):  # both set, or neither set
            raise ParseError(
                f"ap: plugin '{name}': exactly one of 'git:' or 'path:' is required "
                f"(got {'both' if path_str and git_url else 'neither'})."
            )

        if git_url:
            branch = str(body.get("branch") or "main")
            subdir_raw = body.get("subdir") or ""
            if isinstance(subdir_raw, str) and (PurePosixPath(subdir_raw).is_absolute() or
                    ".." in PurePosixPath(subdir_raw).parts):
                raise ParseError(
                    f"ap: plugin '{name}': subdir {subdir_raw!r} must be relative "
                    f"without '..' components."
                )
            cache_dir = _cache_root / name
            _resolve_git_plugin(str(git_url), branch, cache_dir)
            subdir_parts = PurePosixPath(subdir_raw).parts if subdir_raw else ()
            marketplace_root = cache_dir.joinpath(*subdir_parts) if subdir_parts else cache_dir
        else:
            if not path_str:
                continue
            marketplace_root = _resolve_plugin_path(str(path_str), repo_root)

        # ── Resolve marketplace root and read marketplace.json ──
        marketplace_json = marketplace_root / ".claude-plugin" / "marketplace.json"
        if not marketplace_json.is_file():
            raise ParseError(
                f"ap: plugin '{name}': expected marketplace.json at "
                f"{marketplace_json} but it was not found. "
                f"The marketplace root must contain .claude-plugin/marketplace.json."
            )
        try:
            market_data = _json.loads(marketplace_json.read_text())
        except Exception as exc:
            raise ParseError(
                f"ap: plugin '{name}': failed to parse {marketplace_json}: {exc}"
            ) from exc

        marketplace_name: str = market_data.get("name") or name
        harnesses: list[str] = _as_list(body.get("harnesses"))
        gate_unless = body.get("gate_unless")
        claude_native = bool(body.get("claude_native", False))
        codex_native = bool(body.get("codex_native", False))
        description = body.get("description") or ""

        # `metadata.pluginRoot` (optional) is a base dir prefixed onto every
        # plugins[].source — Claude's own marketplace loader honors it, so the
        # decomposer must too. e.g. hallouminate: pluginRoot "./plugins" + source
        # "./hallouminate" → payload at <market>/plugins/hallouminate.
        meta = market_data.get("metadata")
        plugin_root = (meta.get("pluginRoot") if isinstance(meta, dict) else "") or ""
        payload_base = (
            _resolve_market_relative(
                marketplace_root, plugin_root, kind="metadata.pluginRoot", plugin=name
            )
            if plugin_root
            else marketplace_root
        )

        # Decompose only the payload whose marketplace.json name matches this
        # registry entry. The registry schema says each entry names one plugin,
        # so a multi-plugin marketplace must not double-expand every payload.
        matched = False
        for plugin_entry in market_data.get("plugins") or []:
            if not isinstance(plugin_entry, dict):
                continue
            if plugin_entry.get("name") != name:
                continue
            matched = True
            # `source` resolves relative to the marketplace root — or to
            # marketplace_root/<metadata.pluginRoot> when that optional field is
            # set (payload_base). Absolute paths and `..` traversal are rejected
            # loud by _resolve_market_relative.
            payload_root = _resolve_market_relative(
                payload_base,
                plugin_entry.get("source") or "",
                kind="source",
                plugin=name,
            )
            source_dir = str(payload_root)

            # ── MCP decomposition from .mcp.json ──
            mcp_file = payload_root / ".mcp.json"
            if mcp_file.is_file():
                try:
                    raw_mcp = _json.loads(mcp_file.read_text())
                except Exception as exc:
                    # Fail loud (parity with the marketplace.json handler above):
                    # a malformed .mcp.json silently dropping every MCP server is a
                    # silent-breakage trap.
                    raise ParseError(
                        f"ap: plugin '{name}': failed to parse {mcp_file}: {exc}"
                    ) from exc
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
                    # C-var: validate env vars (mirrors _expand_mcps behaviour).
                    unset = first_unset_var(item, dotenv)
                    if unset is not None:
                        if server_body.get("optional"):
                            continue
                        raise EnvResolutionError(
                            f"ap: plugin '{name}' server '{server_name}': "
                            f"env var ${{{unset}}} is unset "
                            f"(set it in .env or mark the server optional)"
                        )
                    if server_body.get("optional") is not None:
                        item["optional"] = server_body["optional"]
                    # DEDUP: for a harness whose native install delivers the
                    # plugin (claude_native / codex_native), remove that harness
                    # from the decomposed MCP harnesses — the harness gets the
                    # plugin via its native marketplace install, not bare user MCP.
                    effective_harnesses = harnesses
                    if harnesses:
                        skip = set()
                        if claude_native:
                            skip.add("claude")
                        if codex_native:
                            skip.add("codex")
                        if skip:
                            effective_harnesses = [
                                h for h in harnesses if h not in skip
                            ]
                    if effective_harnesses:
                        item["harnesses"] = effective_harnesses
                    elif harnesses and not effective_harnesses:
                        # All harnesses were native-only; emit empty list so the
                        # item exists but renderers' harnesses-filter skips it.
                        item["harnesses"] = []
                    if gate_unless:
                        item["gate_unless"] = gate_unless
                    out_mcps.append(item)

            # ── Skills decomposition from skills/ tree ──
            # _expand_local_skills stamps source_dir from its parameter; it uses
            # tree.name as the rel_root prefix, so 'path' becomes 'skills/<name>'.
            skills_tree = payload_root / "skills"
            plugin_skills = _expand_local_skills(skills_tree, source_dir)
            if claude_native:
                for skill in plugin_skills:
                    skill["_from_native_plugin"] = True
            if codex_native:
                # Separate flag from claude's: reusing _from_native_plugin would
                # make the claude renderer wrongly skip a codex-only-native
                # plugin's skills. Two independent flags, one per native path.
                for skill in plugin_skills:
                    skill["_from_codex_native_plugin"] = True
            out_skills.extend(plugin_skills)

        # Fail loud when the registry key matched no marketplace plugin. Without
        # this, the plugin silently decomposes to nothing — and a claude_native
        # entry would still register a marketplace below with no primitives behind
        # it (the same silent-breakage class the loud guards above prevent).
        if not matched:
            available = [
                p.get("name")
                for p in market_data.get("plugins") or []
                if isinstance(p, dict)
            ]
            raise ParseError(
                f"ap: plugin '{name}': no plugins[] entry named '{name}' in "
                f"{marketplace_json} (found: {available}). The registry key must "
                f"match a plugins[].name in marketplace.json."
            )

        # ── Native plugin descriptor (claude / codex renderer passes) ──
        # Carried once per registry entry (not per payload): the marketplace
        # root and canonical marketplace name are what the renderers need.
        # Carries both native booleans; each renderer consumes only its own.
        if claude_native or codex_native:
            out_native.append(
                {
                    "name": name,
                    "claude_native": claude_native,
                    "codex_native": codex_native,
                    "marketplace_root": str(marketplace_root),
                    "marketplace_name": marketplace_name,
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
        # MCP-name collision check: same guard as skills above. An unguarded
        # plugin MCP name matching a registry (or other plugin) server would
        # silently shadow it — last writer wins in each renderer's servers dict.
        existing_mcp_names = {m["name"] for m in out["mcps"] if m.get("name")}
        for mcp in plugin_mcps:
            mn = mcp.get("name")
            if mn and mn in existing_mcp_names:
                raise ParseError(
                    f"ap: plugin MCP name collision: '{mn}' is already"
                    " present in the MCP registry. Rename the plugin"
                    " MCP server or the colliding registry entry."
                )
            if mn:
                existing_mcp_names.add(mn)
        out["mcps"].extend(plugin_mcps)
        out["skills"].extend(plugin_skills)
        out["native_plugins"].extend(native)

    return out
