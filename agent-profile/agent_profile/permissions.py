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
    Codex/Copilot lever-3 collectors);
  - :func:`whole_server_mcp_allows` — collect the servers a list allows
    whole (``mcp__<server>__*``), so a renderer can tell a whole-server
    allow apart from a named-tool restriction even when both name the
    same server.

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

    ``mcp__tilth__*`` -> ``("tilth", "*")``;  ``mcp__my-server__*``
    -> ``("my-server", "*")``;  ``mcp__s__read_file`` ->
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


def native_mcp_server_plugins(native_plugins: list[dict], harness: str) -> dict[str, str]:
    """Map ``server_name -> plugin_name`` for plugins native on ``harness``.

    A plugin installed natively on a harness has its MCP tools re-namespaced by
    that harness to ``mcp__plugin_<plugin>_<server>__*`` (Claude-compat layout,
    e.g. ``mcp__plugin_hallouminate_hallouminate__*``). Renderers use this map
    to rewrite the canonical ``mcp__<server>__*`` permission rules for harnesses
    where the plugin is native, leaving decomposed harnesses on the bare form.
    """
    flag = f"{harness}_native"
    out: dict[str, str] = {}
    for entry in native_plugins:
        if not entry.get(flag):
            continue
        plugin = entry.get("name")
        for server in entry.get("servers") or []:
            out[server] = plugin
    return out


def rewrite_native_mcp_rule(rule: str, server_plugins: dict[str, str]) -> str:
    """Rewrite one ``mcp__<server>__<tool>`` rule to the plugin-namespaced form
    ``mcp__plugin_<plugin>_<server>__<tool>`` when ``<server>`` belongs to a
    native plugin in ``server_plugins``. Non-MCP rules and servers absent from
    the map pass through unchanged."""
    parsed = parse_mcp_rule(rule)
    if parsed is None:
        return rule
    server, tool = parsed
    plugin = server_plugins.get(server)
    if plugin is None:
        return rule
    return f"{_MCP_PREFIX}plugin_{plugin}_{server}__{tool}"


def rewrite_native_mcp_rules(rules: list[str], server_plugins: dict[str, str]) -> list[str]:
    """Apply :func:`rewrite_native_mcp_rule` across a rule list. A no-op (copy)
    when ``server_plugins`` is empty — i.e. no plugin is native on the harness."""
    if not server_plugins:
        return list(rules)
    return [rewrite_native_mcp_rule(rule, server_plugins) for rule in rules]


def rewrite_skill_allowed_tools(text: str, server_plugins: dict[str, str]) -> str:
    """Rewrite ``mcp__<server>__*`` entries in a skill's inline ``allowed-tools:``
    frontmatter line to the plugin-namespaced form for native plugins.

    Claude Code is the only harness that enforces a skill's ``allowed-tools``,
    and it reads its own ``.claude/skills/`` copy, so the claude renderer applies
    this to that copy alone. Operates only on the comma-separated inline form
    inside the leading ``---`` frontmatter block; returns ``text`` unchanged when
    there is no such line, no frontmatter, or no native plugin to rewrite for."""
    if not server_plugins or not text.startswith("---"):
        return text
    lines = text.splitlines(keepends=True)
    end = next(
        (i for i in range(1, len(lines)) if lines[i].rstrip("\n") == "---"), None
    )
    if end is None:
        return text
    for i in range(1, end):
        bare = lines[i].rstrip("\n")
        inline = re.match(r"^allowed-tools:\s*(\S.*?)\s*$", bare)
        if inline:
            items = [tok.strip() for tok in inline.group(1).split(",")]
            rewritten = [rewrite_native_mcp_rule(tok, server_plugins) for tok in items]
            trailing = "\n" if lines[i].endswith("\n") else ""
            lines[i] = "allowed-tools: " + ", ".join(rewritten) + trailing
            return "".join(lines)
        if re.match(r"^allowed-tools:\s*$", bare):
            # YAML block-list form: rewrite each following "  - <entry>" line.
            for j in range(i + 1, end):
                item = re.match(r"^(\s*-\s*)(\S.*?)\s*$", lines[j].rstrip("\n"))
                if not item:
                    break
                trailing = "\n" if lines[j].endswith("\n") else ""
                lines[j] = item.group(1) + rewrite_native_mcp_rule(
                    item.group(2), server_plugins
                ) + trailing
            return "".join(lines)
    return text


def whole_server_mcp_allows(rules: list[str]) -> set[str]:
    """Collect the servers ``rules`` allows whole via ``mcp__<server>__*``.

    A whole-server rule means "no tool restriction for this server". The
    Codex and Copilot lever-3 collectors read :func:`named_mcp_tools` as
    "restrict this server to these named tools"; that read is wrong when the
    canonical list ALSO carries a ``mcp__<server>__*`` rule for the same
    server (the whole-server allow must win — no restriction). Renderers
    union this set against the named-tool buckets to detect that case: a
    server present here stays unrestricted even when named-tool entries
    exist for it. Non-MCP and named-tool rules contribute nothing."""
    out: set[str] = set()
    for rule in rules:
        parsed = parse_mcp_rule(rule)
        if not parsed:
            continue
        server, tool = parsed
        if tool == "*":
            out.add(server)
    return out
