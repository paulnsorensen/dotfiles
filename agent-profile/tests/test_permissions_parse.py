"""test_permissions_parse.py — the canonical-rule classifiers shared by the
Codex and Copilot renderers (agent_profile.permissions)."""

from __future__ import annotations

import pytest

from agent_profile.permissions import bash_argv, parse_mcp_rule


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
