#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for the opencode turn-budget-guard plugin adapter.
#
# The adapter should export a plugin, fail open when its shared lib is absent,
# and quietly skip work when opencode does not provide a stable sub-agent
# identity.

load test_helper

OPENCODE_PLUGIN="$REAL_DOTFILES_DIR/chezmoi/dot_config/opencode/plugins/turn-budget-guard.js"

setup() {
    setup_test_env
    export CLAUDE_TURN_BUDGET_DIR="$TEST_HOME/budget"
    export CLAUDE_TURN_BUDGET_LOG="$TEST_HOME/decisions.jsonl"
}

teardown() {
    teardown_test_env
}

@test "opencode turn-budget-guard plugin exports TurnBudgetGuard and registers before/after hooks" {
    DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" run node --input-type=module -e '
      const mod = await import(process.env.OG_PLUGIN);
      if (typeof mod.TurnBudgetGuard !== "function") {
        throw new Error("missing TurnBudgetGuard export");
      }
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR });
      const keys = Object.keys(hooks);
      if (!keys.includes("tool.execute.before") || !keys.includes("tool.execute.after")) {
        throw new Error(`missing hooks: ${keys.sort().join(",")}`);
      }
    '
    assert_success
}

@test "opencode turn-budget-guard plugin fails open when its shared lib is missing" {
    local empty="$TEST_HOME/opencode-empty"
    mkdir -p "$empty"

    DOTFILES_DIR="$empty" OG_PLUGIN="$OPENCODE_PLUGIN" run node --input-type=module -e '
      const mod = await import(process.env.OG_PLUGIN);
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR });
      if (Object.keys(hooks).length !== 0) {
        throw new Error(`expected no hooks, got: ${Object.keys(hooks).sort().join(",")}`);
      }
    '
    assert_success
}

@test "opencode turn-budget-guard plugin does not throw without stable sub-agent identity" {
    DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" run node --input-type=module -e '
      const mod = await import(process.env.OG_PLUGIN);
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR });
      const before = hooks["tool.execute.before"];
      const after = hooks["tool.execute.after"];
      if (typeof before !== "function" || typeof after !== "function") {
        throw new Error("missing execute hooks");
      }
      await before({ tool: "bash" }, { args: { command: "git status" } });
      await after({ tool: "bash" }, { args: { command: "git status" } });
    '
    assert_success
}
