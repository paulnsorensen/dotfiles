#!/usr/bin/env bats
# Tests for chezmoi/.sync — first-time wiring, idempotence, the
# run_onchange installer script that copies dotfiles-owned skills into
# ~/.claude/skills via chezmoi/lib/install-local.sh, and the templated
# dotfiles (gitconfig, copilot/mcp-config.json, .chezmoi.toml.tmpl prompts).

load test_helper

setup() {
    setup_test_env
    export CHEZMOI_SYNC="$REAL_DOTFILES_DIR/chezmoi/.sync"
    # The install-claude-skills deploy script was retired (curd 7); its
    # deploy role — and the gh fail-loud + content-hash invariants below —
    # moved to install-base-profile, which renders the registry-derived
    # `base` profile (skills union included) into every harness via `ap`.
    export INSTALLER_TMPL="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-base-profile.sh.tmpl"
}

teardown() { teardown_test_env; }

# ── chezmoi/.sync wiring ────────────────────────────────────────────────

# Helper: drop a fake `npx` binary on PATH so `chezmoi apply` runs hermetically.
# It satisfies the run_onchange preflight (`command -v npx`) AND no-ops
# `npx skills add ...` — ap's external-skill fetch path — so the test never
# git-clones a real source repo over the network.
make_fake_npx() {
    local fake_bin="${1:-$TEST_HOME/fake-bin}"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/npx" <<'SH'
#!/usr/bin/env bash
# Args look like: --yes skills add <repo> --skill ... --agent ... -g --copy -y
# Succeed on everything (no network); the skills CLI is never really invoked.
exit 0
SH
    chmod +x "$fake_bin/npx"
    echo "$fake_bin"
}

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
# run_onchange base-profile render lands files inside a real ~/.claude/
# dir, and any settings write lands a real ~/.claude/settings.json file —
# both of which claude/.sync later backs up to .bak, orphaning everything
# chezmoi just wrote.

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
    # settings.json must NOT be pre-linked anymore — it's a chezmoi
    # create_ seed now (chezmoi/dot_claude/create_settings.json), and a
    # legacy symlink would block the seed step.
    [[ ! -L "$HOME/.claude/settings.json" ]]
}

@test "chezmoi/.sync prelink is idempotent (existing correct symlink preserved)" {
    mkdir -p "$HOME/.claude"
    ln -s "$REAL_DOTFILES_DIR/claude/hooks"         "$HOME/.claude/hooks"
    ln -s "$REAL_DOTFILES_DIR/claude/reference"     "$HOME/.claude/reference"

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
    [[ "$(readlink "$HOME/.claude/hooks")"         == "$REAL_DOTFILES_DIR/claude/hooks"         ]]
    [[ "$(readlink "$HOME/.claude/reference")"     == "$REAL_DOTFILES_DIR/claude/reference"     ]]
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

@test "chezmoi/.sync prelink does not clobber a pre-existing real settings.json" {
    # If the user has a hand-rolled ~/.claude/settings.json before adopting
    # dotfiles, prelink must leave it alone — claude/.sync's backup pass owns
    # real files at that path.
    mkdir -p "$HOME/.claude"
    echo '{"user":"keep"}' > "$HOME/.claude/settings.json"

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
    # Real file preserved untouched.
    [[ -f "$HOME/.claude/settings.json" && ! -L "$HOME/.claude/settings.json" ]]
    [[ "$(cat "$HOME/.claude/settings.json")" == '{"user":"keep"}' ]]
}

# ── source-tree scaffold ────────────────────────────────────────────────

@test "chezmoi/.chezmoiroot exists" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoiroot"
}

@test "chezmoi/run_onchange template drives the base-profile installer lib" {
    assert_file_exists "$INSTALLER_TMPL"
    grep -qF 'lib/install-base-profile.sh' "$INSTALLER_TMPL"
    # The unified deploy runs through the `ap` shim, not the retired
    # install-local / install-external helpers.
    grep -qF 'agent-profile/ap' "$INSTALLER_TMPL"
}

@test "chezmoi/run_onchange template no longer references the retired deploy helpers" {
    for stale in 'install-local.sh' 'lib/install-external.sh' 'skills-install/'; do
        if grep -qF "$stale" "$INSTALLER_TMPL"; then
            echo "template still references retired deploy path: $stale" >&2
            return 1
        fi
    done
}

@test "chezmoi/run_onchange template embeds a content hash so chezmoi re-runs on changes" {
    grep -qF 'hash:' "$INSTALLER_TMPL"
    grep -qF 'output' "$INSTALLER_TMPL"
}

@test "chezmoi/run_onchange template hashes the registries + skills tree it renders from" {
    # The base profile unions the three registries + the local skills tree
    # AND the global profile wraps base with operator-overlay fields;
    # the hash must cover all of them so a registry/skill/profile/hook-script
    # edit retriggers the render.
    grep -qF '/../skills ' "$INSTALLER_TMPL"
    grep -qF '/../profiles/base' "$INSTALLER_TMPL"
    grep -qF '/../profiles/global' "$INSTALLER_TMPL"
    grep -qF '/../agents/mcp/registry.yaml' "$INSTALLER_TMPL"
    # `agents/hooks` covers the registry AND its referenced scripts —
    # without script-content coverage, edits to a hook payload (e.g. the
    # SessionStart cheese-flair script) would NOT trigger re-deploy on
    # `dots sync`. Same for the cheese-flair lib + bank under agents/lib
    # and agents/reference.
    grep -qF '/../agents/hooks' "$INSTALLER_TMPL"
    grep -qF '/../agents/lib' "$INSTALLER_TMPL"
    grep -qF '/../agents/reference' "$INSTALLER_TMPL"
    # The `ap` renderer source shapes the output: a renderer-only fix (e.g.
    # the codex env-scrub) changes no registry/profile/skill input, so
    # without watching agent_profile/** the hash would stay stable and the
    # fix would never redeploy on a plain `dots sync`. It is the last path
    # before `-type f`.
    grep -qF '/../agent-profile/agent_profile -type f' "$INSTALLER_TMPL"
    # Bytecode is excluded so the hash tracks source edits, not interpreter
    # artifacts (a *.pyc regen would otherwise churn the hash spuriously).
    # Match dash-free substrings so the pattern isn't parsed as a grep flag.
    grep -qF "'*.pyc'" "$INSTALLER_TMPL"
    grep -qF "'*/__pycache__/*'" "$INSTALLER_TMPL"
    # The pre-flatten nested path must stay gone.
    if grep -qF '/../claude/skills' "$INSTALLER_TMPL"; then
        echo "template still references the pre-flatten claude/skills tree" >&2
        return 1
    fi
}

@test "chezmoi/run_onchange template fails loud when npx is missing" {
    # Spec invariant (PR #196, carried into curd 7): the deploy must FAIL
    # LOUD when npx is missing — external skills install through ap's fetch
    # path, which shells `npx skills add` (a git clone per source repo). A
    # silent skip masked partial installs; guard against it. (npx clones public
    # repos, so no GitHub-auth preflight is needed.)
    grep -qF 'command -v npx' "$INSTALLER_TMPL"
    # The render invocation must NOT tolerate per-invocation failure.
    if grep -qE 'install-base-profile\.sh.*\|\| *true' "$INSTALLER_TMPL"; then
        echo "base-profile render still has '|| true' — silent partial install regression risk" >&2
        return 1
    fi
}

# Helper: render the run_onchange template to a runnable script + drop a
# tripwire `ap` on PATH that fails loudly if the render is ever reached.
# Used by the preflight-FAILURE test below: the static grep above proves the
# check exists in the text; this proves it actually aborts at runtime BEFORE
# the `ap` render (a silent partial-install regression PR #196 guarded against).
render_base_profile_onchange() {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local script="$TEST_HOME/base-profile-onchange.sh"
    chezmoi execute-template --source "$REAL_DOTFILES_DIR/chezmoi" \
        < "$INSTALLER_TMPL" > "$script"
    chmod +x "$script"
    # If preflight wrongly passes through, the installer would invoke `ap`;
    # this tripwire turns that into a loud, assertable failure.
    local fake_bin="$TEST_HOME/tripwire-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/ap" <<'SH'
#!/usr/bin/env bash
echo "TRIPWIRE: ap render reached despite a failing npx preflight" >&2
exit 0
SH
    chmod +x "$fake_bin/ap"
    echo "$script"
}

@test "base-profile run_onchange skips cleanly when npx is missing" {
    # Behavior change: the linux-bootstrap PR (commit 5369aa3) softened
    # missing-npx from `exit 1` (fail-loud) to `exit 0` (clean skip with
    # pointer) — symmetric with the missing-uv branch. Rationale: on a
    # fresh Ubuntu box npx arrives from `apt install nodejs npm` after the
    # first sync prints its missing-tools list; failing the whole apply
    # there is hostile. The render still must NOT reach `ap` while npx
    # is absent (no tripwire trigger), and the skip diagnostic must
    # surface so the user knows why external skills weren't fetched.
    command -v uv >/dev/null 2>&1 || skip "uv not installed (run_onchange skips before preflight)"
    local script
    script=$(render_base_profile_onchange)
    local uv_bin="$TEST_HOME/uv-only-bin"
    mkdir -p "$uv_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$uv_bin/uv"
    chmod +x "$uv_bin/uv"
    PATH="$TEST_HOME/tripwire-bin:$uv_bin:/bin" run bash "$script"
    assert_success
    assert_output_contains "Skipping base-profile render (npx not found"
    [[ "$output" != *"TRIPWIRE"* ]]
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
    # per-repo email is native git (`git config user.email`).
    if grep -q 'promptBoolOnce' "$toml"; then
        echo ".chezmoi.toml.tmpl still has the removed work prompt" >&2
        return 1
    fi
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

@test "chezmoi apply triggers the base-profile render + renders templates" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    # The base-profile run_onchange (curd 7) fails loud when npx (Node) is
    # missing — external skills install via `npx skills add`. Stub a fake npx
    # that satisfies the `command -v npx` preflight and no-ops the fetch.
    local fake_npx_bin
    fake_npx_bin=$(make_fake_npx)
    PATH="$fake_npx_bin:$PATH"

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

    # Skills now deploy through the registry-derived `base` profile rendered
    # by `ap` (claude renderer → ~/.claude/plugins/local/base/skills/<name>).
    # The render needs uv (+ a real `ap` env); when uv is absent the
    # run_onchange skips by design, so gate the skill assertion on uv.
    if command -v uv >/dev/null 2>&1; then
        local skills_dir="$HOME/.claude/plugins/local/base/skills"
        [[ -d "$skills_dir" ]]
        # At least one dotfiles-owned (local path:) skill landed as a real dir.
        local first
        first=$(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        [[ -n "$first" ]]
        [[ -d "$first" && ! -L "$first" ]]
    fi

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
    # `chezmoi apply`: with the keys unset, apply would also drive the
    # base-profile `ap install`, which legitimately fails loud on the
    # non-optional context7/tavily ${VAR}s (criterion 2). That fail-loud is a
    # separate, intended behavior — this test pins the copilot template alone.
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
    # initial_instructions list, replacing whatever was there (here: ["some_tool"]).
    [[ "$(yq '.excluded_tools | length'       "$HOME/.serena/serena_config.yml")" == "8" ]]
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

# ── claude settings.json migration to chezmoi seed ─────────────────────────

@test "claude settings.json: chezmoi seed source exists at dot_claude/create_settings.json" {
    [[ -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json" ]]
}

@test "claude settings.json: chezmoi seed is valid JSON" {
    jq -e 'type == "object"' "$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json" >/dev/null
}

@test "claude settings.json: seed has NO legacy SessionStart hook entry" {
    # The base plugin's plugin.json (rendered by ap into
    # ~/.claude/plugins/local/global/.claude-plugin/plugin.json) now
    # provides the SessionStart wiring. A duplicate entry in settings.json
    # would double-fire the hook AND silently break when the legacy
    # symlinked path is gone (the regression that drove the migration).
    local has_session
    has_session=$(jq -r '.hooks.SessionStart // empty' \
        "$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json")
    [[ -z "$has_session" ]]
}

@test "claude settings.json: seed does NOT pre-bake ap-managed marketplace/plugin" {
    # `local` marketplace + `global@local` enablement are owned by the
    # claude renderer (ap install global) — they get merged in after
    # chezmoi seeds. Pre-baking would either cause the merge to look like
    # a no-op (fine, but confusing) OR survive a global rename (broken).
    ! jq -e '.enabledPlugins["global@local"]' \
        "$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json" >/dev/null 2>&1
    ! jq -e '.extraKnownMarketplaces["local"]' \
        "$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json" >/dev/null 2>&1
}

@test "claude settings.json: source filename uses create_ prefix (seed-once)" {
    # `create_` chezmoi semantic: never overwrite on subsequent applies.
    # Using `dot_settings.json` (always-render) would clobber user edits;
    # using `modify_settings.json` (script-driven mutation) would be
    # heavier than needed since ap handles the per-profile mutations.
    [[ -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/settings.json" ]]
    [[ ! -f "$REAL_DOTFILES_DIR/chezmoi/dot_claude/dot_settings.json" ]]
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
