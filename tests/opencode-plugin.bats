#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    command -v node >/dev/null 2>&1 || skip "node not installed"
    export PLUGIN="$REAL_DOTFILES_DIR/chezmoi/dot_config/opencode/plugins/tilth-only.js"
}

teardown() {
    teardown_test_env
}

@test "v2 tool transform removes every native file tool and retains other tools" {
    run node --input-type=module -e '
        import assert from "node:assert/strict";
        import { pathToFileURL } from "node:url";

        const module = await import(pathToFileURL(process.argv[1]));
        assert.deepEqual(Object.keys(module), ["default"]);
        assert.equal(module.default.id, "dotfiles.tilth-only");
        const native = ["read", "edit", "write", "patch", "grep", "glob"];
        const kept = ["shell", "subagent", "webfetch", "tilth_tilth_read", "tilth_tilth_write", "custom"];
        const tools = new Map([...native, ...kept].map((id) => [id, { id }]));
        const editor = { remove: (id) => tools.delete(id) };
        await module.default.setup({
            tool: { transform: async (callback) => callback(editor), hook: async () => {} },
        });
        assert.deepEqual([...tools.keys()], kept);
        console.log("native removed; other tools retained");
    ' "$PLUGIN"
    [ "$status" -eq 0 ]
    [ "$output" = "native removed; other tools retained" ]
}

@test "v2 execute.before hook rejects each native file tool and permits other IDs" {
    run node --input-type=module -e '
        import assert from "node:assert/strict";
        import { pathToFileURL } from "node:url";

        const { default: plugin } = await import(pathToFileURL(process.argv[1]));
        const hooks = {};
        await plugin.setup({
            tool: { transform: async () => {}, hook: async (name, callback) => { hooks[name] = callback; } },
        });
        for (const tool of ["read", "edit", "write", "patch", "grep", "glob"]) {
            assert.throws(() => hooks["execute.before"]({ tool, input: {} }), /Native file tool .* is disabled/);
        }
        for (const tool of ["shell", "subagent", "tilth_tilth_read", "tilth_tilth_write", "custom"]) {
            assert.doesNotThrow(() => hooks["execute.before"]({ tool, input: {} }), tool);
        }
        console.log("native rejected; other IDs permitted");
    ' "$PLUGIN"
    [ "$status" -eq 0 ]
    [ "$output" = "native rejected; other IDs permitted" ]
}

@test "chezmoi deploys the native plugin from source" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local source_dir="$REAL_DOTFILES_DIR/chezmoi"
    local destination="$TEST_HOME/home"
    local config="$TEST_HOME/chezmoi.toml"
    mkdir -p "$destination/.config/opencode/plugins"
    printf 'sourceDir = "%s"\ndestDir = "%s"\n\n[data]\nemail = "test@example.com"\nwork = false\nlocalLLM = false\n' "$source_dir" "$destination" > "$config"

    run env HOME="$TEST_HOME" chezmoi --config "$config" --source "$source_dir" apply --force --exclude=scripts "$destination/.config/opencode/plugins/tilth-only.js"
    [ "$status" -eq 0 ]
    cmp -s "$PLUGIN" "$destination/.config/opencode/plugins/tilth-only.js"
}

@test "OpenCode Node tests run through the Bats gate when present" {
    local js_tests=("$REAL_DOTFILES_DIR"/tests/opencode-*.test.js)
    [ -f "${js_tests[0]}" ] || skip "no OpenCode Node tests"
    run node --test --test-reporter=tap "${js_tests[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# fail 0"* ]]
}
