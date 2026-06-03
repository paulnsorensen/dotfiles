"""test_permissions_parse.py — the canonical-rule classifiers shared by the
Codex and Copilot renderers (agent_profile.permissions)."""

from __future__ import annotations

import pytest

from agent_profile.permissions import (
    bash_argv,
    named_mcp_tools,
    parse_mcp_rule,
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
