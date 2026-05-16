#!/usr/bin/env bats
# Tests for chezmoi/.sync — first-time wiring, idempotence, the
# run_onchange installer script that copies dotfiles-owned skills into
# ~/.claude/skills via chezmoi/lib/install-local.sh, and the templated
# dotfiles (gitconfig, copilot/mcp-config.json, .chezmoi.toml.tmpl prompts).

load test_helper

setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
    export INSTALLER_TMPL="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_install-claude-skills.sh.tmpl"
}

teardown() { teardown_test_env; }

# ── chezmoi/.sync wiring ────────────────────────────────────────────────

@test "chezmoi/.sync creates chezmoi.toml on fresh setup" {
    [[ ! -e "$HOME/.config/chezmoi/chezmoi.toml" ]]

    run bash "$CHEZMOI_SYNC"
    assert_success

    assert_file_exists "$HOME/.config/chezmoi/chezmoi.toml"
    grep -qF "sourceDir = \"$REAL_DOTFILES_DIR/chezmoi\"" "$HOME/.config/chezmoi/chezmoi.toml"
}

@test "chezmoi/.sync is a no-op when chezmoi.toml already exists (preserves user edits)" {
    run bash "$CHEZMOI_SYNC"
    assert_success

    local config="$HOME/.config/chezmoi/chezmoi.toml"
    cat > "$config" <<EOF
sourceDir = "/some/user/override"

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

@test "chezmoi/.sync cleans up its mktemp scratch file" {
    run bash "$CHEZMOI_SYNC"
    assert_success

    if compgen -G "$HOME/.config/chezmoi/chezmoi-toml.*" >/dev/null; then
        echo "leftover mktemp scratch file in config dir" >&2
        return 1
    fi
}

# ── source-tree scaffold ────────────────────────────────────────────────

@test "chezmoi/.chezmoiroot exists" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot"
}

@test "chezmoi/run_onchange template references both helpers under chezmoi/lib" {
    assert_file_exists "$INSTALLER_TMPL"
    grep -qF 'lib/install-local.sh' "$INSTALLER_TMPL"
    grep -qF 'lib/install-external.sh' "$INSTALLER_TMPL"
    # shellcheck disable=SC2016 # literal text in the template, not a shell expansion
    grep -qF '$DOTFILES_ROOT/skills' "$INSTALLER_TMPL"
    grep -qF '.claude/skills' "$INSTALLER_TMPL"
    grep -qF '_registry.yaml' "$INSTALLER_TMPL"
}

@test "chezmoi/run_onchange template no longer references skills-install/" {
    if grep -qF 'skills-install/' "$INSTALLER_TMPL"; then
        echo "template still references the deleted skills-install/ directory" >&2
        return 1
    fi
}

@test "chezmoi/run_onchange template embeds a content hash so chezmoi re-runs on changes" {
    grep -qF 'Skills tree hash:' "$INSTALLER_TMPL"
    grep -qF 'output' "$INSTALLER_TMPL"
}

@test "chezmoi/run_onchange template hashes the same tree it installs from" {
    # Locks PR #1's flatten: hash-line tree path and installer source arg
    # must agree. Reverting one without the other would silently de-sync
    # the run_onchange trigger from the install source.
    grep -qF '/../skills -type f' "$INSTALLER_TMPL"
    # And the old nested path must be gone from both the hash and the exec line.
    if grep -qF '/../claude/skills' "$INSTALLER_TMPL"; then
        echo "template still references the pre-flatten claude/skills tree" >&2
        return 1
    fi
}

@test "chezmoi/run_onchange template guards Phase 2 behind 'gh skill --help'" {
    # Spec invariant (PR #2 §3): the external installer must skip silently
    # when gh is missing or `gh skill` is unavailable. Without this guard, a
    # machine without gh would fail chezmoi apply on every run.
    grep -qF 'command -v gh' "$INSTALLER_TMPL"
    grep -qF 'gh skill --help' "$INSTALLER_TMPL"
    # Phase 2 must also tolerate per-invocation failure so a flaky network
    # doesn't break chezmoi apply.
    grep -qF 'install-external.sh' "$INSTALLER_TMPL"
    grep -qE 'install-external\.sh.*\|\| *true' "$INSTALLER_TMPL"
}

@test "chezmoi/.chezmoiignore excludes lib/ so helpers aren't applied to \$HOME" {
    local ignore="$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    assert_file_exists "$ignore"
    grep -qE '^lib(/|$)' "$ignore"
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

# ── end-to-end: chezmoi apply runs the installer ───────────────────────

# ── templated dotfiles ─────────────────────────────────────────────────

@test "chezmoi source dir contains the expected templates" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoi.toml.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_gitconfig.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.gitattributes"
}

@test ".chezmoi.toml.tmpl prompts for email and work, and persists sourceDir" {
    local toml="$REAL_DOTFILES_DIR/chezmoi/.chezmoi.toml.tmpl"
    grep -q 'promptStringOnce . "email"' "$toml"
    grep -q 'promptBoolOnce' "$toml"
    grep -q '\.chezmoi\.sourceDir' "$toml"
}

@test "gitconfig template references .email and gates Uber URLs on .work" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_gitconfig.tmpl"
    grep -q 'email = {{ .email }}' "$tmpl"
    grep -q '{{- if .work }}' "$tmpl"
    grep -q 'code.uber.internal' "$tmpl"
}

@test "copilot template fails fast on missing env vars and renders both keys" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    grep -q 'CONTEXT7_API_KEY is not set' "$tmpl"
    grep -q 'TAVILY_API_KEY is not set' "$tmpl"
    grep -q 'env "CONTEXT7_API_KEY"' "$tmpl"
    grep -q 'env "TAVILY_API_KEY"' "$tmpl"
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
    grep -q 'chezmoi apply --force' "$CHEZMOI_SYNC"
}

# ── end-to-end: chezmoi apply runs the installer ───────────────────────

@test "chezmoi apply triggers the skill installer (real files in ~/.claude/skills)" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

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

    # The installer reads from the real dotfiles skills/ tree.
    # We just need to assert that chezmoi apply triggers the run_onchange
    # script, which exec's install-local.sh. After apply, at least one
    # known dotfiles-owned skill should land at ~/.claude/skills/ as a real
    # directory and the manifest should list it.
    run chezmoi apply --force
    assert_success

    assert_file_exists "$HOME/.claude/skills/.dotfiles-managed"
    [[ -s "$HOME/.claude/skills/.dotfiles-managed" ]]

    # Pick the first managed skill from the manifest and assert it exists
    # as a real directory (not a symlink).
    local first
    first=$(head -1 "$HOME/.claude/skills/.dotfiles-managed")
    [[ -n "$first" ]]
    [[ -d "$HOME/.claude/skills/$first" && ! -L "$HOME/.claude/skills/$first" ]]

    # The gitconfig template should now exist at the rendered target with
    # the bootstrapped email.
    assert_file_exists "$HOME/.gitconfig"
    grep -qF "email = test@example.com" "$HOME/.gitconfig"
    # work=false → Uber [url] redirects must NOT appear.
    if grep -qF 'code.uber.internal' "$HOME/.gitconfig"; then
        echo "Uber [url] redirects rendered even though work=false" >&2
        return 1
    fi

    # The copilot template should render with the env-supplied API keys.
    assert_file_exists "$HOME/.copilot/mcp-config.json"
    grep -qF '"CONTEXT7_API_KEY": "test-context7-key"' "$HOME/.copilot/mcp-config.json"
    grep -qF '"TAVILY_API_KEY": "test-tavily-key"' "$HOME/.copilot/mcp-config.json"
}

@test "copilot template fails fast when CONTEXT7_API_KEY is unset" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
work = false
TOML
    unset CONTEXT7_API_KEY
    export TAVILY_API_KEY="test-tavily-key"

    run chezmoi apply --force
    assert_failure
    assert_output_contains "CONTEXT7_API_KEY is not set"
}

@test "gitconfig template renders Uber URL redirects when work=true" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "paul.sorensen@uber.com"
work = true
TOML
    export CONTEXT7_API_KEY="test-context7-key"
    export TAVILY_API_KEY="test-tavily-key"

    run chezmoi apply --force
    assert_success

    assert_file_exists "$HOME/.gitconfig"
    grep -qF "email = paul.sorensen@uber.com" "$HOME/.gitconfig"
    grep -qF 'ssh://code.uber.internal/' "$HOME/.gitconfig"
    grep -qF 'gopkg.uberinternal.com' "$HOME/.gitconfig"
}
