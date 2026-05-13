#!/usr/bin/env python3
"""Tests for validate.py — the ralphify RALPH.md schema validator."""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from validate import _split_frontmatter, _validate_credit, validate


@pytest.fixture()
def tmp_ralph(tmp_path: Path):
    """Write a RALPH.md to tmp_path and return a helper to call validate()."""

    def _write(content: str) -> tuple[list[str], list[str]]:
        p = tmp_path / "RALPH.md"
        p.write_text(textwrap.dedent(content))
        return validate(p)

    return _write


# ── Frontmatter parsing ─────────────────────────────────────────────


class TestSplitFrontmatter:
    def test_valid(self):
        fm, body = _split_frontmatter("---\nagent: claude -p\n---\nHello\n")
        assert fm == {"agent": "claude -p"}
        assert body == "Hello\n"

    def test_empty_frontmatter(self):
        fm, body = _split_frontmatter("---\n---\nbody\n")
        assert fm == {}

    def test_no_opening_delimiter(self):
        with pytest.raises(ValueError, match="must start with"):
            _split_frontmatter("agent: claude\n---\n")

    def test_no_closing_delimiter(self):
        with pytest.raises(ValueError, match="not closed"):
            _split_frontmatter("---\nagent: claude\n")

    def test_trailing_whitespace_on_closing(self):
        fm, _ = _split_frontmatter("---\nagent: claude -p\n---   \nbody\n")
        assert fm["agent"] == "claude -p"

    def test_non_mapping_frontmatter(self):
        with pytest.raises(ValueError, match="must be a YAML mapping"):
            _split_frontmatter("---\n- item1\n- item2\n---\nbody\n")


# ── Agent validation ─────────────────────────────────────────────────


class TestAgentValidation:
    def test_missing_agent(self, tmp_ralph):
        errors, _ = tmp_ralph("---\ncommands: []\n---\nbody\n")
        assert any("agent" in e and "required" in e for e in errors)

    def test_agent_not_on_path(self, tmp_ralph):
        errors, _ = tmp_ralph(
            "---\nagent: nonexistent-binary-xyz123\n---\nbody\n"
        )
        assert any("not on PATH" in e for e in errors)

    def test_valid_agent(self, tmp_ralph):
        errors, _ = tmp_ralph("---\nagent: echo test\n---\nbody\n")
        assert not any("agent" in e for e in errors)


# ── Credit validation ────────────────────────────────────────────────


class TestCreditValidation:
    def test_valid_bool_true(self):
        assert _validate_credit({"credit": True}) == []

    def test_valid_bool_false(self):
        assert _validate_credit({"credit": False}) == []

    def test_absent_is_fine(self):
        assert _validate_credit({}) == []

    def test_string_rejected(self):
        errors = _validate_credit({"credit": "false"})
        assert len(errors) == 1
        assert "boolean" in errors[0]

    def test_int_rejected(self):
        errors = _validate_credit({"credit": 1})
        assert len(errors) == 1


# ── Command validation ───────────────────────────────────────────────


class TestCommandValidation:
    def test_valid_command(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: tests
                run: uv run pytest
            ---
            ## Results
            {{ commands.tests }}
        """)
        assert not errors

    def test_shell_metachar_pipe(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: tests
                run: pytest | tail -20
            ---
            {{ commands.tests }}
        """)
        assert any("metacharacter" in e for e in errors)

    def test_shell_metachar_and(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: check
                run: cargo check && cargo test
            ---
            {{ commands.check }}
        """)
        assert any("metacharacter" in e for e in errors)

    def test_duplicate_command_names(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: tests
                run: pytest
              - name: tests
                run: pytest --verbose
            ---
            {{ commands.tests }}
        """)
        assert any("not unique" in e for e in errors)

    def test_bad_command_name(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: "bad name!"
                run: echo hi
            ---
            {{ commands.bad name! }}
        """)
        assert any("must match" in e for e in errors)

    def test_timeout_bool_rejected(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: tests
                run: pytest
                timeout: true
            ---
            {{ commands.tests }}
        """)
        assert any("timeout" in e and "positive number" in e for e in errors)

    def test_timeout_negative_rejected(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: tests
                run: pytest
                timeout: -5
            ---
            {{ commands.tests }}
        """)
        assert any("positive number" in e for e in errors)

    def test_timeout_valid(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: tests
                run: pytest
                timeout: 180
            ---
            {{ commands.tests }}
        """)
        assert not errors

    def test_commands_not_a_list(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              tests: pytest
            ---
            body
        """)
        assert any("must be a list" in e for e in errors)

    def test_command_entry_not_a_mapping(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - just a string
            ---
            body
        """)
        assert any("must be a mapping" in e for e in errors)


# ── Args validation ──────────────────────────────────────────────────


class TestArgsValidation:
    def test_valid_args(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            args:
              - module
              - target
            ---
            Working on {{ args.module }} targeting {{ args.target }}
        """)
        assert not errors

    def test_duplicate_args(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            args:
              - foo
              - foo
            ---
            {{ args.foo }}
        """)
        assert any("not unique" in e for e in errors)

    def test_args_not_a_list(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            args: module
            ---
            {{ args.module }}
        """)
        assert any("must be a list" in e for e in errors)


# ── Placeholder validation ───────────────────────────────────────────


class TestPlaceholders:
    def test_undeclared_command_placeholder(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            ---
            {{ commands.nonexistent }}
        """)
        assert any("no command named" in e for e in errors)

    def test_undeclared_arg_placeholder(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            ---
            {{ args.missing }}
        """)
        assert any("no arg named" in e for e in errors)

    def test_arg_placeholder_in_run_string(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            args:
              - issue
            commands:
              - name: view
                run: gh issue view {{ args.issue }}
            ---
            {{ commands.view }}
        """)
        assert not errors

    def test_undeclared_arg_in_run_string(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: view
                run: gh issue view {{ args.issue }}
            ---
            {{ commands.view }}
        """)
        assert any("no arg named" in e and "issue" in e for e in errors)

    def test_html_comments_stripped_from_placeholder_check(self, tmp_ralph):
        errors, _ = tmp_ralph("""\
            ---
            agent: echo
            ---
            <!-- {{ commands.nonexistent }} -->
            body text
        """)
        assert not any("no command named" in e for e in errors)


# ── Warnings ─────────────────────────────────────────────────────────


class TestWarnings:
    def test_unused_command_warning(self, tmp_ralph):
        _, warnings = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: tests
                run: pytest
            ---
            body without placeholders
        """)
        assert any("tests" in w and "never referenced" in w for w in warnings)

    def test_unused_arg_warning(self, tmp_ralph):
        _, warnings = tmp_ralph("""\
            ---
            agent: echo
            args:
              - focus
            ---
            body without arg placeholders
        """)
        assert any("focus" in w and "never referenced" in w for w in warnings)


# ── Full integration ─────────────────────────────────────────────────


class TestIntegration:
    def test_clean_ralph(self, tmp_ralph):
        errors, warnings = tmp_ralph("""\
            ---
            agent: echo
            commands:
              - name: git-log
                run: git log --oneline -10
              - name: tests
                run: uv run pytest
            ---

            You are an autonomous agent.

            ## Recent changes
            {{ commands.git-log }}

            ## Test results
            {{ commands.tests }}

            ## Task
            Fix one failing test per iteration.
        """)
        assert not errors
        assert not warnings

    def test_minimal_ralph(self, tmp_ralph):
        errors, warnings = tmp_ralph("---\nagent: echo\n---\nbody\n")
        assert not errors
        assert not warnings
