"""ingest.py — expand a ``registries:`` directive into profile item lists.

The ``base`` profile (spec curd 1) declares::

    registries:
      mcps:   agents/mcp/registry.yaml
      skills: [skills/_registry.yaml, skills/]
      hooks:  agents/hooks/registry.yaml

instead of inline ``mcps:`` / ``skills:`` / ``hooks:`` lists. This module is
the *only* reader of the three separate registries — they stay the per-type
edit surface (``mcp-edit`` / ``hook-edit`` / ``skill-edit``); ``base`` just
unions them.

:func:`expand_registries` reads each declared registry relative to the repo
root, normalizes every entry into a profile *item* (the registry entry IS a
profile item — no translation layer), stamps ``_source_dir`` so payload
files resolve against the repo root, resolves ``${VAR}`` env refs at ingest
time (spec D4), and drops ``optional`` MCPs whose referenced credential is
unset (parity with the bash ``optional`` skip).

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
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from agent_profile.env import first_unset_var, resolve_item_env


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
    blocks resolve at ingest. An ``optional`` MCP whose referenced ``${VAR}``
    is unset is dropped non-fatally; a required MCP with an unset ref fails
    loud via :func:`resolve_item_env`."""
    data = _load_yaml_mapping(path)
    mcps = data.get("mcps") or {}
    out: list[dict[str, Any]] = []
    for name, body in mcps.items():
        if not isinstance(body, dict):
            continue
        item: dict[str, Any] = {"name": name, **body, "_source_dir": source_dir}
        if item.get("optional") and first_unset_var(item, dotenv) is not None:
            continue
        out.append(resolve_item_env(item, dotenv))
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


def _expand_external_skills(
    path: Path, source_dir: str
) -> list[dict[str, Any]]:
    """Normalize ``_registry.yaml`` ``sources:`` into ``source:`` skill items.

    A source with an explicit ``skills:`` list yields one item per named
    skill (each carrying the shared ``pin``); a source without one yields a
    single repo-level item whose names are resolved at fetch time by
    ``gh skill install`` (auto-discovery)."""
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


def expand_registries(
    directive: dict[str, Any],
    repo_root: Path,
    dotenv: dict[str, str],
) -> dict[str, list[dict[str, Any]]]:
    """Expand a ``registries:`` directive into ``{mcps, skills, hooks}`` item
    lists, each item carrying ``_source_dir = str(repo_root)``.

    ``directive`` maps each section to a registry path (or, for skills, a
    list of paths: the external registry plus the local tree). ``dotenv``
    resolves ``${VAR}`` env refs at ingest (spec D4). Sections absent from
    the directive yield empty lists."""
    repo_root = Path(repo_root)
    source_dir = str(repo_root)
    out: dict[str, list[dict[str, Any]]] = {"mcps": [], "skills": [], "hooks": []}

    mcps_path = directive.get("mcps")
    if mcps_path:
        out["mcps"] = _expand_mcps(repo_root / mcps_path, source_dir, dotenv)

    hooks_path = directive.get("hooks")
    if hooks_path:
        out["hooks"] = _expand_hooks(repo_root / hooks_path, source_dir, dotenv)

    skills_paths = _as_list(directive.get("skills"))
    if skills_paths:
        out["skills"] = _expand_skills(skills_paths, repo_root, source_dir)

    return out
