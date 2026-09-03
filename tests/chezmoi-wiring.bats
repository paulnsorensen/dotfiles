#!/usr/bin/env bats
# Tests for chezmoi/.sync — first-time wiring, idempotence, the
# run_onchange installer script that copies dotfiles-owned skills into
# ~/.claude/skills via chezmoi/lib/install-local.sh, and the templated
# dotfiles (gitconfig, copilot/mcp-config.json, .chezmoi.toml.tmpl prompts).

load test_helper


setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
    export SYNC_LIB="$REAL_DOTFILES_DIR/.sync-lib.sh"
    # shellcheck source=../.sync-lib.sh
    source "$SYNC_LIB"
    # The ap live-install path (install-base-profile) and the claude asset
    # installer were retired (spec: chezmoi-authoritative-claude): ~/.claude
    # deploys via dot_claude/exact_* + modify_settings.json, and user-scope
    # MCPs reconcile via this run_onchange template.
    export MCP_TMPL="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_sync-claude-mcps.sh.tmpl"
}

teardown() { teardown_test_env; }

# ── chezmoi/.sync wiring ────────────────────────────────────────────────

# Helper: drop a fake chezmoi binary on PATH that records its args and
# (optionally) writes a config file when invoked as `chezmoi init`. Returns
# the bin-dir path so callers can extend PATH themselves.
make_fake_chezmoi() {
    local fake_bin="$TEST_HOME/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/chezmoi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$HOME/chezmoi-args.log"
if [[ "$1" == "init" ]]; then
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<TOML
sourceDir = "$3"

[data]
email = "init-mock@example.com"
work = false
TOML
fi
exit 0
SH
    chmod +x "$fake_bin/chezmoi"
    echo "$fake_bin"
}

run_chezmoi_preflight() {
    run prepare_chezmoi_wiring "$REAL_DOTFILES_DIR" "$REAL_DOTFILES_DIR/chezmoi"
}

write_valid_chezmoi_config() {
    local source_dir="${1:-$REAL_DOTFILES_DIR/chezmoi}"
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$source_dir"

[data]
email = "user@example.com"
work = false
EOF
}

make_isolated_chezmoi_source() {
    local root="$TEST_HOME/dotfiles"
    local source_dir="$root/chezmoi"
    mkdir -p "$source_dir"
    cp -R "$REAL_DOTFILES_DIR/chezmoi/." "$source_dir/"
    local sibling
    # bin/ carries lib/npm-nightly.sh, which the two nightly run_after
    # installers source through $SOURCE_DIR/..
    for sibling in agent-profile agents bin claude cursor; do
        ln -s "$REAL_DOTFILES_DIR/$sibling" "$root/$sibling"
    done
    echo "$source_dir"
}

@test "chezmoi/.sync: missing config + chezmoi present + no TTY fails loud" {
    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run_chezmoi_preflight
    assert_failure
    assert_output_contains "no TTY available to run init"
    # Critical: we must NOT write a stub. The whole point of the change is to
    # avoid the no-[data] zombie config that masked PR #167.
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]
}

@test "chezmoi/.sync: missing config + chezmoi absent exits clean without stub" {
    # Strip homebrew/cargo dirs from PATH so chezmoi resolves as not-found.
    # Keep /usr/bin + /bin so the script's core tools (rm, grep, mkdir, sed)
    # still work — clearing PATH entirely would break the script and the
    # bats teardown.
    PATH="/usr/bin:/bin"

    run_chezmoi_preflight
    assert_success
    assert_output_contains "Skipping chezmoi setup"
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]
}

@test "chezmoi/.sync: stale stub (sourceDir but no [data]) + no TTY fails loud" {
    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
# Pre-fix non-TTY fallback that PR #168 removes.
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"
EOF

    run_chezmoi_preflight
    assert_failure
    assert_output_contains "no [data] block"
    # Stub left in place for the user to inspect/delete manually.
    [[ -f "$HOME/.config/chezmoi/chezmoi.toml" ]]
}

@test "chezmoi/.sync: valid config (sourceDir + [data]) is preserved (no churn)" {
    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    local config="$HOME/.config/chezmoi/chezmoi.toml"
    mkdir -p "$(dirname "$config")"
    cat > "$config" <<EOF
sourceDir = "/some/user/override"

[data]
email = "user@example.com"
work = false

[diff]
exclude = ["scripts"]

[merge]
command = "vimdiff"
EOF

    local before
    before=$(shasum -a 256 "$config" | awk '{print $1}')

    run_chezmoi_preflight
    assert_success

    local after
    after=$(shasum -a 256 "$config" | awk '{print $1}')
    [[ "$before" == "$after" ]]

    grep -qF '[diff]' "$config"
    grep -qF '[merge]' "$config"
    grep -qF 'sourceDir = "/some/user/override"' "$config"
}

@test "chezmoi/.sync applies from current checkout even when config has an old sourceDir" {
    local fake_bin
    fake_bin=$(make_fake_chezmoi)

    local config="$HOME/.config/chezmoi/chezmoi.toml"
    mkdir -p "$(dirname "$config")"
    cat > "$config" <<'EOF'
sourceDir = "/some/stale/checkout/chezmoi"

[data]
email = "stale@example.com"
work = false
EOF

    PATH="$fake_bin:$PATH"
    run apply_chezmoi_source "$REAL_DOTFILES_DIR/chezmoi"
    assert_success
    grep -qF 'sourceDir = "/some/stale/checkout/chezmoi"' "$config"

    # Only the apply call should land in the args log — no init, no other
    # invocations.
    local args
    args=$(tr '\n' ' ' < "$HOME/chezmoi-args.log")
    [[ "$args" == "--source $REAL_DOTFILES_DIR/chezmoi apply --force " ]]
}

# ── legacy symlink migration ───────────────────────────────────────────

@test "chezmoi preflight removes dangling ~/.gitconfig symlink pointing into dotfiles" {
    ln -s "$REAL_DOTFILES_DIR/gitconfig" "$HOME/.gitconfig"
    [[ -L "$HOME/.gitconfig" ]]
    [[ ! -e "$HOME/.gitconfig" ]]

    run migrate_legacy_chezmoi_symlinks "$REAL_DOTFILES_DIR"
    assert_success
    [[ ! -L "$HOME/.gitconfig" ]]
    [[ ! -e "$HOME/.gitconfig" ]]
    assert_output_contains "Removed legacy dotfiles symlink"
}

@test "chezmoi preflight removes live ~/.gitconfig symlink that resolves into dotfiles" {
    local fake_target="$REAL_DOTFILES_DIR/chezmoi/.gitattributes"
    [[ -f "$fake_target" ]]
    ln -s "$fake_target" "$HOME/.gitconfig"

    run migrate_legacy_chezmoi_symlinks "$REAL_DOTFILES_DIR"
    assert_success
    [[ ! -e "$HOME/.gitconfig" ]]
}

@test "chezmoi preflight preserves real file at ~/.gitconfig" {
    printf '[user]\n\temail = real@example.com\n' > "$HOME/.gitconfig"

    run migrate_legacy_chezmoi_symlinks "$REAL_DOTFILES_DIR"
    assert_success
    [[ -f "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]
    grep -qF 'real@example.com' "$HOME/.gitconfig"
}

@test "chezmoi preflight preserves ~/.gitconfig symlink pointing outside dotfiles" {
    local outside_target="$TEST_HOME/elsewhere/gitconfig"
    mkdir -p "$(dirname "$outside_target")"
    printf '[user]\n\temail = elsewhere@example.com\n' > "$outside_target"
    ln -s "$outside_target" "$HOME/.gitconfig"

    run migrate_legacy_chezmoi_symlinks "$REAL_DOTFILES_DIR"
    assert_success
    [[ -L "$HOME/.gitconfig" ]]
    [[ "$(readlink "$HOME/.gitconfig")" == "$outside_target" ]]
}

@test "chezmoi preflight migrates ~/.copilot/mcp-config.json legacy symlink too" {
    mkdir -p "$HOME/.copilot"
    ln -s "$REAL_DOTFILES_DIR/nonexistent-mcp.json" "$HOME/.copilot/mcp-config.json"

    run migrate_legacy_chezmoi_symlinks "$REAL_DOTFILES_DIR"
    assert_success
    [[ ! -e "$HOME/.copilot/mcp-config.json" ]]
}

# ── claude source assembly (pre-apply) ────────────────────────────────
# External-skill vendoring is fed from a seeded cache so the retained
# end-to-end apply test stays offline.

# Seed the external-skill cache + a git shim so no network is touched.
seed_skill_cache_offline() {
    local cache="$TEST_HOME/.cache/dotfiles/claude-skill-sources"
    local registry="$REAL_DOTFILES_DIR/skills/_registry.yaml"
    # Registry-driven: seed every source at its skills_path so a registry
    # addition can't strand the offline vendor on a fake-git clone. Sources
    # with an explicit `skills:` list get those names seeded (the vendor
    # resolves the list against the cache; a dummy name would match nothing
    # and silently vendor zero skills); default-scan sources get dummy-<enc>.
    local src enc sp skill pin
    while IFS= read -r src; do
        [[ -z "$src" ]] && continue
        enc="${src//\//__}"
        sp=$(yq -r ".sources.\"$src\".skills_path // \"skills\"" "$registry")
        mkdir -p "$cache/$enc/.git"
        # A pinned source's cache must record its pin, as a prior sync would
        # have: offline (fetch fails) then falls back to the cached checkout
        # instead of hard-failing on an apparently-changed pin.
        pin=$(yq -r ".sources.\"$src\".pin // \"\"" "$registry")
        [[ -n "$pin" ]] && echo "$pin" > "$cache/$enc/.dotfiles-pin"
        local -a names=()
        while IFS= read -r skill; do
            [[ -n "$skill" && "$skill" != "null" ]] && names+=("$skill")
        done < <(yq -r ".sources.\"$src\".skills // [] | .[]" "$registry")
        (( ${#names[@]} > 0 )) || names=("dummy-$enc")
        for skill in "${names[@]}"; do
            mkdir -p "$cache/$enc/$sp/$skill"
            echo "# dummy" > "$cache/$enc/$sp/$skill/SKILL.md"
        done
    done < <(yq -r '.sources | keys | .[]' "$registry")
    local fake_bin="$TEST_HOME/fake-git-bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/git"
    chmod +x "$fake_bin/git"
    echo "$fake_bin"
}


@test "chezmoi preflight no longer pre-links ~/.claude/{hooks,reference}" {
    [[ ! -e "$HOME/.claude" ]]
    write_valid_chezmoi_config
    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    run_chezmoi_preflight
    assert_success
    [[ "$output" != *"Pre-linked"* ]]
    [[ ! -L "$HOME/.claude/hooks" ]]
    [[ ! -L "$HOME/.claude/reference" ]]
}

@test "chezmoi/.sync fails loud when the claude source assembly fails" {
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF
    local isolated_source="$TEST_HOME/chezmoi-source"
    mkdir -p "$isolated_source/.chezmoidata"
    cp "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml" "$isolated_source/.chezmoidata/"
    export CHEZMOI_SOURCE_DIR_OVERRIDE="$isolated_source"
    # Empty cache + failing git → external vendoring cannot clone → assembly
    # must abort the sync (a partial exact_ tree would DELETE live entries).
    local fake_bin="$TEST_HOME/fake-git-bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/git"
    chmod +x "$fake_bin/git"
    local cz_bin
    cz_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$cz_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    [[ $status -ne 0 ]]
    [[ "$output" == *"claude chezmoi source assembly failed"* ]]
    # chezmoi apply never ran (fake chezmoi logs its args).
    [[ ! -f "$HOME/chezmoi-args.log" ]] || ! grep -q '^apply$' "$HOME/chezmoi-args.log"
}

# ── github credential helper self-heal + prompt guard ──────────────────

@test "_cz_ensure_github_credential_helper wires gh when no helper is configured and gh is authed" {
    local fake_bin="$TEST_HOME/fake-gh-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/gh" <<SH
#!/usr/bin/env bash
if [[ "\$1 \$2" == "auth status" ]]; then exit 0; fi
if [[ "\$1 \$2" == "auth setup-git" ]]; then echo called >> "$TEST_HOME/gh-setup-git.log"; exit 0; fi
exit 1
SH
    chmod +x "$fake_bin/gh"

    PATH="$fake_bin:$PATH" run _cz_ensure_github_credential_helper
    assert_success
    assert_output_contains "wired gh as the git credential helper"
    assert_file_exists "$TEST_HOME/gh-setup-git.log"
}

@test "_cz_ensure_github_credential_helper is a no-op when a helper is already configured" {
    git config --global credential.https://github.com.helper store

    local fake_bin="$TEST_HOME/fake-gh-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/gh" <<SH
#!/usr/bin/env bash
echo called >> "$TEST_HOME/gh-invoked.log"
exit 0
SH
    chmod +x "$fake_bin/gh"

    PATH="$fake_bin:$PATH" run _cz_ensure_github_credential_helper
    assert_success
    [[ ! -f "$TEST_HOME/gh-invoked.log" ]]
}

@test "_cz_vendor_external_skills runs git clone with GIT_TERMINAL_PROMPT=0" {
    local fake_bin="$TEST_HOME/fake-git-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
printf 'GIT_TERMINAL_PROMPT=%s args=%s\n' "${GIT_TERMINAL_PROMPT-unset}" "$*" >> "$HOME/git-calls.log"
exit 1
SH
    chmod +x "$fake_bin/git"

    local registry="$TEST_HOME/registry.yaml"
    cat > "$registry" <<'YAML'
sources:
  someorg/somerepo:
    description: test
YAML

    PATH="$fake_bin:$PATH" run _cz_vendor_external_skills "$registry" "$TEST_HOME/dst" claude
    assert_failure
    assert_file_exists "$TEST_HOME/git-calls.log"
    grep -q '^GIT_TERMINAL_PROMPT=0 args=clone' "$TEST_HOME/git-calls.log"
}

@test "_cz_vendor_external_skills refreshes a branch pin when the remote moves" {
    export XDG_CACHE_HOME="$TEST_HOME/cache"

    # Local origin repo standing in for github.com/someorg/somerepo.
    local origin="$TEST_HOME/origin-repo"
    mkdir -p "$origin/skills/foo"
    git -C "$origin" init -q -b soak
    echo "v1" > "$origin/skills/foo/SKILL.md"
    git -C "$origin" add -A
    git -C "$origin" -c user.email=t@t -c user.name=t commit -qm v1

    # Pre-seed the cache exactly as a prior pinned sync would have left it,
    # so the function takes the existing-cache path (no network clone).
    local cache="$XDG_CACHE_HOME/dotfiles/claude-skill-sources/someorg__somerepo"
    mkdir -p "$(dirname "$cache")"
    git clone -q --depth 1 --branch soak "$origin" "$cache"
    echo soak > "$cache/.dotfiles-pin"

    # The branch moves on the remote after the cache was created.
    echo "v2" > "$origin/skills/foo/SKILL.md"
    git -C "$origin" add -A
    git -C "$origin" -c user.email=t@t -c user.name=t commit -qm v2

    local registry="$TEST_HOME/registry.yaml"
    cat > "$registry" <<'YAML'
sources:
  someorg/somerepo:
    description: test
    pin: soak
YAML

    run _cz_vendor_external_skills "$registry" "$TEST_HOME/dst" claude
    assert_success
    # An unchanged pin value must still track the branch tip: the vendored
    # skill carries the post-cache commit, not the frozen clone-time one.
    grep -rq "^v2$" "$TEST_HOME/dst"
}

# ── source-tree scaffold ────────────────────────────────────────────────

@test "chezmoi/.chezmoiroot exists" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot"
}

@test "retired ap-era installers are gone from the source tree" {
    local stale
    for stale in \
        "chezmoi/.chezmoiscripts/run_onchange_after_install-base-profile.sh.tmpl" \
        "chezmoi/.chezmoiscripts/run_onchange_after_install-claude-assets.sh.tmpl" \
        "chezmoi/lib/install-base-profile.sh" \
        "chezmoi/lib/install-claude-assets.sh" \
        "chezmoi/lib/agent-profile-sync.sh"; do
        if [[ -e "$REAL_DOTFILES_DIR/$stale" ]]; then
            echo "retired file still present: $stale" >&2
            return 1
        fi
    done
}

@test "claude registry exists and carries every managed section" {
    local reg="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    assert_file_exists "$reg"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    local key
    for key in mcps hooks enabledPlugins extraKnownMarketplaces permissions skills agents; do
        [[ "$(yq -r ".claude | has(\"$key\")" "$reg")" == "true" ]] \
            || { echo "claude.yaml missing section: $key" >&2; return 1; }
    done
    # Secret-bearing servers use the fixed local proxy and never carry
    # credential placeholders or envFile entries.
    local consumer
    for consumer in context7 tavily; do
        [[ "$(yq -r ".claude.mcps.$consumer.command" "$reg")" == "/usr/local/libexec/dotfiles/agent-secret-proxy" ]] \
            || { echo "claude MCP $consumer is not proxy-backed" >&2; return 1; }
        [[ "$(yq -r ".claude.mcps.$consumer.args | join(\" \")" "$reg")" == "--socket /var/run/dotfiles-agent-secrets/$consumer.sock" ]] \
            || { echo "claude MCP $consumer has the wrong proxy socket" >&2; return 1; }
        [[ "$(yq -r ".claude.mcps.$consumer | has(\"env\")" "$reg")" == "false" ]] \
            || { echo "claude MCP $consumer still carries an env block" >&2; return 1; }
        [[ "$(yq -r ".claude.mcps.$consumer | has(\"envFile\")" "$reg")" == "false" ]] \
            || { echo "claude MCP $consumer still carries envFile" >&2; return 1; }
    done
    local retired
    for retired in \
        CONTEXT7_API_KEY TAVILY_API_KEY TODOIST_API_KEY GITHUB_APP_PRIVATE_KEY \
        SERPER_API_KEY GH_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
        if grep -qF "$retired" "$reg"; then
            echo "retired secret name remains in claude registry: $retired" >&2
            return 1
        fi
    done
}

@test "claude registry: tilth retired inject-cwd hook and env marker stay gone" {
    # tilth retired the inject-cwd.js PreToolUse hook. A reappearing hook
    # entry or TILTH_MCP_CWD_HOOK_INJECTED marker would make an omitted cwd
    # silently fill with the session root instead of tilth's teaching refusal.
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    local reg="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    [[ "$(yq -r '.claude.hooks.PreToolUse[] | select(.matcher == "mcp__tilth__.*")' "$reg")" == "" ]] \
        || { echo "retired mcp__tilth__.* PreToolUse hook reappeared in claude.yaml" >&2; return 1; }
    [[ "$(yq -r '.claude.mcps.tilth | has("env")' "$reg")" == "false" ]] \
        || { echo "claude MCP tilth carries an env block (retired TILTH_MCP_CWD_HOOK_INJECTED?)" >&2; return 1; }
}

@test "claude registry: selected skills and agents resolve to real repo sources" {
    # A registry entry naming a skill/agent that no longer exists in the repo
    # would fail every `dots sync` at assembly time. Catch it in CI first.
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    local reg="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ -f "$REAL_DOTFILES_DIR/skills/$name/SKILL.md" ]] \
            || { echo "claude.yaml selects skill '$name' but skills/$name/SKILL.md is missing" >&2; return 1; }
    done < <(yq -r '.claude.skills // [] | .[]' "$reg")
    local body
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        body=$(yq -r ".agents.\"$name\".body_path // \"\"" "$REAL_DOTFILES_DIR/agents/registry.yaml")
        [[ -n "$body" && -f "$REAL_DOTFILES_DIR/$body" ]] \
            || { echo "claude.yaml selects agent '$name' but agents/registry.yaml body_path is missing ('$body')" >&2; return 1; }
    done < <(yq -r '.claude.agents // [] | .[]' "$reg")
}

@test "claude registry: every wired ~/.claude/hooks script has a deployable source" {
    # The hooks block wires commands like `node .../hook-runner.js bash-guard.js`
    # and `"$HOME/.claude/hooks/git-guard.sh"`. exact_hooks deploys from
    # claude/hooks + agents/hooks — a wired script missing from both would
    # break every session after apply. Check both the $HOME-pathed script and
    # relative *.js runner args.
    #
    # state.sh is exempt: it ships inside the tmux-claude-session-manager
    # TPM plugin (~/.tmux/plugins/...), installed by `prefix+I`, not by dots sync.
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    local reg="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    local -a exempt_scripts=("state.sh")
    local tok script found ex
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        # shellcheck disable=SC2013,SC2016  # word-split is intended; regex is a literal
        for script in $(grep -oE '(\$HOME/\.claude/hooks/)?[A-Za-z0-9_-]+\.(js|sh)' <<<"$tok"); do
            script="${script##*/}"
            for ex in "${exempt_scripts[@]}"; do
                [[ "$script" == "$ex" ]] && continue 2
            done
            found=false
            [[ -f "$REAL_DOTFILES_DIR/claude/hooks/$script" ]] && found=true
            [[ -f "$REAL_DOTFILES_DIR/agents/hooks/$script" ]] && found=true
            $found || { echo "claude.yaml hooks wire '$script' but no source in claude/hooks or agents/hooks" >&2; return 1; }
        done
    done < <(yq -r '.claude.hooks[][].hooks[].command' "$reg")
}

@test "MCP reconcile run_onchange embeds the registry mcps hash" {
    assert_file_exists "$MCP_TMPL"
    grep -qF '.claude.mcps | toJson | sha256sum' "$MCP_TMPL"
    grep -qF 'lib/claude-mcp-reconcile.sh' "$MCP_TMPL"
    grep -qF '.chezmoi-mcp-manifest' "$MCP_TMPL"
}

@test "plugin reconcile run_onchange embeds an installed user-scope ids projection" {
    local plugin_tmpl="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_sync-claude-plugins.sh.tmpl"
    assert_file_exists "$plugin_tmpl"
    # A projection of installed_plugins.json (not a whole-file hash — see the
    # in-template rationale) so an out-of-band uninstall re-runs the reconcile
    # on the next sync without any repo file changing (spec:
    # plugin-reconcile-self-heal, Change 1).
    grep -qF 'installed user-scope ids:' "$plugin_tmpl"
    grep -qF '.claude/plugins/installed_plugins.json' "$plugin_tmpl"
}

@test "plugin reconcile run_onchange embeds ownership manifest state projection" {
    local plugin_tmpl="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_sync-claude-plugins.sh.tmpl"
    assert_file_exists "$plugin_tmpl"
    grep -qF 'owned marketplaces manifest state:' "$plugin_tmpl"
    grep -qF 'missing' "$plugin_tmpl"
    grep -qF 'present-empty' "$plugin_tmpl"
    grep -qF 'present-nonempty' "$plugin_tmpl"
}

@test "MCP reconcile run_onchange renders and fails loud without jq/yq" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local script="$TEST_HOME/mcp-onchange.sh"
    chezmoi execute-template --source "$REAL_DOTFILES_DIR/chezmoi" \
        < "$MCP_TMPL" > "$script"
    chmod +x "$script"
    # Rendered hash line must not carry unexpanded template syntax.
    ! grep -qF '{{' "$script"
    # Minimal PATH (bash only): the jq/yq preflight must exit NONZERO. Exit 0
    # would let chezmoi record the run_onchange as done for the current mcps
    # hash — reconcile would then silently never run until the registry
    # mcps block next changes.
    local minimal_bin="$TEST_HOME/minimal-bin"
    mkdir -p "$minimal_bin"
    ln -s "$(command -v bash)" "$minimal_bin/bash"
    PATH="$minimal_bin" run bash "$script"
    assert_failure
    assert_output_contains "claude MCP reconcile cannot run"
}

@test "chezmoi/.chezmoiignore excludes lib/ so helpers aren't applied to \$HOME" {
    local ignore="$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    assert_file_exists "$ignore"
    grep -qE '^lib(/|$)' "$ignore"
}

@test ".chezmoiignore localLLM gate renders when the key is absent (missingkey-safe)" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    # chezmoi renders templates with missingkey=error. A bare `{{ .localLLM }}`
    # in .chezmoiignore would fail `chezmoi apply` on every machine whose
    # chezmoi.toml predates the localLLM flag (the key is simply absent). The
    # gate must use `get . "localLLM"` so an absent key falls back to ""/ignore.
    local cfg="$HOME/.config/chezmoi/chezmoi.toml"
    mkdir -p "$(dirname "$cfg")"
    cat > "$cfg" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
TOML
    run chezmoi --config "$cfg" --source "$REAL_DOTFILES_DIR/chezmoi" \
        execute-template < "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    assert_success
    # With localLLM absent (→ falsy), the stack tree + units must be ignored.
    assert_output_contains "local-llm/**"
    assert_output_contains ".config/systemd/user/llama-swap.service"
}

@test "skills-install/ directory is gone from the repo" {
    [[ ! -e "$REAL_DOTFILES_DIR/skills-install" ]]
}

@test "chezmoi/lib/install-local.sh exists and is executable" {
    [[ -x "$REAL_DOTFILES_DIR/chezmoi/lib/install-local.sh" ]]
}

@test "chezmoi/lib/install-external.sh exists and is executable" {
    [[ -x "$REAL_DOTFILES_DIR/chezmoi/lib/install-external.sh" ]]
}

@test "install-external.sh exits non-zero when an npx skills add fails (PR #196 regression)" {
    # Spec invariant (PR #196 finding 3): install-external.sh MUST propagate
    # failure so the chezmoi run_onchange records the apply as failed and
    # reruns next `dots sync`, rather than marking success and skipping
    # until the skills-tree hash changes. Without this exit-1, silent
    # partial installs persist — the exact bug PR #196 was filed to fix.
    local fake_bin="$TEST_HOME/fake-bin-failing-install"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/npx" <<'SH'
#!/usr/bin/env bash
# `npx skills add ...` fails (simulated clone/install error).
echo "fake: simulated npx skills add failure" >&2
exit 1
SH
    chmod +x "$fake_bin/npx"
    PATH="$fake_bin:$PATH"

    # Minimal registry with explicit `skills:` so install_source emits
    # `--skill fake-skill` (the discovery path is gone — npx does its own).
    local registry="$TEST_HOME/test-registry.yaml"
    cat > "$registry" <<YAML
sources:
  fake/repo:
    description: regression fixture for PR #196 finding 3
    skills:
      - fake-skill
YAML

    # Force a non-empty harness list so the script doesn't early-exit at the
    # SKILL_HARNESSES-empty branch. Use a valid agent ID so the allowlist
    # guard (mirrors agent_profile/fetch.py's SKILL_AGENT) passes — the test
    # is asserting *npx failure propagation*, not allowlist behavior. On dev
    # machines the real .env's SKILL_HARNESSES overrides this; harmless,
    # since every fake-npx invocation fails regardless of which IDs are in
    # the loop.
    export SKILL_HARNESSES="claude-code"

    run "$REAL_DOTFILES_DIR/chezmoi/lib/install-external.sh" "$registry"
    assert_failure
    assert_output_contains "source(s) failed"
}

# ── end-to-end: chezmoi apply runs the installer ───────────────────────

# ── templated dotfiles ─────────────────────────────────────────────────

@test "chezmoi source dir contains the expected templates" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoi.toml.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_gitconfig.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.gitattributes"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/dot_zprofile"
}

@test "dot_zprofile is static homebrew shellenv, no duplicate nvm, overlay markers intact" {
    local zprofile="$REAL_DOTFILES_DIR/chezmoi/dot_zprofile"
    # Static shellenv equivalent, not a `brew shellenv` fork on every login shell.
    grep -q 'export HOMEBREW_PREFIX="/opt/homebrew"' "$zprofile"
    # shellcheck disable=SC2016  # literal string to match in the file, not for expansion
    if grep -v '^#' "$zprofile" | grep -qF '$(brew shellenv'; then
        echo "dot_zprofile still forks brew shellenv instead of the static block" >&2
        return 1
    fi
    # nvm.sh must not be sourced directly here — the multiplier overlay owns it.
    if grep -q 'nvm.sh' "$zprofile"; then
        echo "dot_zprofile still double-sources nvm.sh outside the overlay" >&2
        return 1
    fi
    # multiplier-dots greps for these exact markers; they must stay byte-identical.
    grep -q '^# >>> multiplier overlay >>>$' "$zprofile"
    grep -q '^# <<< multiplier overlay <<<$' "$zprofile"
}

@test ".chezmoi.toml.tmpl prompts for email and persists sourceDir" {
    local toml="$REAL_DOTFILES_DIR/chezmoi/.chezmoi.toml.tmpl"
    grep -q 'promptStringOnce . "email"' "$toml"
    grep -q '\.chezmoi\.sourceDir' "$toml"
    # The work-machine prompt was removed with the employer git machinery;
    # per-repo email is native git (`git config user.email`). Guard the
    # *work* prompt specifically — not all promptBoolOnce — so a legitimate
    # boolean flag (e.g. localLLM) doesn't trip this invariant.
    if grep -qE 'promptBoolOnce \. "work"' "$toml"; then
        echo ".chezmoi.toml.tmpl still has the removed work prompt" >&2
        return 1
    fi
    # The localLLM flag must stay a persisted boolean prompt: the .chezmoiignore
    # gate reads .localLLM, so dropping the prompt would leave the key undefined
    # and break `chezmoi apply` (missingkey=error).
    grep -qE 'localLLM = \{\{ promptBoolOnce \. "localLLM"' "$toml"
}

@test "gitconfig template references .email and carries no employer machinery" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_gitconfig.tmpl"
    grep -q 'email = {{ .email }}' "$tmpl"
    # Public-repo guard: the template must carry no work gate and no
    # internal/employer hostname or address. Per-repo email is native git
    # (`git config user.email`), so no `.work`-gated block is needed.
    if grep -q '\.work' "$tmpl"; then
        echo "gitconfig template still references removed .work gate" >&2
        return 1
    fi
    if grep -qi 'uber' "$tmpl"; then
        echo "gitconfig template still references an employer hostname/address" >&2
        return 1
    fi
}

@test "copilot template emits fixed secret proxies with no retired credentials" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    local rendered
    rendered="$(CONTEXT7_API_KEY=ctx7-real-secret TAVILY_API_KEY=tav-real-secret \
        TODOIST_API_KEY=todo-real-secret SERPER_API_KEY=serper-real-secret \
        GH_TOKEN=gh-real-secret GITHUB_PERSONAL_ACCESS_TOKEN=pat-real-secret \
        GITHUB_APP_PRIVATE_KEY=github-app-real-secret \
        chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")"
    jq -e . <<<"$rendered" >/dev/null
    for consumer in context7 tavily; do
        jq -e ".mcpServers.$consumer.command == \"/usr/local/libexec/dotfiles/agent-secret-proxy\"" <<<"$rendered"
        jq -e ".mcpServers.$consumer.args == [\"--socket\", \"/var/run/dotfiles-agent-secrets/$consumer.sock\"]" <<<"$rendered"
        jq -e "(.mcpServers.$consumer | has(\"env\") | not)" <<<"$rendered"
        jq -e "(.mcpServers.$consumer | has(\"envFile\") | not)" <<<"$rendered"
    done
    local retired
    for retired in \
        CONTEXT7_API_KEY TAVILY_API_KEY TODOIST_API_KEY GITHUB_APP_PRIVATE_KEY \
        SERPER_API_KEY GH_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
        if grep -qF "$retired" <<<"$rendered"; then
            echo "retired secret name remains in Copilot config: $retired" >&2
            return 1
        fi
    done
    local value
    for value in \
        ctx7-real-secret tav-real-secret todo-real-secret github-app-real-secret \
        serper-real-secret gh-real-secret pat-real-secret; do
        if grep -qF "$value" <<<"$rendered"; then
            echo "secret value leaked into Copilot config: $value" >&2
            return 1
        fi
    done
}



@test "copilot sensitive-file-guard source files exist" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/hooks/executable_sensitive-file-guard.sh"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/hooks/sensitive-file-guard.json.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-copilot-guard.sh.tmpl"
}

@test "copilot hook config renders a preToolUse matcher and the deployed adapter path" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/hooks/sensitive-file-guard.json.tmpl"
    local rendered
    rendered="$(chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")"
    # Valid JSON with the documented shape.
    jq -e '.version == 1 and (.hooks.preToolUse | length) == 1' <<<"$rendered"
    # Matcher covers Copilot's shell + file tools (anchored regex on toolName).
    [[ "$(jq -r '.hooks.preToolUse[0].matcher' <<<"$rendered")" == "bash|powershell|view|edit|create" ]]
    # bash key points at the deployed adapter under ~/.copilot/hooks/.
    [[ "$(jq -r '.hooks.preToolUse[0].bash' <<<"$rendered")" == */.copilot/hooks/sensitive-file-guard.sh ]]
}

@test "copilot guard installer copies the single-sourced shared logic" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-copilot-guard.sh.tmpl"
    local rendered
    rendered="$(chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")"
    # Reuses the shared detection module, not a duplicate.
    grep -q 'agents/lib/sensitive-file-guard.js' <<<"$rendered"
    grep -q '.copilot/hooks/lib/sensitive-file-guard.js' <<<"$rendered"
    grep -q 'install-shared-assets.sh' <<<"$rendered"
}

@test ".gitattributes pins LF line endings inside chezmoi source" {
    grep -qE '\* +text +eol=lf' "$REAL_DOTFILES_DIR/chezmoi/.gitattributes"
}

@test ".chezmoiignore excludes .gitattributes so chezmoi doesn't apply it to \$HOME" {
    grep -qE '^\.gitattributes$' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
}

@test "old repo-root gitconfig and .copilot/ source files are gone" {
    [[ ! -e "$REAL_DOTFILES_DIR/gitconfig" ]]
    [[ ! -e "$REAL_DOTFILES_DIR/.copilot" ]]
}

# ── chezmoi/.sync first-run logic ──────────────────────────────────────

@test "chezmoi preflight references the init flow for TTY first-run" {
    grep -q 'chezmoi init --source' "$SYNC_LIB"
    grep -q '\[\[ -t 0 \]\]' "$SYNC_LIB"
    grep -q '\.chezmoi\.toml\.tmpl' "$SYNC_LIB"
    grep -q 'prepare_chezmoi_wiring' "$CHEZMOI_SYNC"
}

@test "chezmoi prepare wires only while direct and final phases fully apply" {
    local fake_root="$TEST_HOME/chezmoi-phase"
    mkdir -p "$fake_root/chezmoi"
    cp "$CHEZMOI_SYNC" "$fake_root/chezmoi/.sync"
    cat > "$fake_root/.sync-lib.sh" <<'SCRIPT'
prepare_chezmoi_wiring() {
    printf 'prepare\n'
}
assemble_chezmoi_sources() {
    printf 'assemble\n'
}
apply_chezmoi_source() {
    printf 'apply\n'
}
apply_mise_manifest() {
    printf 'mise-manifest\n'
}
SCRIPT

    run env CHEZMOI_SYNC_PHASE=prepare CHEZMOI_WIRING_SKIP=false \
        bash "$fake_root/chezmoi/.sync"
    assert_success
    [[ "$output" == $'prepare\nmise-manifest' ]]

    run env CHEZMOI_SYNC_PHASE= CHEZMOI_WIRING_SKIP=false \
        bash "$fake_root/chezmoi/.sync"
    assert_success
    [[ "$output" == $'prepare\nassemble\napply' ]]

    run env CHEZMOI_SYNC_PHASE=final CHEZMOI_WIRING_SKIP=false \
        bash "$fake_root/chezmoi/.sync"
    assert_success
    [[ "$output" == $'prepare\nassemble\napply' ]]
}

# Regression: the tracked mise manifest is an INPUT to package convergence.
# mise lets the live ~/.config/mise/config.toml override any --source manifest,
# so leaving it to the final apply pins the old version, starves `mise install`
# of the new one, and lets the harness-version gate skip the apply that would
# have fixed it — a deadlock no re-run escapes.
@test "chezmoi prepare lands the tracked mise manifest before package convergence" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    local source_dir="$TEST_HOME/mise-src"
    mkdir -p "$source_dir/dot_config/mise"
    cat > "$source_dir/dot_config/mise/config.toml" <<'TOML'
[tools]
"aqua:openai/codex" = "rust-v9.9.9"
TOML

    local target="$TEST_HOME/.config/mise/config.toml"
    mkdir -p "${target%/*}"
    cat > "$target" <<'TOML'
[tools]
"aqua:openai/codex" = "rust-v0.0.1"
TOML

    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    run apply_mise_manifest "$source_dir"
    assert_success

    # The stale live pin must be gone before any `mise install` reads it.
    grep -q 'rust-v9.9.9' "$target"
    ! grep -q 'rust-v0.0.1' "$target"
}

@test "chezmoi/.sync calls chezmoi apply --force after wiring config" {
    grep -qE 'chezmoi .*apply --force' "$SYNC_LIB"
    grep -q 'apply_chezmoi_source' "$CHEZMOI_SYNC"
}

@test "hallouminate nightly installer fails clearly without npm" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    local template="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_after_install-hallouminate.sh.tmpl"
    local script="$TEST_HOME/install-hallouminate.sh"
    chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$template" > "$script"
    mkdir -p "$TEST_HOME/empty-bin"

    run env PATH="$TEST_HOME/empty-bin" /bin/bash "$script"
    assert_failure
    assert_output_contains "npm is required to install @paulnsorensen/hallouminate-nightly"
}

@test "nightly installer removes a second npm prefix's copy of the bin" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    local template="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_after_install-tilth.sh.tmpl"
    local script="$TEST_HOME/install-tilth.sh"
    chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$template" > "$script"

    # Second prefix: a tilth bin symlinked into its own node_modules tree,
    # plus the npm that owns it. This is the copy that must go — a stale one
    # here pinned the hallouminate MCP to 0.7.0 for 34 nightlies.
    local second="$TEST_HOME/second-prefix"
    mkdir -p "$second/lib/node_modules/@paulnsorensen/tilth-nightly/bin" "$second/bin"
    printf '#!/usr/bin/env bash\n' > "$second/lib/node_modules/@paulnsorensen/tilth-nightly/bin/tilth"
    chmod +x "$second/lib/node_modules/@paulnsorensen/tilth-nightly/bin/tilth"
    ln -s "../lib/node_modules/@paulnsorensen/tilth-nightly/bin/tilth" "$second/bin/tilth"
    local rm_log="$TEST_HOME/second-prefix-rm.log"
    cat > "$second/bin/npm" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$rm_log"
exit 0
EOF
    chmod +x "$second/bin/npm"

    # An upstream package can expose the same bin from another prefix. It is
    # not the stale nightly and must not be removed.
    local upstream="$TEST_HOME/upstream-prefix"
    mkdir -p "$upstream/lib/node_modules/tilth/bin" "$upstream/bin"
    printf '#!/usr/bin/env bash\n' > "$upstream/lib/node_modules/tilth/bin/tilth"
    chmod +x "$upstream/lib/node_modules/tilth/bin/tilth"
    ln -s "../lib/node_modules/tilth/bin/tilth" "$upstream/bin/tilth"
    printf '#!/usr/bin/env bash\necho "upstream npm must not run" >&2\nexit 99\n' > "$upstream/bin/npm"
    chmod +x "$upstream/bin/npm"

    # Active npm: offline view, nothing installed, global prefix elsewhere.
    # The prefix must be a real directory or the prune stands down by design.
    local npm_bin="$TEST_HOME/shadow-npm-bin"
    mkdir -p "$npm_bin" "$TEST_HOME/active-prefix"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\ncase "$1 $2" in\n  "prefix -g") echo "%s" ;;\n  *) exit 1 ;;\nesac\n' "$TEST_HOME/active-prefix" > "$npm_bin/npm"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\n[[ "$1" != "-f" ]] || exit 1\nexec /usr/bin/readlink "$@"\n' > "$npm_bin/readlink"
    chmod +x "$npm_bin/npm" "$npm_bin/readlink"

    run env PATH="$npm_bin:$upstream/bin:$second/bin:/usr/bin:/bin" /bin/bash "$script"
    assert_success

    # The installer's resolve_path uses `cd -P`, so the prefix it names is
    # fully canonicalized. On macOS $TMPDIR lives under /var, a symlink to
    # /private/var, so the raw $second path never appears in the message.
    # Canonicalize the expectation the same way the script does; on Linux
    # (CI) this is a no-op.
    local second_real
    second_real="$(cd -P "$second" && printf '%s' "$PWD")"
    assert_output_contains "removed the shadow copy at $second_real/lib"

    # The removal went through that prefix's own npm, and named the nightly.
    [[ -f "$rm_log" ]] || { echo "second prefix npm was never invoked" >&2; return 1; }
    grep -qx "rm -g @paulnsorensen/tilth-nightly" "$rm_log"

    # The upstream copy keeps its own (warning-only) treatment.
    assert_output_not_contains "removed the shadow copy at $upstream"
    [[ -e "$upstream/lib/node_modules/tilth" ]]
}

# ── end-to-end: chezmoi apply runs the installer ───────────────────────

@test "chezmoi apply deploys the assembled ~/.claude payload + renders templates" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local isolated_source
    isolated_source=$(make_isolated_chezmoi_source)
    export CHEZMOI_SOURCE_DIR_OVERRIDE="$isolated_source"

    # Feed the external-skill vendoring from the seeded offline cache so the
    # assembly step never touches the network.
    local git_bin
    git_bin=$(seed_skill_cache_offline)
    PATH="$git_bin:$PATH"

    # The MCP-reconcile run_onchange fails loud without the `claude` CLI
    # (CI has no claude). Stub it — all reconcile writes go through the CLI
    # and only the exit code is checked, so a 0-exit stub keeps the e2e
    # hermetic on any machine.
    local claude_bin="$TEST_HOME/fake-claude-bin"
    mkdir -p "$claude_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$claude_bin/claude"
    chmod +x "$claude_bin/claude"
    PATH="$claude_bin:$PATH"

    # The hallouminate and tilth run_after installers resolve their npm
    # nightlies during apply. Keep the e2e hermetic: both see npm as offline
    # and absent, warn, and never attempt a global install.
    local npm_bin="$TEST_HOME/fake-npm-bin"
    mkdir -p "$npm_bin"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\ncase "$1 $2 $3" in\n  "view @paulnsorensen/hallouminate-nightly version"|"view @paulnsorensen/tilth-nightly version") exit 1 ;;\n  "ls -g @paulnsorensen/hallouminate-nightly"|"ls -g @paulnsorensen/tilth-nightly"|"ls -g hallouminate"|"ls -g tilth") exit 1 ;;\n  "prefix -g ") echo /nonexistent-npm-prefix ;;\n  "install -g @paulnsorensen/hallouminate-nightly@latest"|"install -g @paulnsorensen/tilth-nightly@latest") echo "unexpected npm install" >&2; exit 99 ;;\n  *) echo "unexpected npm $*" >&2; exit 99 ;;\nesac\n' > "$npm_bin/npm"
    chmod +x "$npm_bin/npm"
    PATH="$npm_bin:$PATH"

    # The Copilot template is proxy-backed and needs no credential environment.
    # Bootstrap the chezmoi data needed by the other templates before .sync.
    # The generated MCP config remains valid with all retired credentials unset.

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<TOML
sourceDir = "$isolated_source"

[data]
email = "test@example.com"
work = false
TOML

    run bash "$CHEZMOI_SYNC"
    assert_success
    assert_output_contains "Assembled claude chezmoi source state"
    # The reconcile ran (via the stub) and wrote its ownership manifest.
    assert_file_exists "$HOME/.claude/.chezmoi-mcp-manifest"

    run chezmoi apply --force
    assert_success

    # The single production assembly populated every exact_ category before
    # apply, including vendored skills and rendered/attributed files.
    local source_claude="$isolated_source/dot_claude"
    local tree
    for tree in exact_skills exact_agents exact_commands exact_hooks exact_lib exact_reference exact_workflows; do
        [[ -d "$source_claude/$tree" ]] \
            || { echo "missing $source_claude/$tree" >&2; return 1; }
    done
    [[ -f "$source_claude/exact_skills/exact_dummy-paulnsorensen__easy-cheese/SKILL.md" ]]
    grep -q '^name: whey-drainer$' "$source_claude/exact_agents/whey-drainer.md"
    grep -q '^model: haiku$' "$source_claude/exact_agents/whey-drainer.md"
    [[ -f "$source_claude/exact_hooks/executable_git-guard.sh" ]]

    # Skills deploy via the assembled dot_claude/exact_skills tree — real
    # directories at ~/.claude/skills/<name>, deletion-propagating.
    local skills_dir="$HOME/.claude/skills"
    [[ -d "$skills_dir" ]]
    [[ -d "$skills_dir/de-slop" && ! -L "$skills_dir/de-slop" ]]
    # Agents rendered with registry frontmatter.
    grep -q '^name: whey-drainer$' "$HOME/.claude/agents/whey-drainer.md"
    # Hooks land executable (settings.json hooks invoke them directly).
    [[ -x "$HOME/.claude/hooks/git-guard.sh" ]]
    # settings.json authored: registry-derived keys present.
    command -v jq >/dev/null 2>&1 && {
        jq -e '.hooks.PreToolUse | length > 0' "$HOME/.claude/settings.json" >/dev/null
        jq -e '.permissions.allow | length > 0' "$HOME/.claude/settings.json" >/dev/null
    }

    # The gitconfig template should now exist at the rendered target with
    # the bootstrapped email.
    assert_file_exists "$HOME/.gitconfig"
    grep -qF "email = test@example.com" "$HOME/.gitconfig"
    # Public-repo guard: no employer hostname/address in the rendered config.
    if grep -qi 'uber' "$HOME/.gitconfig"; then
        echo "employer hostname/address rendered into .gitconfig" >&2
        return 1
    fi

    # Fixed proxy arguments are the only secret-bearing MCP configuration.
    assert_file_exists "$HOME/.copilot/mcp-config.json"
    for consumer in context7 tavily; do
        jq -e ".mcpServers.$consumer.command == \"/usr/local/libexec/dotfiles/agent-secret-proxy\"" \
            "$HOME/.copilot/mcp-config.json"
        jq -e ".mcpServers.$consumer.args == [\"--socket\", \"/var/run/dotfiles-agent-secrets/$consumer.sock\"]" \
            "$HOME/.copilot/mcp-config.json"
        jq -e "(.mcpServers.$consumer | has(\"env\") | not)" \
            "$HOME/.copilot/mcp-config.json"
        jq -e "(.mcpServers.$consumer | has(\"envFile\") | not)" \
            "$HOME/.copilot/mcp-config.json"
    done
    local retired
    for retired in \
        CONTEXT7_API_KEY TAVILY_API_KEY TODOIST_API_KEY GITHUB_APP_PRIVATE_KEY \
        SERPER_API_KEY GH_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
        if grep -qF "$retired" "$HOME/.copilot/mcp-config.json"; then
            echo "retired secret name remains in rendered Copilot config: $retired" >&2
            return 1
        fi
    done
}

@test "copilot template emits fixed proxies with all retired credentials unset" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    # Render in isolation: proxy-backed servers do not depend on any secret
    # environment at apply time.
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    local rendered
    rendered="$(env -u CONTEXT7_API_KEY -u TAVILY_API_KEY \
        -u TODOIST_API_KEY -u GITHUB_APP_PRIVATE_KEY -u SERPER_API_KEY \
        -u GH_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN \
        chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")"
    jq -e . <<<"$rendered" >/dev/null
    for consumer in context7 tavily; do
        jq -e ".mcpServers.$consumer.command == \"/usr/local/libexec/dotfiles/agent-secret-proxy\"" <<<"$rendered"
        jq -e ".mcpServers.$consumer.args == [\"--socket\", \"/var/run/dotfiles-agent-secrets/$consumer.sock\"]" <<<"$rendered"
        jq -e "(.mcpServers.$consumer | has(\"env\") | not)" <<<"$rendered"
        jq -e "(.mcpServers.$consumer | has(\"envFile\") | not)" <<<"$rendered"
    done
    local retired
    for retired in \
        CONTEXT7_API_KEY TAVILY_API_KEY TODOIST_API_KEY GITHUB_APP_PRIVATE_KEY \
        SERPER_API_KEY GH_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
        if grep -qF "$retired" <<<"$rendered"; then
            echo "retired secret name remains in Copilot template output: $retired" >&2
            return 1
        fi
    done
    [[ "$(jq -r '.mcpServers | length' <<<"$rendered")" -ge 4 ]]
}



# ── claude settings.json repo-authoritative via modify_ ────────────────────

@test "claude settings.json: authoritative source exists at lib/claude-settings-authoritative.json" {
    [[ -f "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json" ]]
}

@test "claude settings.json: authoritative source is valid JSON" {
    jq -e 'type == "object"' "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json" >/dev/null
}

@test "claude settings.json: authoritative source carries no terminal-escape residue" {
    # The Claude CLI prints model names wrapped in SGR bold (ESC[1m ... ESC[22m).
    # Pasting that output into the seed strips the ESC byte but leaves the
    # literal "[1m" behind, producing an unusable model id. This has shipped
    # twice: "opus[1m]" and "claude-fable-5[1m]" (blame 86db029c). The
    # schemastore prek check does not enum model ids, so nothing caught it.
    ! grep -qE $'\x1b|\[[0-9]+m' \
        "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json"
}

@test "claude settings.json: authoritative source has NO legacy SessionStart hook entry" {
    # SessionStart wiring now renders into settings.json from the claude
    # registry `hooks` block (chezmoi/.chezmoidata/claude.yaml). A hand-written
    # duplicate in the authoritative seed would double-fire the hook AND
    # silently break when its hardcoded path drifts (the regression that
    # drove the migration to registry-rendered hooks).
    local has_session
    has_session=$(jq -r '.hooks.SessionStart // empty' \
        "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json")
    [[ -z "$has_session" ]]
}

@test "claude settings.json: authoritative source does NOT pre-bake ap-managed marketplace/plugin" {
    # `local` marketplace + plugin enablement are owned by the claude registry
    # (claude.yaml enabledPlugins / extraKnownMarketplaces), rendered into the
    # live file by modify_settings.json. Pre-baking them in the seed would
    # either look like a no-op (fine, but confusing) OR survive a registry
    # rename (broken).
    ! jq -e '.enabledPlugins["global@local"]' \
        "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json" >/dev/null 2>&1
    ! jq -e '.extraKnownMarketplaces["local"]' \
        "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json" >/dev/null 2>&1
}

@test "claude settings.json: source uses modify_ prefix, not create_/dot_settings" {
    # Repo-authoritative: modify_settings.json authors the live file wholesale
    # on every apply (seed + registry-rendered hooks/plugins/permissions),
    # overwriting in-app drift, with an unknown-key halt gate. The retired
    # `create_` seed (write-once) is gone; a bare dot_settings.json would
    # render without that gate and silently clobber unexpected live keys.
    [[ -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/modify_settings.json" ]]
    [[ -x "$REAL_DOTFILES_DIR/chezmoi/dot_claude/modify_settings.json" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/settings.json" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/dot_settings.json" ]]
}

@test "claude settings.json: authoritative source is .chezmoiignore'd (lib/) — never a target" {
    grep -qE '^lib/' "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
}

@test "claude settings.json: post-apply schema validator exists" {
    local s="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_after_validate-claude-settings.sh"
    [[ -f "$s" && -x "$s" ]]
    grep -qF 'check-jsonschema' "$s"
}

@test "claude settings.json: one-time migration script exists" {
    [[ -f "$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_once_before_migrate-claude-settings.sh" ]]
}

@test "claude settings.json: migration script removes legacy dotfiles symlink only" {
    # The script must NOT delete a settings.json that links to anywhere
    # other than $DOTFILES/claude/settings.json — the user may have
    # set up their own symlink.
    local script="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_once_before_migrate-claude-settings.sh"
    grep -qF '*/dotfiles/claude/settings.json' "$script"
    # shellcheck disable=SC2016
    grep -qE 'if[[:space:]]+\[\[ -L "\$target" \]\]' "$script"
}

@test "claude/.sync no longer symlinks settings.json" {
    # settings.json moved to chezmoi/dot_claude/create_settings.json;
    # claude/.sync's configs list must not include it (else a fresh sync
    # would re-create the legacy symlink, undoing the migration).
    local sync_script="$REAL_DOTFILES_DIR/claude/.sync"
    # The configs=( ... ) array shouldn't list `settings.json`.
    ! awk '/^configs=\(/,/^\)/' "$sync_script" | grep -qE '^\s*settings\.json\s*$'
}

@test "claude/settings.json source is gone from the repo (migrated to chezmoi)" {
    # Once committed, the legacy claude/settings.json must not exist —
    # the chezmoi seed is the source of truth. A re-introduced file would
    # quietly fight the chezmoi-seeded one via the legacy symlink path.
    [[ ! -f "$REAL_DOTFILES_DIR/claude/settings.json" ]]
}
