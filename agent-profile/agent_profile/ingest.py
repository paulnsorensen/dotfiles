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
  - **Plugins** (``plugins: {name: {path, harnesses, claude_native,
    codex_native, gate_unless, description}}``) — a 5th registry that
    auto-decomposes each plugin's payload into MCP, skills, agents, and hooks
    items. Commands are intentionally unsupported on the decomposed path.
    ``_source_dir`` on every emitted item is stamped at the **plugin payload
    root**, not the repo root, so renderers resolve payload files correctly.
    Native entries additionally produce a ``native_plugins`` record so native
    renderers can register the marketplace.
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


def _as_csv_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [part.strip() for part in value.split(",") if part.strip()]
    return list(value)


_AGENT_HARNESSES = ("claude", "codex", "opencode", "cursor", "copilot")
_SKILL_HARNESSES = ("claude", "codex", "opencode", "cursor", "copilot")
_HOOK_HARNESSES = ("claude", "codex", "cursor", "copilot")
_COMMAND_HOOK_HARNESSES = ("claude", "codex")


def _effective_plugin_harnesses(
    requested: list[str],
    supported: tuple[str, ...],
    *,
    claude_native: bool,
    codex_native: bool,
) -> list[str]:
    out = [h for h in (requested or list(supported)) if h in supported]
    if claude_native:
        out = [h for h in out if h != "claude"]
    if codex_native:
        out = [h for h in out if h != "codex"]
    return out


def _parse_plugin_agent_frontmatter(path: Path, plugin: str) -> dict[str, Any]:
    from agent_profile._validate import ParseError

    text = path.read_text()
    if not text.startswith("---"):
        return {}
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        return {}
    end = next((i for i, line in enumerate(lines[1:], start=1) if line == "---"), None)
    if end is None:
        raise ParseError(f"ap: plugin '{plugin}': unterminated YAML frontmatter in {path}")
    try:
        data = yaml.safe_load("\n".join(lines[1:end])) or {}
    except Exception as exc:
        raise ParseError(f"ap: plugin '{plugin}': failed to parse {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ParseError(f"ap: plugin '{plugin}': YAML frontmatter in {path} must be a mapping")
    return data


def _plugin_agents(
    plugin: str,
    payload_root: Path,
    source_dir: str,
    harnesses: list[str],
    *,
    claude_native: bool,
    codex_native: bool,
) -> list[dict[str, Any]]:
    agents_dir = payload_root / "agents"
    if not agents_dir.is_dir():
        return []

    out: list[dict[str, Any]] = []
    effective_harnesses = _effective_plugin_harnesses(
        harnesses,
        _AGENT_HARNESSES,
        claude_native=claude_native,
        codex_native=codex_native,
    )
    for agent_file in sorted(agents_dir.glob("*.md")):
        frontmatter = _parse_plugin_agent_frontmatter(agent_file, plugin)
        item: dict[str, Any] = {
            "name": str(frontmatter.get("name") or agent_file.stem),
            "body_path": f"agents/{agent_file.name}",
            "_source_dir": source_dir,
            "harnesses": effective_harnesses,
        }
        for key in ("description", "color", "effort"):
            if frontmatter.get(key) is not None:
                item[key] = frontmatter[key]
        for key in ("tools", "disallowedTools", "skills"):
            if frontmatter.get(key) is not None:
                item[key] = _as_csv_list(frontmatter[key])

        models: dict[str, Any] = {}
        if frontmatter.get("model") is not None:
            models["claude"] = frontmatter["model"]
        if frontmatter.get("models") is not None:
            if not isinstance(frontmatter["models"], dict):
                from agent_profile._validate import ParseError
                raise ParseError(
                    f"ap: plugin '{plugin}': frontmatter models in {agent_file} must be a mapping"
                )
            models.update(frontmatter["models"])
        if models:
            item["models"] = models

        if claude_native:
            item["_from_native_plugin"] = True
        if codex_native:
            item["_from_codex_native_plugin"] = True
        out.append(item)
    return out


def _safe_name_part(value: object) -> str:
    text = str(value)
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in text)
    return cleaned.strip("-") or "hook"


def _plugin_hook_script(command: str, payload_root: Path, plugin: str, manifest: Path) -> str | None:
    from agent_profile._validate import ParseError

    plugin_prefix = "${CLAUDE_PLUGIN_ROOT}/"
    candidates: list[PurePosixPath] = []
    strict = False
    if command.startswith(plugin_prefix):
        candidates.append(PurePosixPath(command[len(plugin_prefix):]))
        strict = True
    else:
        cmd_path = Path(command)
        hooks_root = (payload_root / "hooks").resolve()
        if cmd_path.is_absolute():
            try:
                rel = cmd_path.resolve().relative_to(hooks_root)
            except ValueError:
                return None
            script = PurePosixPath("hooks", *rel.parts).as_posix()
            if not (payload_root / script).is_file():
                raise ParseError(f"ap: plugin '{plugin}': hook script {cmd_path} from {manifest} was not found")
            return script
        candidates.append(PurePosixPath(command))

    for rel in candidates:
        if rel.is_absolute() or ".." in rel.parts or not rel.parts or rel.parts[0] != "hooks":
            return None
        script_path = payload_root.joinpath(*rel.parts)
        if script_path.is_file():
            return rel.as_posix()
        if strict or str(rel).startswith("hooks/"):
            raise ParseError(f"ap: plugin '{plugin}': hook script {script_path} from {manifest} was not found")
    return None


def _plugin_hooks(
    plugin: str,
    payload_root: Path,
    source_dir: str,
    harnesses: list[str],
    *,
    claude_native: bool,
    codex_native: bool,
) -> list[dict[str, Any]]:
    import json as _json
    from agent_profile._validate import ParseError

    manifest = payload_root / ".claude-plugin" / "plugin.json"
    if not manifest.is_file():
        return []
    try:
        data = _json.loads(manifest.read_text())
    except Exception as exc:
        raise ParseError(f"ap: plugin '{plugin}': failed to parse {manifest}: {exc}") from exc
    hooks = data.get("hooks") or {}
    if not isinstance(hooks, dict):
        raise ParseError(f"ap: plugin '{plugin}': hooks in {manifest} must be a mapping")

    script_harnesses = _effective_plugin_harnesses(
        harnesses,
        _HOOK_HARNESSES,
        claude_native=claude_native,
        codex_native=codex_native,
    )
    out: list[dict[str, Any]] = []
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            raise ParseError(f"ap: plugin '{plugin}': hooks[{event!r}] in {manifest} must be a list")
        for outer_index, outer in enumerate(entries):
            if not isinstance(outer, dict):
                raise ParseError(f"ap: plugin '{plugin}': hook entry {outer_index} in {manifest} must be a mapping")
            inner_hooks = outer.get("hooks") or []
            if not isinstance(inner_hooks, list):
                raise ParseError(f"ap: plugin '{plugin}': hook entry {outer_index} hooks in {manifest} must be a list")
            for inner_index, inner in enumerate(inner_hooks):
                if not isinstance(inner, dict) or inner.get("type") != "command":
                    continue
                command = inner.get("command")
                if not isinstance(command, str) or not command:
                    raise ParseError(f"ap: plugin '{plugin}': command hook in {manifest} is missing command")
                script = _plugin_hook_script(command, payload_root, plugin, manifest)
                if script:
                    item_harnesses = script_harnesses
                    if not item_harnesses:
                        continue
                    suffix = Path(script).stem
                    # name carries the (event, outer, inner) coordinate so it stays
                    # unique even when two hooks on one event share a script stem;
                    # the suffix is only a readability tag.
                    item: dict[str, Any] = {
                        "name": f"{plugin}-{_safe_name_part(event)}-{outer_index}-{inner_index}-{_safe_name_part(suffix)}",
                        "event": event,
                        "script": script,
                        "_source_dir": source_dir,
                        "harnesses": item_harnesses,
                    }
                else:
                    item_harnesses = _effective_plugin_harnesses(
                        harnesses,
                        _COMMAND_HOOK_HARNESSES,
                        claude_native=claude_native,
                        codex_native=codex_native,
                    )
                    if not item_harnesses:
                        continue
                    item = {
                        "name": f"{plugin}-{_safe_name_part(event)}-{outer_index}-{inner_index}",
                        "event": event,
                        "command": command,
                        "_source_dir": source_dir,
                        "harnesses": item_harnesses,
                    }
                if outer.get("matcher") is not None:
                    item["matcher"] = outer["matcher"]
                for key in ("timeout", "async"):
                    if inner.get(key) is not None:
                        item[key] = inner[key]
                out.append(item)
    return out

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
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
]:
    """Decompose plugin registry entries into MCPs, skills, agents, hooks, and native descriptors.

    The decomposed path intentionally omits commands; native plugin installs may
    still provide command behavior inside the native harness.
    """
    import json as _json
    from agent_profile._validate import ParseError

    data = _load_yaml_mapping(path)
    plugins = data.get("plugins") or {}
    out_mcps: list[dict[str, Any]] = []
    out_skills: list[dict[str, Any]] = []
    out_agents: list[dict[str, Any]] = []
    out_hooks: list[dict[str, Any]] = []
    out_native: list[dict[str, Any]] = []
    _cache_root = cache_root or (Path.home() / ".cache" / "ap" / "plugins")

    for name, body in plugins.items():
        if not isinstance(body, dict):
            continue

        path_str = body.get("path")
        git_url = body.get("git")
        if bool(path_str) == bool(git_url):
            raise ParseError(
                f"ap: plugin '{name}': exactly one of 'git:' or 'path:' is required "
                f"(got {'both' if path_str and git_url else 'neither'})."
            )

        if git_url:
            branch = str(body.get("branch") or "main")
            subdir_raw = body.get("subdir") or ""
            if isinstance(subdir_raw, str) and (
                PurePosixPath(subdir_raw).is_absolute()
                or ".." in PurePosixPath(subdir_raw).parts
            ):
                raise ParseError(
                    f"ap: plugin '{name}': subdir {subdir_raw!r} must be relative "
                    "without '..' components."
                )
            cache_dir = _cache_root / name
            _resolve_git_plugin(str(git_url), branch, cache_dir)
            subdir_parts = PurePosixPath(subdir_raw).parts if subdir_raw else ()
            marketplace_root = cache_dir.joinpath(*subdir_parts) if subdir_parts else cache_dir
        else:
            if not path_str:
                continue
            marketplace_root = _resolve_plugin_path(str(path_str), repo_root)

        marketplace_json = marketplace_root / ".claude-plugin" / "marketplace.json"
        if not marketplace_json.is_file():
            raise ParseError(
                f"ap: plugin '{name}': expected marketplace.json at "
                f"{marketplace_json} but it was not found. "
                "The marketplace root must contain .claude-plugin/marketplace.json."
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

        meta = market_data.get("metadata")
        plugin_root = (meta.get("pluginRoot") if isinstance(meta, dict) else "") or ""
        payload_base = (
            _resolve_market_relative(
                marketplace_root, plugin_root, kind="metadata.pluginRoot", plugin=name
            )
            if plugin_root
            else marketplace_root
        )

        matched = False
        for plugin_entry in market_data.get("plugins") or []:
            if not isinstance(plugin_entry, dict):
                continue
            if plugin_entry.get("name") != name:
                continue
            matched = True
            payload_root = _resolve_market_relative(
                payload_base,
                plugin_entry.get("source") or "",
                kind="source",
                plugin=name,
            )
            source_dir = str(payload_root)

            mcp_file = payload_root / ".mcp.json"
            if mcp_file.is_file():
                try:
                    raw_mcp = _json.loads(mcp_file.read_text())
                except Exception as exc:
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
                    unset = first_unset_var(item, dotenv)
                    if unset is not None:
                        if server_body.get("optional"):
                            continue
                        raise EnvResolutionError(
                            f"ap: plugin '{name}' server '{server_name}': "
                            f"env var ${{{unset}}} is unset "
                            "(set it in .env or mark the server optional)"
                        )
                    if server_body.get("optional") is not None:
                        item["optional"] = server_body["optional"]
                    effective_harnesses = harnesses
                    if harnesses:
                        skip = set()
                        if claude_native:
                            skip.add("claude")
                        if codex_native:
                            skip.add("codex")
                        if skip:
                            effective_harnesses = [h for h in harnesses if h not in skip]
                    if effective_harnesses:
                        item["harnesses"] = effective_harnesses
                    elif harnesses and not effective_harnesses:
                        item["harnesses"] = []
                    if gate_unless:
                        item["gate_unless"] = gate_unless
                    out_mcps.append(item)

            skills_tree = payload_root / "skills"
            plugin_skills = _expand_local_skills(skills_tree, source_dir)
            skill_harnesses = _effective_plugin_harnesses(
                harnesses,
                _SKILL_HARNESSES,
                claude_native=claude_native,
                codex_native=codex_native,
            )
            for skill in plugin_skills:
                skill["harnesses"] = skill_harnesses
                if claude_native:
                    skill["_from_native_plugin"] = True
                if codex_native:
                    skill["_from_codex_native_plugin"] = True
            out_skills.extend(plugin_skills)

            out_agents.extend(
                _plugin_agents(
                    name,
                    payload_root,
                    source_dir,
                    harnesses,
                    claude_native=claude_native,
                    codex_native=codex_native,
                )
            )
            out_hooks.extend(
                _plugin_hooks(
                    name,
                    payload_root,
                    source_dir,
                    harnesses,
                    claude_native=claude_native,
                    codex_native=codex_native,
                )
            )

        if not matched:
            available = [
                p.get("name")
                for p in market_data.get("plugins") or []
                if isinstance(p, dict)
            ]
            raise ParseError(
                f"ap: plugin '{name}': no plugins[] entry named '{name}' in "
                f"{marketplace_json} (found: {available}). The registry key must "
                "match a plugins[].name in marketplace.json."
            )

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

    return out_mcps, out_skills, out_agents, out_hooks, out_native


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
        plugin_mcps, plugin_skills, plugin_agents, plugin_hooks, native = _expand_plugins(
            repo_root / plugins_path, repo_root, dotenv
        )
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

        existing_agent_names = {a["name"] for a in out["agents"] if a.get("name")}
        for agent in plugin_agents:
            an = agent.get("name")
            if an and an in existing_agent_names:
                raise ParseError(
                    f"ap: plugin agent name collision: '{an}' is already"
                    " present in the agents registry. Rename the plugin"
                    " agent or the registry entry."
                )
            if an:
                existing_agent_names.add(an)

        existing_hook_names = {h["name"] for h in out["hooks"] if h.get("name")}
        for hook in plugin_hooks:
            hn = hook.get("name")
            if hn and hn in existing_hook_names:
                raise ParseError(
                    f"ap: plugin hook name collision: '{hn}' is already"
                    " present in the hooks registry. Rename the plugin"
                    " hook or the registry entry."
                )
            if hn:
                existing_hook_names.add(hn)

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
        out["agents"].extend(plugin_agents)
        out["hooks"].extend(plugin_hooks)
        out["native_plugins"].extend(native)

    return out
