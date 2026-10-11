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

@test "chat.message hides every native file tool and retains passed nonnative tools" {
    run node --input-type=module -e '
        import assert from "node:assert/strict";
        import { pathToFileURL } from "node:url";

        const module = await import(pathToFileURL(process.argv[1]));
        assert.deepEqual(Object.keys(module), ["default"]);
        const hooks = await module.default({});
        const native = ["read", "edit", "write", "apply_patch", "grep", "glob", "list"];
        const passed = { bash: true, task: true, tilth_tilth_read: true, tilth_tilth_write: false, custom: false };
        const output = { message: { tools: { ...passed, read: true, edit: true, write: true, apply_patch: true, grep: true, glob: true, list: true } } };
        await hooks["chat.message"]({}, output);
        for (const id of native) assert.equal(output.message.tools[id], false, id);
        for (const [id, value] of Object.entries(passed)) assert.equal(output.message.tools[id], value, id);
        const empty = { message: {} };
        await hooks["chat.message"]({}, empty);
        assert.deepEqual(empty.message.tools, Object.fromEntries(native.map(id => [id, false])));
        console.log("native hidden; passed tools retained");
    ' "$PLUGIN"
    [ "$status" -eq 0 ]
    [ "$output" = "native hidden; passed tools retained" ]
}

@test "tool.execute.before rejects each native file tool and permits other IDs" {
    run node --input-type=module -e '
        import assert from "node:assert/strict";
        import { pathToFileURL } from "node:url";

        const { default: plugin } = await import(pathToFileURL(process.argv[1]));
        const hooks = await plugin({});
        for (const tool of ["read", "edit", "write", "apply_patch", "grep", "glob", "list"]) {
            await assert.rejects(hooks["tool.execute.before"]({ tool }, {}), /Native file tool .* is disabled/);
        }
        for (const tool of ["bash", "task", "tilth_tilth_read", "tilth_tilth_write", "custom"]) {
            await assert.doesNotReject(hooks["tool.execute.before"]({ tool }, {}), tool);
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
