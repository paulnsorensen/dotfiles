"""permissions.py — parse canonical permission-rule strings.

The canonical allow/deny lists use the Claude permission-rule grammar as
the interlingua (see ``profiles/_permissions/profile.yaml``). Renderers
lower each entry onto their native surface; this module owns the two
classifiers they share:

  - :func:`bash_argv` — pull the argv prefix out of a ``Bash(<cmd>:*)``
    rule (the lever-1 per-command subset);
  - :func:`parse_mcp_rule` — split an ``mcp__<server>__<tool>`` rule into
    ``(server, tool)`` (the lever-3 MCP-scoping subset);
  - :func:`named_mcp_tools` — bucket a rule list into the explicit
    (non-``*``) tool names it names per server (the shared half of the
    Codex/Copilot lever-3 collectors).

The lever split is DERIVED from the prefix: an entry matching ``mcp__*``
is lever 3; a ``Bash(...)`` entry is lever 1. Everything else (``Edit``,
``Write``, ``Read``, ``Skill``, bare ``Grep``/``Glob``) is a Claude/native
tool with no shell-command or MCP surface on Codex/Copilot, so the
renderers skip it.
"""

from __future__ import annotations

import re

# `Bash(<cmd>:*)` — the prefix form. ``<cmd>`` is one-or-more whitespace-
# separated argv tokens (``git``, ``gh pr view``, ``rm -rf``). Only the
# trailing ``:*`` prefix form maps to a Codex/Copilot command rule; a bare
# ``Bash`` (no parens) or an exact-command form is not in the canonical set.
_BASH_PREFIX_RE = re.compile(r"^Bash\((.+):\*\)$")

# `mcp__<server>__<tool>` — server and tool are the 2nd and 3rd `__`-split
# segments. ``<tool>`` may be ``*`` (whole-server) or a named tool.
_MCP_PREFIX = "mcp__"


def bash_argv(rule: str) -> list[str] | None:
    """Return the argv-prefix token list for a ``Bash(<cmd>:*)`` rule, or
    ``None`` when ``rule`` is not a bash-prefix rule.

    ``Bash(git:*)`` -> ``["git"]``; ``Bash(gh pr view:*)`` ->
    ``["gh", "pr", "view"]``; ``Bash(rm -rf:*)`` -> ``["rm", "-rf"]``."""
    m = _BASH_PREFIX_RE.match(rule)
    if not m:
        return None
    tokens = m.group(1).split()
    return tokens or None


def parse_mcp_rule(rule: str) -> tuple[str, str] | None:
    """Return ``(server, tool)`` for an ``mcp__<server>__<tool>`` rule, or
    ``None`` when ``rule`` is not an MCP rule.

    ``mcp__tilth__*`` -> ``("tilth", "*")``; ``mcp__code-review-graph__*``
    -> ``("code-review-graph", "*")``; ``mcp__s__read_file`` ->
    ``("s", "read_file")``. Splits on the ``__`` delimiter: the server is
    the segment after the ``mcp__`` prefix, the tool is the remainder (so a
    tool name containing ``__`` is preserved)."""
    if not rule.startswith(_MCP_PREFIX):
        return None
    rest = rule[len(_MCP_PREFIX):]
    server, sep, tool = rest.partition("__")
    if not sep or not server or not tool:
        return None
    return server, tool


def named_mcp_tools(rules: list[str]) -> dict[str, set[str]]:
    """Bucket ``rules`` into the explicit tool names each server is scoped to.

    Iterates one allow- or deny-list, parses each ``mcp__<server>__<tool>``
    rule, and collects the named (non-``*``) tools per server. A whole-server
    ``mcp__<server>__*`` rule names no tool, so it contributes no entry;
    non-MCP rules are skipped. Codex calls this once per list (allow ->
    ``enabled_tools``, deny -> ``disabled_tools``); Copilot calls it on the
    allow list to derive each server's ``tools`` array. The divergent
    enabled/disabled vs whole-server-default handling stays at the call
    site."""
    out: dict[str, set[str]] = {}
    for rule in rules:
        parsed = parse_mcp_rule(rule)
        if not parsed:
            continue
        server, tool = parsed
        if tool != "*":
            out.setdefault(server, set()).add(tool)
    return out
