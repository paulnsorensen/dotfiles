"""test_model_tiers.py — `tier:` resolution against agents/models.yaml.

`agents/registry.yaml` agents name a tier instead of transcribing the
claude/codex model ids; `agents/models.yaml` holds the lookup. Resolution
runs in `expand_agents` so renderers keep reading `item["models"]`.

Precedence under test:
  1. the agent's own `models.<harness>` wins
  2. else `pins[tier][harness]`
  3. else the harness key stays absent
plus: an unknown `tier` is a hard failure, not a silent passthrough.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
import yaml

from agent_profile._validate import ParseError
from agent_profile.cli import CliError, cmd_agents_json
from agent_profile.ingest import expand_agents

PINS = {
    "fast": {"claude": "haiku", "codex": "gpt-5.6-luna"},
    "deep": {"claude": "opus", "codex": "gpt-5.6-sol"},
}


def _registry(tmp_path: Path, agents: dict, *, pins: dict | None = PINS) -> Path:
    """Write a registry + sibling models.yaml, return the registry path."""
    reg = tmp_path / "registry.yaml"
    reg.write_text(yaml.safe_dump({"agents": agents}), encoding="utf-8")
    if pins is not None:
        (tmp_path / "models.yaml").write_text(
            yaml.safe_dump({"pins": pins}), encoding="utf-8"
        )
    return reg


def _models(tmp_path: Path, agents: dict, **kw) -> dict:
    items = expand_agents(_registry(tmp_path, agents, **kw), ".")
    return {i["name"]: i.get("models") for i in items}


def test_tier_resolves_to_pinned_models(tmp_path):
    out = _models(tmp_path, {"a": {"tier": "deep"}})
    assert out["a"] == {"claude": "opus", "codex": "gpt-5.6-sol"}


def test_own_models_entry_overrides_the_tier(tmp_path):
    out = _models(tmp_path, {"a": {"tier": "deep", "models": {"codex": "gpt-pinned"}}})
    # claude still comes from the tier; codex is the agent's own override.
    assert out["a"] == {"claude": "opus", "codex": "gpt-pinned"}


def test_harness_absent_from_the_tier_stays_absent(tmp_path):
    """cursor/opencode are not tier-derived — they only appear when the agent
    sets them, and setting one must not synthesize the others."""
    out = _models(tmp_path, {"a": {"tier": "fast", "models": {"cursor": "auto"}}})
    assert out["a"] == {"claude": "haiku", "codex": "gpt-5.6-luna", "cursor": "auto"}
    assert "opencode" not in out["a"]


def test_agent_without_a_tier_is_untouched(tmp_path):
    out = _models(tmp_path, {"a": {"models": {"claude": "sonnet"}}, "b": {}})
    assert out["a"] == {"claude": "sonnet"}
    assert out["b"] is None


def test_unknown_tier_is_a_hard_failure_naming_the_agent(tmp_path):
    with pytest.raises(ParseError) as excinfo:
        _models(tmp_path, {"typo-agent": {"tier": "medium"}})
    message = str(excinfo.value)
    assert "typo-agent" in message
    assert "medium" in message
    # the error must list what the agent could have said instead
    assert "deep" in message and "fast" in message


def test_tier_without_models_yaml_is_a_hard_failure(tmp_path):
    """A missing models.yaml must not silently drop every agent's model."""
    with pytest.raises(ParseError):
        _models(tmp_path, {"a": {"tier": "fast"}}, pins=None)


def test_tier_key_is_consumed_not_leaked_into_frontmatter(tmp_path):
    items = expand_agents(_registry(tmp_path, {"a": {"tier": "fast"}}), ".")
    assert "tier" not in items[0]


def test_agents_json_emits_resolved_models(tmp_path, capsys):
    """`ap agents-json` is the sync-lib assembly's only view of the registry —
    it must hand over models already resolved, not the raw tier."""
    reg = _registry(tmp_path, {"a": {"tier": "deep", "body_path": "x.md"}})
    assert cmd_agents_json(str(reg), sys.stdout) == 0
    payload = json.loads(capsys.readouterr().out)
    assert [i["name"] for i in payload] == ["a"]
    assert payload[0]["models"] == {"claude": "opus", "codex": "gpt-5.6-sol"}
    assert "tier" not in payload[0]


def test_agents_json_rejects_a_missing_registry(tmp_path):
    with pytest.raises(CliError):
        cmd_agents_json(str(tmp_path / "nope.yaml"), sys.stdout)
