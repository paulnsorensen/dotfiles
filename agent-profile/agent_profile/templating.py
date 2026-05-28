"""templating.py — per-harness Go-template render for MCP ``args`` and ``env``.

The MCP registry at ``agents/mcp/registry.yaml`` lets each entry branch
its arg or env values per harness via Go templates against ``$h``::

    serena:
      command: serena-mux
      env:
        SERENA_MUX_HARNESS: '{{ if eq $h "claude" }}claude-code{{ else }}{{ $h }}{{ end }}'

The retired ``agents/mcp/sync.sh`` ran the whole registry through ``chezmoi
execute-template`` once per harness (HARNESS=<harness>) before deploying.
The ``ap`` install path is the single deploy path now (the legacy sync
script is gone), so the same render has to live here.

Only values containing ``{{`` are shelled out — the common case is bare
strings, which incur zero subprocess overhead. A missing ``chezmoi``
binary falls back to returning the original value (the install proceeds
with the unrendered string surfaced via stderr so the breakage is
visible rather than silent).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from typing import Any

# Cache the chezmoi lookup. shutil.which is cheap but called per value;
# avoid re-walking $PATH for every MCP env entry on every install.
_chezmoi_bin: str | None = None
_chezmoi_warned: bool = False


def _resolve_chezmoi() -> str | None:
    global _chezmoi_bin
    if _chezmoi_bin is None:
        _chezmoi_bin = shutil.which("chezmoi") or ""
    return _chezmoi_bin or None


def _warn_missing_chezmoi(value: str) -> None:
    """Surface the fall-back once per process so the unrendered template
    leaking into a deployed config is visible. Renderers shouldn't crash
    when chezmoi is absent (it isn't a hard ap dependency), but the user
    needs to see what's about to ship."""
    global _chezmoi_warned
    if _chezmoi_warned:
        return
    _chezmoi_warned = True
    print(
        f"    ap: chezmoi not on PATH — leaving Go-template values unrendered "
        f"(first: {value!r})",
        file=sys.stderr,
    )


def needs_render(value: Any) -> bool:
    """A value needs the render pass iff it's a string with a Go-template
    open delimiter. Non-strings (lists, dicts, ints) are walked by the
    caller; this only judges leaves."""
    return isinstance(value, str) and "{{" in value


# The legacy `agents/mcp/sync.sh` rendered the whole registry in one
# chezmoi pass; the registry's leading `{{ $h := env "HARNESS" }}` line
# put $h in scope for every entry. We render values one at a time, so
# each render gets its own preamble — same effect, narrower blast radius.
_PREAMBLE = '{{ $h := env "HARNESS" }}'


def render_value(value: str, harness: str) -> str:
    """Render a single string through ``chezmoi execute-template`` with
    ``HARNESS=<harness>`` exported and ``$h`` pre-declared. Returns the
    original on render failure so a bad template doesn't abort the whole
    install — the deployed config will surface the unrendered string at
    use time."""
    chezmoi = _resolve_chezmoi()
    if chezmoi is None:
        _warn_missing_chezmoi(value)
        return value
    env = {**os.environ, "HARNESS": harness}
    try:
        result = subprocess.run(
            [chezmoi, "execute-template"],
            input=_PREAMBLE + value,
            text=True,
            capture_output=True,
            env=env,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        print(
            f"    ap: chezmoi execute-template failed for harness '{harness}': "
            f"{exc.stderr.strip() if exc.stderr else exc}",
            file=sys.stderr,
        )
        return value
    return result.stdout


def render_mcp_for_harness(
    mcp: dict[str, Any], harness: str
) -> dict[str, Any]:
    """Return a shallow copy of ``mcp`` with ``args`` and ``env`` string
    values rendered against ``harness``. The original dict is not mutated
    so the same ``Manifest`` can be projected across multiple harnesses in
    one install pass without cross-contamination."""
    rendered = dict(mcp)

    args = mcp.get("args")
    if isinstance(args, list):
        rendered["args"] = [
            render_value(v, harness) if needs_render(v) else v for v in args
        ]

    env = mcp.get("env")
    if isinstance(env, dict):
        rendered["env"] = {
            k: render_value(v, harness) if needs_render(v) else v
            for k, v in env.items()
        }

    return rendered
