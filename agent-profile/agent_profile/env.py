"""env.py — render-time ``${VAR}`` resolution from a ``.env`` mapping (spec D4).

The registries carry ``${VAR}`` env references on MCP ``env:`` blocks (and,
potentially, on skill/hook items). The bash sync resolved these at deploy
time from the process environment seeded by a ``.env`` loader; this module is
the Python parity:

  - :func:`load_dotenv` mirrors ``mcp_load_dotenv`` (skip blanks/comments,
    strip ``export`` and surrounding quotes, reject illegal identifiers,
    keep everything after the first ``=`` as the value).
  - :func:`resolve_env_value` expands every ``${VAR}`` in a string, failing
    loud (:class:`EnvResolutionError`) on the first unset reference — naming
    the missing var so the operator knows which credential to set.
  - :func:`first_unset_var` reports the first unset ``${VAR}`` an item's
    ``env`` block references, or ``None`` when all resolve. ``optional`` items
    use this to skip non-fatally (parity with ``_mcp_first_unset_env_var``).
  - :func:`resolve_item_env` returns an immutable-style copy of an item with
    its ``env`` values fully resolved.

Resolution is "fail fast and loud": an unset, non-optional ``${VAR}`` aborts
the render rather than emitting a half-configured server entry.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class EnvResolutionError(Exception):
    """Raised when a referenced ``${VAR}`` is unset and the item is not
    ``optional``. Carries the missing variable name so the operator can fix
    the ``.env``."""


def load_dotenv(path: Path) -> dict[str, str]:
    """Parse a ``.env`` file into a ``{KEY: value}`` mapping.

    Port of ``mcp_load_dotenv``: skip blank/comment lines, strip a leading
    ``export`` and surrounding single/double quotes from the value, reject
    keys that are not legal shell identifiers, and keep everything after the
    first ``=`` as the value (so ``TOKEN=a=b`` -> ``a=b``). A missing file
    yields an empty mapping (not an error)."""
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.split("=", 1)
        if len(line) != 2:
            continue
        key, val = line
        key = key.removeprefix("export ").lstrip()
        if not key or key.startswith("#"):
            continue
        if not _IDENT_RE.match(key):
            continue
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        out[key] = val
    return out


def resolve_env_value(value: str, dotenv: dict[str, str]) -> str:
    """Expand every ``${VAR}`` in ``value`` from ``dotenv``.

    Fails loud on the first unset reference (left-to-right), naming the
    missing variable. Strings with no reference pass through unchanged."""

    def _sub(match: re.Match[str]) -> str:
        var = match.group(1)
        if var not in dotenv:
            raise EnvResolutionError(
                f"ap: env var ${{{var}}} is unset (referenced at render time; "
                "set it in .env or mark the item optional)"
            )
        return dotenv[var]

    return VAR_RE.sub(_sub, value)


def first_unset_var(item: dict[str, Any], dotenv: dict[str, str]) -> str | None:
    """Return the first ``${VAR}`` an item's ``env`` block references that is
    unset in ``dotenv``, or ``None`` when every reference resolves.

    Used by ``optional`` items to decide whether to skip non-fatally (parity
    with the bash ``_mcp_first_unset_env_var``). Iterates ``env`` values in
    insertion order, then the references within each value left-to-right."""
    env = item.get("env")
    if not isinstance(env, dict):
        return None
    for val in env.values():
        for match in VAR_RE.finditer(str(val)):
            var = match.group(1)
            if var not in dotenv:
                return var
    return None


def resolve_item_env(
    item: dict[str, Any], dotenv: dict[str, str]
) -> dict[str, Any]:
    """Return a copy of ``item`` with its ``env`` values fully resolved.

    Items without an ``env`` block are returned unchanged. An unset,
    referenced ``${VAR}`` raises :class:`EnvResolutionError`, with the
    offending item's name folded into the message for operator context."""
    env = item.get("env")
    if not isinstance(env, dict):
        return item
    resolved: dict[str, Any] = {}
    for key, val in env.items():
        try:
            resolved[key] = resolve_env_value(str(val), dotenv)
        except EnvResolutionError as exc:
            name = item.get("name") or "<unnamed>"
            raise EnvResolutionError(f"{exc} (item '{name}')")
    out = dict(item)
    out["env"] = resolved
    return out
