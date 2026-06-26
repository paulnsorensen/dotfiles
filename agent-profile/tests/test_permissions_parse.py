"""test_permissions_parse.py — the canonical-rule classifiers shared by the
Codex and Copilot renderers (agent_profile.permissions)."""

from __future__ import annotations

import pytest

from agent_profile.permissions import (
    bash_argv,
    named_mcp_tools,
    native_mcp_server_plugins,
    parse_mcp_rule,
    rewrite_native_mcp_rule,
    rewrite_native_mcp_rules,
    rewrite_skill_allowed_tools,
    whole_server_mcp_allows,
)


@pytest.mark.parametrize(
    "rule,expected",
    [
        ("Bash(git:*)", ["git"]),
        ("Bash(gh pr view:*)", ["gh", "pr", "view"]),
        ("Bash(rm -rf:*)", ["rm", "-rf"]),
        ("Bash(sudo:*)", ["sudo"]),
        ("Bash(npm test:*)", ["npm", "test"]),
    ],
)
def test_bash_argv_extracts_prefix(rule, expected):
    assert bash_argv(rule) == expected


@pytest.mark.parametrize(
    "rule",
    ["Edit", "Write", "Read", "Grep", "Glob", "Skill", "mcp__tilth__*", "Bash"],
)
def test_bash_argv_rejects_non_bash_prefix(rule):
    assert bash_argv(rule) is None


@pytest.mark.parametrize(
    "rule,expected",
    [
        ("mcp__tilth__*", ("tilth", "*")),
        ("mcp__code-review-graph__*", ("code-review-graph", "*")),
        ("mcp__server__read_file", ("server", "read_file")),
        ("mcp__plugin_global_tilth__*", ("plugin_global_tilth", "*")),
    ],
)
def test_parse_mcp_rule_splits_server_tool(rule, expected):
    assert parse_mcp_rule(rule) == expected


@pytest.mark.parametrize(
    "rule", ["Bash(git:*)", "Edit", "mcp__only", "mcp____tool", "mcp__server__"]
)
def test_parse_mcp_rule_rejects_non_mcp(rule):
    assert parse_mcp_rule(rule) is None


def test_whole_server_mcp_allows_collects_star_servers():
    rules = ["mcp__tilth__*", "mcp__code-review-graph__*", "Bash(git:*)", "Edit"]
    assert whole_server_mcp_allows(rules) == {"tilth", "code-review-graph"}


def test_whole_server_mcp_allows_excludes_named_only_servers():
    """A server named ONLY by a named-tool rule is not a whole-server allow."""
    assert whole_server_mcp_allows(["mcp__tilth__tilth_read"]) == set()


def test_whole_server_mcp_allows_includes_server_with_both_star_and_named():
    """When a server has BOTH a whole-server and a named-tool rule, the
    whole-server allow is recorded — the renderer needs it to override the
    named-tool restriction (no-restriction wins). This is the bug findings
    4/5 fix: named_mcp_tools alone can't distinguish this case."""
    rules = ["mcp__tilth__*", "mcp__tilth__tilth_read"]
    assert whole_server_mcp_allows(rules) == {"tilth"}
    # named_mcp_tools still buckets the named tool — the two collectors are
    # orthogonal; the renderer unions them.
    assert named_mcp_tools(rules) == {"tilth": {"tilth_read"}}


def test_whole_server_mcp_allows_empty_for_no_mcp_rules():
    assert whole_server_mcp_allows(["Bash(git:*)", "Edit", "Write"]) == set()


# ─── native-plugin MCP rule rewrite (Phase 4 reference migration) ─────────────

_HALLOUM_NATIVE = [{
    "name": "hallouminate",
    "claude_native": True,
    "codex_native": True,
    "copilot_native": False,
    "servers": ["hallouminate"],
}]


def test_native_mcp_server_plugins_maps_only_native_harness():
    assert native_mcp_server_plugins(_HALLOUM_NATIVE, "claude") == {"hallouminate": "hallouminate"}
    assert native_mcp_server_plugins(_HALLOUM_NATIVE, "codex") == {"hallouminate": "hallouminate"}
    # copilot_native is False here → no rewrite map for copilot.
    assert native_mcp_server_plugins(_HALLOUM_NATIVE, "copilot") == {}
    # cursor never carries a *_native flag → empty.
    assert native_mcp_server_plugins(_HALLOUM_NATIVE, "cursor") == {}


def test_rewrite_native_mcp_rule_namespaces_native_server():
    m = {"hallouminate": "hallouminate"}
    assert rewrite_native_mcp_rule("mcp__hallouminate__*", m) == "mcp__plugin_hallouminate_hallouminate__*"
    assert rewrite_native_mcp_rule("mcp__hallouminate__ground", m) == "mcp__plugin_hallouminate_hallouminate__ground"


def test_rewrite_native_mcp_rule_passes_through_non_native_and_non_mcp():
    m = {"hallouminate": "hallouminate"}
    assert rewrite_native_mcp_rule("mcp__tilth__*", m) == "mcp__tilth__*"
    assert rewrite_native_mcp_rule("Bash(git:*)", m) == "Bash(git:*)"
    assert rewrite_native_mcp_rule("Edit", m) == "Edit"


def test_rewrite_native_mcp_rules_empty_map_is_noop():
    rules = ["mcp__hallouminate__*", "mcp__tilth__*"]
    assert rewrite_native_mcp_rules(rules, {}) == rules


def test_rewrite_native_mcp_rules_rewrites_only_native_entries():
    rules = ["mcp__hallouminate__*", "mcp__tilth__*", "Bash(gh:*)"]
    out = rewrite_native_mcp_rules(rules, {"hallouminate": "hallouminate"})
    assert out == ["mcp__plugin_hallouminate_hallouminate__*", "mcp__tilth__*", "Bash(gh:*)"]


def test_rewrite_skill_allowed_tools_rewrites_inline_line():
    text = "---\nname: rennet\nallowed-tools: Task, mcp__hallouminate__*, mcp__tilth__*\n---\nbody\n"
    out = rewrite_skill_allowed_tools(text, {"hallouminate": "hallouminate"})
    assert "allowed-tools: Task, mcp__plugin_hallouminate_hallouminate__*, mcp__tilth__*\n" in out
    assert "body" in out  # body untouched


def test_rewrite_skill_allowed_tools_noops_without_native_or_frontmatter():
    text = "---\nallowed-tools: mcp__hallouminate__*\n---\n"
    assert rewrite_skill_allowed_tools(text, {}) == text  # empty map
    no_fm = "no frontmatter here\nallowed-tools: mcp__hallouminate__*\n"
    assert rewrite_skill_allowed_tools(no_fm, {"hallouminate": "hallouminate"}) == no_fm


def test_rewrite_skill_allowed_tools_noops_when_no_allowed_tools_line():
    text = "---\nname: x\ndescription: y\n---\nbody\n"
    assert rewrite_skill_allowed_tools(text, {"hallouminate": "hallouminate"}) == text


def test_rewrite_skill_allowed_tools_handles_yaml_block_list():
    text = (
        "---\nname: rennet\nallowed-tools:\n"
        "  - Task\n  - mcp__hallouminate__*\n  - mcp__tilth__*\n---\nbody\n"
    )
    out = rewrite_skill_allowed_tools(text, {"hallouminate": "hallouminate"})
    assert "  - mcp__plugin_hallouminate_hallouminate__*\n" in out
    assert "  - mcp__hallouminate__*\n" not in out
    assert "  - mcp__tilth__*\n" in out
    assert "  - Task\n" in out
