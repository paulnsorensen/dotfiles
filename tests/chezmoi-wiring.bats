#!/usr/bin/env bats
# Tests for chezmoi/.sync — first-time wiring, idempotence, the
# run_onchange installer script that copies dotfiles-owned skills into
# ~/.claude/skills via chezmoi/lib/install-local.sh, and the templated
# dotfiles (gitconfig, copilot/mcp-config.json, .chezmoi.toml.tmpl prompts).

load test_helper

setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
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

@test "chezmoi/.sync: missing config + chezmoi present + no TTY fails loud" {
    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run bash "$CHEZMOI_SYNC"
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

    run bash "$CHEZMOI_SYNC"
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

    run bash "$CHEZMOI_SYNC"
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

    run bash "$CHEZMOI_SYNC"
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
    run bash "$CHEZMOI_SYNC"
    assert_success
    grep -qF 'sourceDir = "/some/stale/checkout/chezmoi"' "$config"

    # Only the apply call should land in the args log — no init, no other
    # invocations.
    local args
    args=$(tr '\n' ' ' < "$HOME/chezmoi-args.log")
    [[ "$args" == "--source $REAL_DOTFILES_DIR/chezmoi apply --force " ]]
}

# ── legacy symlink migration ───────────────────────────────────────────

@test "chezmoi/.sync removes dangling ~/.gitconfig symlink pointing into dotfiles" {
    # Simulate the post-#167 state: ~/.gitconfig still symlinked at the old
    # pre-chezmoi location, target file deleted.
    ln -s "$REAL_DOTFILES_DIR/gitconfig" "$HOME/.gitconfig"
    [[ -L "$HOME/.gitconfig" ]]
    [[ ! -e "$HOME/.gitconfig" ]]  # dangling

    # Pre-populate a valid config so the script doesn't bail on missing
    # config before reaching the migration step.
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF

    # Mock chezmoi so apply is a no-op (we're testing migration, not apply).
    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    assert_success
    [[ ! -L "$HOME/.gitconfig" ]]
    [[ ! -e "$HOME/.gitconfig" ]]
    assert_output_contains "Removed legacy dotfiles symlink"
}

@test "chezmoi/.sync removes live ~/.gitconfig symlink that resolves into dotfiles" {
    # Symlink to a real file inside the dotfiles checkout — live, not dangling.
    # Migration must still claim this path because chezmoi will overwrite it.
    local fake_target="$REAL_DOTFILES_DIR/chezmoi/.gitattributes"
    [[ -f "$fake_target" ]]  # sanity check
    ln -s "$fake_target" "$HOME/.gitconfig"
    [[ -L "$HOME/.gitconfig" ]]
    [[ -e "$HOME/.gitconfig" ]]

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF

    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    assert_success
    [[ ! -e "$HOME/.gitconfig" ]]
}

@test "chezmoi/.sync preserves real file at ~/.gitconfig (no migration)" {
    # If the user already has a real ~/.gitconfig (chezmoi-rendered or
    # hand-edited), the migration must not touch it.
    printf '[user]\n\temail = real@example.com\n' > "$HOME/.gitconfig"
    [[ -f "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF

    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    assert_success
    [[ -f "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]
    grep -qF 'real@example.com' "$HOME/.gitconfig"
}

@test "chezmoi/.sync preserves ~/.gitconfig symlink pointing outside dotfiles" {
    # Symlink to a path outside the dotfiles checkout (e.g. user manages
    # their own gitconfig via a different tool). Migration must not touch it.
    local outside_target="$TEST_HOME/elsewhere/gitconfig"
    mkdir -p "$(dirname "$outside_target")"
    printf '[user]\n\temail = elsewhere@example.com\n' > "$outside_target"
    ln -s "$outside_target" "$HOME/.gitconfig"
    [[ -L "$HOME/.gitconfig" ]]

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF

    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    assert_success
    [[ -L "$HOME/.gitconfig" ]]
    [[ "$(readlink "$HOME/.gitconfig")" == "$outside_target" ]]
}

@test "chezmoi/.sync migrates ~/.copilot/mcp-config.json legacy symlink too" {
    # Smoke test that the migration list covers the other chezmoi-managed
    # path. Real-world this was a regular file, but if anyone left a
    # dotfiles-pointing symlink during a half-migration it must still be
    # claimed.
    mkdir -p "$HOME/.copilot"
    ln -s "$REAL_DOTFILES_DIR/nonexistent-mcp.json" "$HOME/.copilot/mcp-config.json"
    [[ -L "$HOME/.copilot/mcp-config.json" ]]

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF

    local fake_bin
    fake_bin=$(make_fake_chezmoi)
    PATH="$fake_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    assert_success
    [[ ! -e "$HOME/.copilot/mcp-config.json" ]]
}

# ── prelink_claude_writethrough (first-install symlink ordering) ───────
#
# Regression guard for the first-install race between chezmoi/.sync (runs
# first alphabetically) and claude/.sync (creates the ~/.claude/{hooks,
# reference, settings.json} symlinks). Without the prelink, chezmoi's
# ── claude source assembly (pre-apply) ────────────────────────────────
# chezmoi/.sync assembles the registry-selected ~/.claude payload into
# dot_claude/exact_* BEFORE chezmoi apply, so exact_ deletion semantics see a
# complete tree. The external-skill vendoring is fed from a seeded cache so
# these tests stay offline (a fake git that fails `pull` exercises the
# use-cached-checkout fallback).

# Seed the external-skill cache + a git shim so no network is touched.
seed_skill_cache_offline() {
    local cache="$TEST_HOME/.cache/dotfiles/claude-skill-sources"
    local src
    for src in paulnsorensen__easy-cheese paulnsorensen__skillz-that-grillz; do
        mkdir -p "$cache/$src/.git" "$cache/$src/skills/dummy-$src"
        echo "# dummy" > "$cache/$src/skills/dummy-$src/SKILL.md"
    done
    local fake_bin="$TEST_HOME/fake-git-bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/git"
    chmod +x "$fake_bin/git"
    echo "$fake_bin"
}

@test "chezmoi/.sync assembles dot_claude/exact_* before chezmoi apply" {
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF
    local git_bin fake_bin
    git_bin=$(seed_skill_cache_offline)
    fake_bin=$(make_fake_chezmoi)
    PATH="$git_bin:$fake_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    assert_success
    [[ "$output" == *"Assembled claude chezmoi source state"* ]]

    local src="$REAL_DOTFILES_DIR/chezmoi/dot_claude"
    local tree
    for tree in exact_skills exact_agents exact_commands exact_hooks exact_lib exact_reference exact_workflows; do
        [[ -d "$src/$tree" ]] || { echo "missing $src/$tree" >&2; return 1; }
    done
    # Registry-selected local skill assembled with exact_ prefix.
    [[ -d "$src/exact_skills/exact_de-slop" ]]
    # Vendored external skill (from the seeded offline cache).
    [[ -f "$src/exact_skills/exact_dummy-paulnsorensen__easy-cheese/SKILL.md" ]]
    # Rendered agent carries registry frontmatter.
    grep -q '^model: haiku$' "$src/exact_agents/whey-drainer.md"
    grep -q '^name: whey-drainer$' "$src/exact_agents/whey-drainer.md"
    # Hook scripts keep their executable_ attribute.
    [[ -f "$src/exact_hooks/executable_git-guard.sh" ]]
}

@test "chezmoi/.sync no longer pre-links ~/.claude/{hooks,reference} (exact_ dirs own them)" {
    [[ ! -e "$HOME/.claude" ]]
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "user@example.com"
work = false
EOF
    local git_bin fake_bin
    git_bin=$(seed_skill_cache_offline)
    fake_bin=$(make_fake_chezmoi)
    PATH="$git_bin:$fake_bin:$PATH"

    run bash "$CHEZMOI_SYNC"
    assert_success
    [[ "$output" != *"Pre-linked"* ]]
    # No write-through symlinks left behind — chezmoi (faked here) owns the
    # real dirs on apply.
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
    # No plaintext secrets: every mcp env value must be a ${VAR} passthrough.
    run yq -r '.claude.mcps[].env // {} | .[]' "$reg"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # shellcheck disable=SC2016  # literal ${ } passthrough form, not expansion
        [[ "$line" == '${'*'}' ]] || { echo "non-passthrough mcp env value: $line" >&2; return 1; }
    done <<<"$output"
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
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    local reg="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    local tok script found
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        # shellcheck disable=SC2013,SC2016  # word-split is intended; regex is a literal
        for script in $(grep -oE '(\$HOME/\.claude/hooks/)?[A-Za-z0-9_-]+\.(js|sh)' <<<"$tok"); do
            script="${script##*/}"
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

@test "copilot template emits literal \${VAR} placeholders, never resolved secrets" {
    # MCP-secret-passthrough: the template emits the LITERAL ${CONTEXT7_API_KEY}
    # / ${TAVILY_API_KEY} so Copilot expands them at launch — the secret stays
    # in .env and never lands in ~/.copilot/mcp-config.json. Render with real
    # secrets in the env and assert they do NOT appear in the output.
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    local rendered
    rendered="$(CONTEXT7_API_KEY=ctx7-real-secret TAVILY_API_KEY=tav-real-secret \
        chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")"
    # Valid JSON.
    jq -e . <<<"$rendered" >/dev/null
    # Literal placeholders present, both servers emitted unconditionally.
    # SC2016: intentional literal — the rendered value IS the string ${VAR}.
    # shellcheck disable=SC2016
    [[ "$(jq -r '.mcpServers.context7.env.CONTEXT7_API_KEY' <<<"$rendered")" == '${CONTEXT7_API_KEY}' ]]
    # shellcheck disable=SC2016
    [[ "$(jq -r '.mcpServers.tavily.env.TAVILY_API_KEY' <<<"$rendered")" == '${TAVILY_API_KEY}' ]]
    # No resolved secret leaked onto disk.
    if grep -qE 'ctx7-real-secret|tav-real-secret' <<<"$rendered"; then
        echo "copilot template leaked a resolved secret into the rendered config" >&2
        return 1
    fi
    # The removed unset-var guard branch must be gone.
    if grep -q '"mcpServers": {}' "$tmpl"; then
        echo "copilot template still carries the removed empty-stub guard" >&2
        return 1
    fi
}

@test "copilot template emits stdio serena, not serena-mux" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    local rendered
    rendered="$(chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")"
    # Valid JSON.
    jq -e . <<<"$rendered" >/dev/null
    # serena entry must use stdio command, not serena-mux.
    [[ "$(jq -r '.mcpServers.serena.command' <<<"$rendered")" == "serena" ]]
    # args must include start-mcp-server with copilot context.
    jq -e '.mcpServers.serena.args | index("start-mcp-server") != null' <<<"$rendered" >/dev/null
    jq -e '.mcpServers.serena.args | map(select(startswith("--context="))) | length == 1' <<<"$rendered" >/dev/null
    [[ "$(jq -r '.mcpServers.serena.args[] | select(startswith("--context="))' <<<"$rendered")" == "--context=copilot" ]]
    # No serena-mux env var.
    [[ "$(jq -r '.mcpServers.serena.env // empty' <<<"$rendered")" == "" ]]
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

@test "chezmoi/.sync references the init flow for TTY first-run" {
    # We can't reliably fake a TTY in bats, but the init branch must be
    # present in the script. Asserting on the source text locks in the
    # contract that a TTY + template + chezmoi binary triggers init.
    grep -q 'chezmoi init --source' "$CHEZMOI_SYNC"
    grep -q '\[\[ -t 0 \]\]' "$CHEZMOI_SYNC"
    grep -q '\.chezmoi\.toml\.tmpl' "$CHEZMOI_SYNC"
}

@test "chezmoi/.sync calls chezmoi apply --force after wiring config" {
    # Apply is unconditional (gated only on chezmoi presence) so templates
    # and run_onchange installers run on every dots sync.
    grep -qE 'chezmoi .*apply --force' "$CHEZMOI_SYNC"
}

# ── end-to-end: chezmoi apply runs the installer ───────────────────────

@test "chezmoi apply deploys the assembled ~/.claude payload + renders templates" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    # Feed the external-skill vendoring from the seeded offline cache so the
    # assembly step never touches the network.
    local git_bin
    git_bin=$(seed_skill_cache_offline)
    PATH="$git_bin:$PATH"

    # Templated dotfiles need [data] for .email and env vars for the
    # copilot template's fail-fast guard. Bootstrap both before .sync runs
    # so chezmoi apply renders cleanly.
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
work = false
TOML
    export CONTEXT7_API_KEY="test-context7-key"
    export TAVILY_API_KEY="test-tavily-key"

    run bash "$CHEZMOI_SYNC"
    assert_success

    run chezmoi apply --force
    assert_success

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

    # MCP-secret-passthrough: the copilot template renders the LITERAL ${VAR}
    # placeholders, NOT the resolved keys — Copilot expands them at launch, so
    # the secret stays in .env and never lands in this file on disk.
    assert_file_exists "$HOME/.copilot/mcp-config.json"
    # SC2016: the single quotes are intentional — we assert the LITERAL ${VAR}
    # placeholder text is present, not its expansion.
    # shellcheck disable=SC2016
    grep -qF '"CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"' "$HOME/.copilot/mcp-config.json"
    # shellcheck disable=SC2016
    grep -qF '"TAVILY_API_KEY": "${TAVILY_API_KEY}"' "$HOME/.copilot/mcp-config.json"
    # The supplied secret values must NOT be baked into the rendered file.
    if grep -qE 'test-context7-key|test-tavily-key' "$HOME/.copilot/mcp-config.json"; then
        echo "copilot mcp-config baked a resolved secret instead of a placeholder" >&2
        return 1
    fi
}

@test "copilot template emits servers with literal placeholders even when keys are unset" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    # MCP-secret-passthrough: because the env values are now runtime ${VAR}
    # placeholders (Copilot expands them at launch), there is no apply-time key
    # to resolve. The template therefore always emits the full server set —
    # even on a fresh box with no .env yet — instead of the old warnf +
    # empty-mcpServers stub. The MCPs simply won't work until .env is populated.
    #
    # Render the template in isolation (execute-template) rather than a full
    # `chezmoi apply`: apply would run the whole chezmoi script suite (the
    # ap-migration run_once, wholesale settings authorship, MCP reconcile)
    # against the test HOME — this test pins the copilot template alone.
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    local rendered
    rendered="$(env -u CONTEXT7_API_KEY -u TAVILY_API_KEY \
        chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")"
    # Valid JSON; both keyed servers present with literal placeholders.
    jq -e . <<<"$rendered" >/dev/null
    # SC2016: intentional literal — the rendered value IS the string ${VAR}.
    # shellcheck disable=SC2016
    [[ "$(jq -r '.mcpServers.context7.env.CONTEXT7_API_KEY' <<<"$rendered")" == '${CONTEXT7_API_KEY}' ]]
    # shellcheck disable=SC2016
    [[ "$(jq -r '.mcpServers.tavily.env.TAVILY_API_KEY' <<<"$rendered")" == '${TAVILY_API_KEY}' ]]
    # No empty-mcpServers stub fallback.
    [[ "$(jq -r '.mcpServers | length' <<<"$rendered")" -ge 4 ]]
}

# ── serena config (modify_ pattern) ────────────────────────────────────────
# Serena ships ~165 lines of inline-documented defaults; we only want to
# override three keys (web_dashboard, web_dashboard_open_on_launch,
# excluded_tools). A full-content chezmoi template would freeze Serena's
# defaults at the version we wrote against and strip the inline docs —
# anything Serena adds in a future release would silently disappear. The
# `modify_` pattern lets yq patch only the keys we care about while
# preserving everything else.

setup_serena_chezmoi_env() {
    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
work = false
TOML
    export CONTEXT7_API_KEY="test-context7-key"
    export TAVILY_API_KEY="test-tavily-key"
}

@test "serena: chezmoi source has modify_ script (not a full-content template)" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/dot_serena/modify_serena_config.yml"
    [[ ! -e "$REAL_DOTFILES_DIR/chezmoi/dot_serena/serena_config.yml.tmpl" ]] \
        || { echo "stray full-content template — should be removed in favor of modify_" >&2; return 1; }
}

@test "serena: modify_ script flips the three managed overrides" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    command -v yq      >/dev/null 2>&1 || skip "yq not installed"
    setup_serena_chezmoi_env

    # Seed a representative existing config with non-default values for the
    # three keys we override. The modify_ script must drive them to false / [].
    mkdir -p "$HOME/.serena"
    cat > "$HOME/.serena/serena_config.yml" <<YAML
# Serena config (test fixture)
language_backend: LSP
web_dashboard: true
web_dashboard_open_on_launch: true
excluded_tools:
  - some_tool
tool_timeout: 240
YAML

    run chezmoi apply --force "$HOME/.serena/serena_config.yml"
    assert_success

    [[ "$(yq '.web_dashboard'                 "$HOME/.serena/serena_config.yml")" == "false" ]]
    [[ "$(yq '.web_dashboard_open_on_launch'  "$HOME/.serena/serena_config.yml")" == "false" ]]
    # excluded_tools is overridden with the managed memory + onboarding +
    # initial_instructions + LSP (find_declaration / find_implementations /
    # get_diagnostics_for_file) list, replacing whatever was there (here: ["some_tool"]).
    [[ "$(yq '.excluded_tools | length'       "$HOME/.serena/serena_config.yml")" == "11" ]]
    [[ "$(yq '.excluded_tools | .[0]'         "$HOME/.serena/serena_config.yml")" == "write_memory" ]]
    [[ "$(yq '.excluded_tools | contains(["onboarding"])' "$HOME/.serena/serena_config.yml")" == "true" ]]
    [[ "$(yq '.excluded_tools | contains(["some_tool"])'  "$HOME/.serena/serena_config.yml")" == "false" ]]
    # And keys we don't touch must survive intact.
    [[ "$(yq '.language_backend' "$HOME/.serena/serena_config.yml")" == "LSP" ]]
    [[ "$(yq '.tool_timeout'     "$HOME/.serena/serena_config.yml")" == "240" ]]
}

@test "serena: modify_ script preserves Serena's inline doc comments" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    command -v yq      >/dev/null 2>&1 || skip "yq not installed"
    setup_serena_chezmoi_env

    mkdir -p "$HOME/.serena"
    cat > "$HOME/.serena/serena_config.yml" <<'YAML'
# upstream Serena docs — must survive the modify_ pass
# Possible values are:
#  * LSP: Use the language server protocol (LSP)
language_backend: LSP
web_dashboard: true
web_dashboard_open_on_launch: true
excluded_tools: []
YAML

    run chezmoi apply --force "$HOME/.serena/serena_config.yml"
    assert_success

    grep -qF 'upstream Serena docs'           "$HOME/.serena/serena_config.yml"
    grep -qF 'Use the language server protocol' "$HOME/.serena/serena_config.yml"
}

# Regression: the placeholder we write when serena isn't on PATH must not
# round-trip through yq on a subsequent apply. The bug it guards against:
# stdin matches PLACEHOLDER → filter resets `existing=` → bootstrap branch
# reads `~/.serena/serena_config.yml` (which IS the placeholder, since
# chezmoi just wrote it last apply) → `existing` is re-populated with the
# placeholder text → yq sees a non-empty input and emits a 3-key stub,
# permanently destroying Serena's ~165 lines of inline-documented defaults.
@test "serena: modify_ script does NOT round-trip the placeholder through yq" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    command -v yq      >/dev/null 2>&1 || skip "yq not installed"
    setup_serena_chezmoi_env

    mkdir -p "$HOME/.serena"
    cat > "$HOME/.serena/serena_config.yml" <<'YAML'
# serena not initialized; run `serena init`, then `chezmoi apply` again
YAML

    # Build a minimal PATH that has chezmoi + yq but not serena. The bug
    # fires only when `command -v serena` succeeds AND the live config is
    # the placeholder. To exercise the placeholder-loop protection honestly
    # we need serena off PATH so the bootstrap branch's live-file read is
    # the only contamination source.
    local chezmoi_dir yq_dir minimal_path
    chezmoi_dir=$(dirname "$(command -v chezmoi)")
    yq_dir=$(dirname "$(command -v yq)")
    minimal_path="/usr/bin:/bin:$chezmoi_dir:$yq_dir"
    [ -z "$(PATH="$minimal_path" command -v serena 2>/dev/null)" ] \
        || skip "serena found on minimal PATH; cannot isolate bootstrap branch"

    PATH="$minimal_path" run chezmoi apply --force "$HOME/.serena/serena_config.yml"
    assert_success

    # Placeholder must survive — both as the comment AND as the *only*
    # content. The bug would replace it with `web_dashboard: false\n...`.
    grep -qF '# serena not initialized' "$HOME/.serena/serena_config.yml"
    ! grep -qE '^web_dashboard:' "$HOME/.serena/serena_config.yml"
}

# Regression: when the live config is the placeholder AND serena IS on PATH,
# the bootstrap branch must call `serena init` to heal the file. The bug it
# guards against: `[ -f $live ] || serena init` short-circuits because the
# placeholder file already exists, so init is skipped, the live read yields
# the placeholder again, the filter resets `existing=`, and the script emits
# the placeholder forever. Stable fixed point on a broken state.
@test "serena: modify_ script bootstraps via serena init when the on-disk file is the placeholder" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    command -v yq      >/dev/null 2>&1 || skip "yq not installed"
    setup_serena_chezmoi_env

    mkdir -p "$HOME/.serena"
    cat > "$HOME/.serena/serena_config.yml" <<'YAML'
# serena not initialized; run `serena init`, then `chezmoi apply` again
YAML

    # Fake serena shim — only `init` is exercised. It writes a real config
    # over the placeholder, mimicking the live `serena init` behaviour.
    local shim_dir="$HOME/bin"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/serena" <<'SH'
#!/bin/sh
case "$1" in
  init)
    cat > "$HOME/.serena/serena_config.yml" <<'YAML'
language_backend: LSP
web_dashboard: true
web_dashboard_open_on_launch: true
excluded_tools: []
projects: []
YAML
    ;;
esac
SH
    chmod +x "$shim_dir/serena"

    local chezmoi_dir yq_dir minimal_path
    chezmoi_dir=$(dirname "$(command -v chezmoi)")
    yq_dir=$(dirname "$(command -v yq)")
    minimal_path="$shim_dir:/usr/bin:/bin:$chezmoi_dir:$yq_dir"

    PATH="$minimal_path" run chezmoi apply --force "$HOME/.serena/serena_config.yml"
    assert_success

    # Placeholder must be gone; the override pass must have run.
    ! grep -qF '# serena not initialized' "$HOME/.serena/serena_config.yml"
    [[ "$(yq '.web_dashboard'                "$HOME/.serena/serena_config.yml")" == "false" ]]
    [[ "$(yq '.web_dashboard_open_on_launch' "$HOME/.serena/serena_config.yml")" == "false" ]]
    [[ "$(yq '.language_backend'             "$HOME/.serena/serena_config.yml")" == "LSP" ]]

    # Second apply is idempotent — byte-level. The weak form (re-check
    # web_dashboard) would miss e.g. excluded_tools getting reshuffled or
    # comment lines being eaten. Hash-equality nails the entire surface.
    local hash_before hash_after
    hash_before=$(shasum -a 256 "$HOME/.serena/serena_config.yml" | awk '{print $1}')
    PATH="$minimal_path" run chezmoi apply --force "$HOME/.serena/serena_config.yml"
    assert_success
    hash_after=$(shasum -a 256 "$HOME/.serena/serena_config.yml" | awk '{print $1}')
    [[ "$hash_before" == "$hash_after" ]]
}

# Regression: real `serena init` loads-then-validates the existing config and
# aborts with "`projects` key not found" when the on-disk file is the stub.
# The script must remove the stub before calling init so init bootstraps from
# absence. Without the rm, init crashes on the stub, the live read yields the
# stub, and the script emits the stub forever — the exact stable-broken state
# the user hit on a fresh box. The shim here mimics serena's real behaviour
# (init fails if a projects-less config already exists); this test fails if the
# rm is removed.
@test "serena: modify_ script clears the stub so serena init can bootstrap over it" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    command -v yq      >/dev/null 2>&1 || skip "yq not installed"
    setup_serena_chezmoi_env

    mkdir -p "$HOME/.serena"
    cat > "$HOME/.serena/serena_config.yml" <<'YAML'
# serena not initialized; run `serena init`, then `chezmoi apply` again
YAML

    # Shim mimics real serena: `init` aborts if a config already exists
    # without a `projects` key, and only writes a fresh config from absence.
    local shim_dir="$HOME/bin"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/serena" <<'SH'
#!/bin/sh
case "$1" in
  init)
    cfg="$HOME/.serena/serena_config.yml"
    if [ -f "$cfg" ] && ! grep -q '^projects:' "$cfg"; then
      echo "projects key not found" >&2
      exit 1
    fi
    cat > "$cfg" <<'YAML'
language_backend: LSP
web_dashboard: true
web_dashboard_open_on_launch: true
excluded_tools: []
projects: []
YAML
    ;;
esac
SH
    chmod +x "$shim_dir/serena"

    local chezmoi_dir yq_dir minimal_path
    chezmoi_dir=$(dirname "$(command -v chezmoi)")
    yq_dir=$(dirname "$(command -v yq)")
    minimal_path="$shim_dir:/usr/bin:/bin:$chezmoi_dir:$yq_dir"

    PATH="$minimal_path" run chezmoi apply --force "$HOME/.serena/serena_config.yml"
    assert_success

    # Healed: stub gone, projects present, overrides applied.
    ! grep -qF '# serena not initialized' "$HOME/.serena/serena_config.yml"
    [[ "$(yq '.projects | length'  "$HOME/.serena/serena_config.yml")" == "0" ]]
    [[ "$(yq '.web_dashboard'      "$HOME/.serena/serena_config.yml")" == "false" ]]
}

# Regression: if `serena init` fails after the stub-on-disk gate fires,
# the script must fall through gracefully — the bootstrap branch swallows
# the failure with `|| true`, the live-file read still yields the stub,
# the filter resets `existing=`, and the final emit-stub branch writes
# the stub back. Documented residual-risk path; locking it in.
@test "serena: modify_ script falls through to stub when serena init fails" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    command -v yq      >/dev/null 2>&1 || skip "yq not installed"
    setup_serena_chezmoi_env

    mkdir -p "$HOME/.serena"
    cat > "$HOME/.serena/serena_config.yml" <<'YAML'
# serena not initialized; run `serena init`, then `chezmoi apply` again
YAML

    # Failing shim — `init` exits 1 without writing anything. Mimics a
    # serena binary present on PATH but unable to bootstrap (broken venv,
    # missing language-server dep, etc.).
    local shim_dir="$HOME/bin"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/serena" <<'SH'
#!/bin/sh
exit 1
SH
    chmod +x "$shim_dir/serena"

    local chezmoi_dir yq_dir minimal_path
    chezmoi_dir=$(dirname "$(command -v chezmoi)")
    yq_dir=$(dirname "$(command -v yq)")
    minimal_path="$shim_dir:/usr/bin:/bin:$chezmoi_dir:$yq_dir"

    PATH="$minimal_path" run chezmoi apply --force "$HOME/.serena/serena_config.yml"
    assert_success

    # Stub must survive verbatim; no yq-emitted 3-key file.
    grep -qF '# serena not initialized' "$HOME/.serena/serena_config.yml"
    ! grep -qE '^web_dashboard:' "$HOME/.serena/serena_config.yml"
    # Exactly the stub literal — nothing more, nothing less.
    [[ "$(wc -l < "$HOME/.serena/serena_config.yml")" -eq 1 ]]
}

# ── claude settings.json repo-authoritative via modify_ ────────────────────

@test "claude settings.json: authoritative source exists at lib/claude-settings-authoritative.json" {
    [[ -f "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json" ]]
}

@test "claude settings.json: authoritative source is valid JSON" {
    jq -e 'type == "object"' "$REAL_DOTFILES_DIR/chezmoi/lib/claude-settings-authoritative.json" >/dev/null
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
