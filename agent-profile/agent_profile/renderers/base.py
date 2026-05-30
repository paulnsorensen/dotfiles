"""base.py — the Renderer seam + shared helpers for all five harness renderers.

This module is the public contract the five harness-renderer curds
(claude, codex, opencode, cursor, copilot) build on. It defines the
:class:`Renderer` protocol and the helpers that replace the repeated bash
``jq``-extraction loop so each renderer inherits them instead of
re-deriving membership filtering and MCP projection.

Renderer protocol contract
---------------------------
A renderer is an object exposing:

  - ``name: str`` — the harness name (``"claude"``, ``"codex"``, …).
  - ``render(manifest, target) -> list[str]`` — write this harness's
    artefacts under ``target`` and return the list of relative paths
    written (whole-file artefacts only; merged files such as
    ``opencode.json`` are *not* listed — they are surgically undone in
    ``clean``). The returned list feeds the install manifest, so it must
    contain each path at most once.
  - ``clean(manifest, target) -> None`` — surgically un-merge this
    harness's contributions to shared/merged files (e.g. drop the
    profile's entries from ``.codex/config.toml``'s ``[mcp_servers]``).
    Whole-file artefacts are removed by the CLI's manifest sweep, so a
    renderer with no merged files has a no-op ``clean``.

``render`` and ``clean`` receive the *resolved* :class:`~agent_profile.parse.Manifest`
(includes already flattened, each item carrying ``_source_dir``).

Substrate rules (from the spec): stdlib :mod:`json` for all JSON (own
your keys, ``del``/``pop`` for surgical removal); :mod:`tomlkit` for all
TOML (round-trip). No ``jq``/``yq`` anywhere.

Harness-default semantics
-------------------------
The bash filters each section by ``(.harnesses // <default>)``. The
default differs per surface, so :func:`mcps_for` takes the default list as
a required argument — the renderer curd passes the default its bash
counterpart used. ``DEFAULT_HOOK_HARNESSES`` captures the claude-only hook
default that every renderer shares.
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

import tomlkit

from agent_profile._validate import ParseError
from agent_profile.parse import Manifest
from agent_profile.shared import track_file
from agent_profile.templating import render_mcp_for_harness

# Hooks default to claude-only membership across every renderer.
DEFAULT_HOOK_HARNESSES = ("claude",)


class MergedConfigError(Exception):
    """Raised when a user-editable merged config (``opencode.json``,
    ``.cursor/mcp.json``, ``.copilot/mcp-config.json``) is present but not a
    JSON object. Mirrors :class:`~agent_profile.manifest.ManifestCorrupt`:
    surfaces a clean stderr line + exit 1 instead of an uncaught
    ``JSONDecodeError`` traceback. Caught by ``cli.main``."""


@runtime_checkable
class Renderer(Protocol):
    """The contract every harness renderer satisfies. See module docstring."""

    name: str

    def render(self, manifest: Manifest, target: Path) -> list[str]:
        """Write artefacts under ``target``; return relative paths written."""
        ...

    def clean(self, manifest: Manifest, target: Path) -> None:
        """Surgically un-merge this harness's shared/merged-file entries."""
        ...


def item_harnesses(item: dict[str, Any], default: tuple[str, ...]) -> list[str]:
    """Return ``item``'s harness membership list, applying ``default`` when
    the item omits ``harnesses``. Replaces the bash ``(.harnesses // [...])``
    fallback."""
    value = item.get("harnesses")
    if value is None:
        return list(default)
    return list(value)


def includes_harness(
    item: dict[str, Any], harness: str, default: tuple[str, ...]
) -> bool:
    """True iff ``harness`` is in ``item``'s (defaulted) membership list.
    Replaces the bash ``(.harnesses // [...]) | index(h) != null``."""
    return harness in item_harnesses(item, default)


def gate_blocks(item: dict[str, Any], harness: str) -> bool:
    """True iff ``item``'s ``gate_unless`` gate suppresses it for ``harness``.

    Ports the claude-only bash filter::

        map(select((.value.gate_unless // "") as $g | $g == "" or (env[$g] // "false") != "true"))

    The gate is claude-scoped: codex/opencode/cursor/copilot ignore it (a
    plugin-provided MCP is a claude concern). An item is blocked when it
    carries a ``gate_unless`` var that is exactly ``"true"`` in the process
    environment (the cheese-flow plugin seeds ``CHEESE_FLOW``), matching the
    bash ``env[$g]`` read — not the ``.env`` file."""
    if harness != "claude":
        return False
    gate = item.get("gate_unless")
    if not gate:
        return False
    return os.environ.get(gate, "false") == "true"


def mcps_for(
    manifest: Manifest,
    harness: str,
    default: tuple[str, ...],
) -> list[dict[str, Any]]:
    """Project the manifest's MCPs to those a ``harness`` should receive.

    This is the shared replacement for the per-renderer jq loop::

        [.mcps[] | select((.harnesses // <default>) | index("<h>") != null)]

    The renderer curd passes the ``default`` its bash counterpart used.
    Claude additionally drops ``gate_unless`` MCPs whose gate var is set
    (see :func:`gate_blocks`) — parity with ``mcp_filter_for_harness``.

    Returned entries are rendered through :func:`render_mcp_for_harness`
    so per-harness Go templates (``{{ $h }}``, ``{{ if eq $h "claude" }}``)
    in ``args``/``env`` resolve to the harness's value — the render the
    retired ``agents/mcp/sync.sh`` used to do once per harness."""
    return [
        render_mcp_for_harness(mcp, harness)
        for mcp in manifest.mcps
        if includes_harness(mcp, harness, default)
        and not gate_blocks(mcp, harness)
    ]


def hooks_for(
    manifest: Manifest,
    harness: str,
    default: tuple[str, ...] = DEFAULT_HOOK_HARNESSES,
) -> list[dict[str, Any]]:
    """Project the manifest's hooks to those a ``harness`` should receive.

    Shared replacement for the per-renderer jq hook-membership filter."""
    return [
        hook
        for hook in manifest.hooks
        if includes_harness(hook, harness, default)
    ]


def mcp_server_entry(
    mcp: dict[str, Any], *, extra: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Project one MCP item to the common ``{command, args?, env?}`` server
    record shared by the claude/.mcp.json, cursor/mcp.json and
    copilot/mcp-config.json shapes.

    ``args`` and ``env`` are included only when present (matching the bash
    ``if .args then {args:.args} else {} end``). ``extra`` lets a renderer
    fold in harness-specific keys (e.g. copilot's mandatory
    ``{"tools": ["*"]}``)."""
    entry: dict[str, Any] = {"command": mcp["command"]}
    if mcp.get("args") is not None:
        entry["args"] = mcp["args"]
    if mcp.get("env") is not None:
        entry["env"] = mcp["env"]
    if extra:
        entry.update(extra)
    return entry


def shared_asset_relpath(asset: str) -> str:
    """Map a repo-relative ``shared_assets`` entry to its harness-root-relative
    deploy path.

    The registry declares assets as ``agents/<subdir>/<file>``; chezmoi deploys
    them to ``~/.<harness>/<subdir>/<file>`` so the self-locating hook script
    finds them at ``$(dirname SCRIPT_DIR)/<subdir>/<file>``. We replicate that
    by dropping the leading repo subdir (``agents/``) and keeping the
    remainder. Entries with no leading subdir pass through unchanged."""
    parts = Path(asset).parts
    if len(parts) <= 1:
        return asset
    return str(Path(*parts[1:]))


def copy_hook_shared_assets(
    hook: dict[str, Any],
    harness_root: Path,
    base: Path,
    out_files: list[str],
) -> None:
    """Copy a hook's ``shared_assets`` to ``<harness_root>/<subdir>/<file>``.

    Each asset is read relative to the hook's ``_source_dir`` and written
    under ``harness_root`` at the path :func:`shared_asset_relpath` derives,
    so the self-locating SessionStart script resolves its lib/bank. Missing
    assets fail loud (a hook that ships a ``shared_assets`` ref but no file is
    a profile bug, not a silent skip). Tracked relative to ``base`` for the
    install manifest sweep."""
    for asset in hook.get("shared_assets") or []:
        src = Path(hook["_source_dir"]) / asset
        if not src.is_file():
            raise FileNotFoundError(f"hook shared_asset not found: {src}")
        dst = harness_root / shared_asset_relpath(asset)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        track_file(out_files, str(dst.relative_to(base)))


def body_abs(item: dict[str, Any], body_key: str = "body_path") -> Path | None:
    """Resolve an item's body file against its ``_source_dir``.

    Returns the absolute path when a body is declared and the file exists.
    Returns ``None`` when no body is declared — an optional body the renderer
    legitimately skips (the bash treated a missing ``body_path`` as "skip the
    body").

    A *declared* ``body_path`` that does not resolve is a registry/profile bug,
    not an optional body: raise :class:`ParseError` so ``ap install`` fails
    loud (clean stderr + exit 1 via ``cli.main``) instead of silently shipping
    a body-less item — e.g. a typo'd agent ``body_path`` would otherwise emit a
    frontmatter-only file and skip the user-scoped shared write with no error."""
    body_rel = item.get(body_key) or ""
    if not body_rel:
        return None
    candidate = Path(item["_source_dir"]) / body_rel
    if not candidate.is_file():
        raise ParseError(
            f"ap: {item.get('name', '?')!r} declares {body_key} "
            f"{body_rel!r}, but it does not resolve to a file under "
            f"{item['_source_dir']}"
        )
    return candidate


def load_toml(path: Path) -> tomlkit.TOMLDocument:
    """Round-trip-load a TOML file (empty doc when absent). Renderers that
    merge into ``.codex/config.toml`` build on this so user keys, comments
    and ordering survive."""
    if path.is_file() and path.stat().st_size > 0:
        return tomlkit.parse(path.read_text())
    return tomlkit.document()


def dump_toml(path: Path, doc: tomlkit.TOMLDocument) -> None:
    """Write a tomlkit document back to ``path``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(tomlkit.dumps(doc))


def read_json_object(path: Path, label: str) -> dict[str, Any]:
    """Load an existing user-editable merged-config JSON object.

    The merged-file renderers (opencode/cursor/copilot) read configs the
    user may hand-edit. A corrupt or non-object file raises
    :class:`MergedConfigError` (caught by ``cli.main`` → clean stderr +
    exit 1) instead of an uncaught ``JSONDecodeError`` / ``AttributeError``
    traceback. The caller is responsible for the absent-file default
    (these renderers bootstrap differently), so ``path`` must exist."""
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise MergedConfigError(
            f"ap: {label} at {path} is corrupt: {exc}"
        )
    if not isinstance(data, dict):
        raise MergedConfigError(
            f"ap: {label} at {path} is corrupt: top-level must be an object"
        )
    return data
