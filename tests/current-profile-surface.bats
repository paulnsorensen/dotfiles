#!/usr/bin/env bats

load test_helper

@test "current profile surfaces contain no removed engine reference" {
  local root="$BATS_TEST_DIRNAME/.."
  local legacy_alias="a""p"
  local legacy_package_name="agent""_""profile"
  local legacy_package_path="agent""-""profile/"
  local legacy_path_ref="${legacy_package_path}|bin/${legacy_alias}([[:space:]/]|$)"
  local legacy_ref="(^|[^[:alnum:]_-])${legacy_alias}([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])${legacy_package_name}([^[:alnum:]_-]|$)|${legacy_path_ref}"
  local surface
  local surfaces=(
    "$root/.github/dependabot.yml"
    "$root/AGENTS.md"
    "$root/agents/instruction-budgets.toml"
    "$root/.hallouminate/wiki/architecture/agent""-profile.md"
    "$root/claude/.sync"
    "$root/claude/README.md"
    "$root/claude/plugins/registry.yaml"
    "$root/claude/workflows/brie-ground.js"
    "$root/bin/lib/vault.sh"
  )

  for surface in "${surfaces[@]}"; do
    run grep -nEi -- "$legacy_ref" "$surface"
    assert_failure "legacy profile reference found in ${surface#"$root"/}: $output"
  done
}

@test "architecture page records the pinned profile migration" {
  local page="$BATS_TEST_DIRNAME/../.hallouminate/wiki/architecture/agent""-profile.md"

  run grep -nF -- 'cheese_flow.profiles' "$page"
  assert_success
  run grep -nF -- '862d8176cb5e87fc557e30c995fc8b2c7d49270d' "$page"
  assert_success
  run grep -nF -- 'Historical wiki, ADR, issue, and one-time migration evidence remains unchanged' "$page"
  assert_success
}

@test "architecture page names every supported profile operation" {
  local page="$BATS_TEST_DIRNAME/../.hallouminate/wiki/architecture/agent-profile.md"
  local operation

  for operation in list describe compile apply launch permissions; do
    run grep -nE -- "cheese profile ${operation}([[:space:]]|$)" "$page"
    assert_success "missing cheese profile ${operation} command"
  done
}
