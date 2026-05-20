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
# reference} symlinks). Without the prelink, chezmoi's run_onchange
# install-hooks template lands files inside a real ~/.claude/hooks/ dir
# that claude/.sync later backs up — orphaning the deployed hook.

@test "chezmoi/.sync pre-links ~/.claude/{hooks,reference} on a fresh install" {
    # No ~/.claude at all — fresh-box state.
    [[ ! -e "$HOME/.claude" ]]

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

    [[ -L "$HOME/.claude/hooks" ]]
    [[ "$(readlink "$HOME/.claude/hooks")"     == "$REAL_DOTFILES_DIR/claude/hooks"     ]]
    [[ -L "$HOME/.claude/reference" ]]
    [[ "$(readlink "$HOME/.claude/reference")" == "$REAL_DOTFILES_DIR/claude/reference" ]]
}

@test "chezmoi/.sync prelink is idempotent (existing correct symlink preserved)" {
    mkdir -p "$HOME/.claude"
    ln -s "$REAL_DOTFILES_DIR/claude/hooks"     "$HOME/.claude/hooks"
    ln -s "$REAL_DOTFILES_DIR/claude/reference" "$HOME/.claude/reference"

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
    # Symlinks unchanged.
    [[ "$(readlink "$HOME/.claude/hooks")"     == "$REAL_DOTFILES_DIR/claude/hooks"     ]]
    [[ "$(readlink "$HOME/.claude/reference")" == "$REAL_DOTFILES_DIR/claude/reference" ]]
    # Prelink message only fires when it actually creates a link.
    [[ "$output" != *"Pre-linked"* ]]
}

@test "chezmoi/.sync prelink does not clobber a pre-existing real directory" {
    # If the user already has a real ~/.claude/hooks/ (e.g. a half-migrated
    # state), prelink must leave it alone — claude/.sync's backup pass is
    # the only thing that should touch real dirs at those paths.
    mkdir -p "$HOME/.claude/hooks"
    echo "user file" > "$HOME/.claude/hooks/sentinel"

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
    # Real dir + its contents preserved untouched.
    [[ -d "$HOME/.claude/hooks" && ! -L "$HOME/.claude/hooks" ]]
    [[ "$(cat "$HOME/.claude/hooks/sentinel")" == "user file" ]]
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
    grep -qE 'chezmoi .*apply --force' "$CHEZMOI_SYNC"
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
    # excluded_tools is overridden with the managed memory + onboarding list,
    # replacing whatever was there (here: ["some_tool"]).
    [[ "$(yq '.excluded_tools | length'       "$HOME/.serena/serena_config.yml")" == "7" ]]
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
