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

@test "opencode turn-budget-guard plugin maps sub-agent session to agent_id/agent_type" {
    DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" LOG="$CLAUDE_TURN_BUDGET_LOG" run node --input-type=module -e '
      import { readFileSync } from "node:fs";
      const mod = await import(process.env.OG_PLUGIN);
      const client = { session: { get: async () => ({ data: { parentID: "p1", agent: "explorer" } }) } };
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR, client });
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "child-1", callID: "c1" }, { args: {} });
      const lines = readFileSync(process.env.LOG, "utf8").trim().split("\n");
      const record = JSON.parse(lines[lines.length - 1]);
      if (record.agent_id !== "child-1") throw new Error(`agent_id: ${record.agent_id}`);
      if (record.agent_type !== "explorer") throw new Error(`agent_type: ${record.agent_type}`);
      if (record.session_id !== "p1") throw new Error(`session_id: ${record.session_id}`);
    '
    assert_success
}

@test "opencode turn-budget-guard plugin no-ops when session has no parentID" {
    CLAUDE_TURN_BUDGET_DEBUG=1 DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" LOG="$CLAUDE_TURN_BUDGET_LOG" run node --input-type=module -e '
      import { readFileSync } from "node:fs";
      const mod = await import(process.env.OG_PLUGIN);
      const client = { session: { get: async () => ({ data: { agent: "explorer" } }) } };
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR, client });
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "top-1", callID: "c1" }, { args: {} });
      const lines = readFileSync(process.env.LOG, "utf8").trim().split("\n");
      const record = JSON.parse(lines[lines.length - 1]);
      if (record.action !== "allow" || record.reason !== "no-agent-id") {
        throw new Error(`unexpected: ${JSON.stringify(record)}`);
      }
    '
    assert_success
}

@test "opencode turn-budget-guard plugin fails open when session.get throws" {
    CLAUDE_TURN_BUDGET_DEBUG=1 DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" LOG="$CLAUDE_TURN_BUDGET_LOG" run node --input-type=module -e '
      import { readFileSync } from "node:fs";
      const mod = await import(process.env.OG_PLUGIN);
      const client = { session: { get: async () => { throw new Error("boom"); } } };
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR, client });
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "err-1", callID: "c1" }, { args: {} });
      const lines = readFileSync(process.env.LOG, "utf8").trim().split("\n");
      const record = JSON.parse(lines[lines.length - 1]);
      if (record.action !== "allow" || record.reason !== "no-agent-id") {
        throw new Error(`unexpected: ${JSON.stringify(record)}`);
      }
    '
    assert_success
}

@test "opencode turn-budget-guard plugin caches session identity across calls" {
    DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" run node --input-type=module -e '
      const mod = await import(process.env.OG_PLUGIN);
      let calls = 0;
      const client = { session: { get: async () => { calls++; return { data: { parentID: "p1", agent: "explorer" } }; } } };
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR, client });
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "child-2", callID: "c1" }, { args: {} });
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "child-2", callID: "c2" }, { args: {} });
      if (calls !== 1) throw new Error(`expected 1 client call, got ${calls}`);
    '
    assert_success
}

@test "opencode turn-budget-guard plugin cleans up sub-agent state on session.idle" {
    DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" LOG="$CLAUDE_TURN_BUDGET_LOG" run node --input-type=module -e '
      import { readFileSync } from "node:fs";
      const mod = await import(process.env.OG_PLUGIN);
      const client = { session: { get: async () => ({ data: { parentID: "p1", agent: "explorer" } }) } };
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR, client });
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "child-3", callID: "c1" }, { args: {} });
      await hooks.event({ event: { type: "session.idle", properties: { sessionID: "child-3" } } });
      const lines = readFileSync(process.env.LOG, "utf8").trim().split("\n");
      const record = JSON.parse(lines[lines.length - 1]);
      if (record.action !== "cleanup" || record.agent_id !== "child-3") {
        throw new Error(`unexpected: ${JSON.stringify(record)}`);
      }
    '
    assert_success
}

@test "opencode turn-budget-guard plugin fails open when counter state is unwritable" {
    printf '' > "$TEST_HOME/not-a-dir"
    CLAUDE_TURN_BUDGET_DIR="$TEST_HOME/not-a-dir" DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" run node --input-type=module -e '
      const mod = await import(process.env.OG_PLUGIN);
      const client = { session: { get: async () => ({ data: { parentID: "p1", agent: "explorer" } }) } };
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR, client });
      // Counter writes throw ENOTDIR under a file base dir; the hook must
      // swallow that (fail-open), not fail the tool call.
      await hooks["tool.execute.before"]({ tool: "bash", sessionID: "child-fs", callID: "c1" }, { args: {} });
      await hooks["tool.execute.after"]({ tool: "bash", sessionID: "child-fs", callID: "c1" }, { args: {} });
    '
    assert_success
}

@test "opencode turn-budget-guard plugin still denies at the turn hard ceiling" {
    mkdir -p "$CLAUDE_TURN_BUDGET_DIR/p1/child-deny"
    printf '%050d' 0 > "$CLAUDE_TURN_BUDGET_DIR/p1/child-deny/turns"  # explorer turnHard = 50
    DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" run node --input-type=module -e '
      const mod = await import(process.env.OG_PLUGIN);
      const client = { session: { get: async () => ({ data: { parentID: "p1", agent: "explorer" } }) } };
      const hooks = await mod.TurnBudgetGuard({ directory: process.env.DOTFILES_DIR, worktree: process.env.DOTFILES_DIR, client });
      let threw = null;
      try {
        await hooks["tool.execute.before"]({ tool: "bash", sessionID: "child-deny", callID: "c1" }, { args: {} });
      } catch (err) {
        threw = err;
      }
      if (!threw) throw new Error("expected the deny to propagate");
      if (!threw.turnBudgetDeny) throw new Error(`deny escaped untagged: ${threw.message}`);
    '
    assert_success
}
