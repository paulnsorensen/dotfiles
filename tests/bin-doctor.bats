#!/usr/bin/env bats
# Tests for bin/bin-doctor and bin/lib/bin-doctor.sh.
#
# WHY these matter: bin-doctor is the enforcement point for the one-install-
# path contract. A false negative lets a second copy of a tool shadow its
# pin (brew `rust` hid the mise rust pin for months on the Linux box). A false
# positive trains the reader to ignore the report. And `clean` runs unattended
# from a timer, so --dry-run must never execute a cleanup.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
REAL_DOTFILES_DIR="$DOTFILES_DIR"
REAL_PATH="$PATH"
REAL_HOME="$HOME"
CHEZMOI="$(command -v chezmoi || true)"

setup() {
    T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/bindoctor.XXXXXX")" && pwd)
    export HOME="$T/home"
    export CARGO_HOME="$HOME/.cargo"
    export XDG_DATA_HOME="$HOME/.local/share"
    export GOBIN="$T/nogo"
    export DOTFILES_DIR="$T/dotfiles"
    mkdir -p "$HOME" "$DOTFILES_DIR/bin" "$T/tools"
    LOG="$T/calls.log"
    : > "$LOG"
    # Real yq for bd_declared, exposed under a neutral dir.
    if command -v yq >/dev/null 2>&1; then
        ln -s "$(command -v yq)" "$T/tools/yq"
    fi
    # Core utilities only: /usr/bin itself may hold npm, go, or pipx, which
    # would leak real managers into the checks and the clean plan.
    mkdir -p "$T/sys"
    local tool
    for tool in bash sh env awk sed grep sort cut tr dirname basename readlink \
        mkdir chmod cat rm ln printf id head tail wc uniq; do
        [[ -x "/usr/bin/$tool" ]] && ln -s "/usr/bin/$tool" "$T/sys/$tool" && continue
        [[ -x "/bin/$tool" ]] && ln -s "/bin/$tool" "$T/sys/$tool"
    done
    BASE_PATH="$T/tools:$T/sys"
    export PATH="$BASE_PATH"
    # Keep bin-doctor from prepending the host's real manager dirs.
    export BIN_DOCTOR_KEEP_PATH=1
    PKGS="$T/packages.yaml"
    cat > "$PKGS" <<'EOF'
packages:
  - tree
  - mold: { platform: linux }
  - pi: { source: npm, pkg: "@earendil-works/pi-coding-agent", version: "1.0.0" }
  - ruff: { source: uv, version: "1.0.0" }
  - cargo-cache: { source: cargo, version: "0.8.3" }
EOF
    ALLOW="$T/allow"
    : > "$ALLOW"
    # shellcheck source=bin/lib/bin-doctor.sh
    source "$REAL_DOTFILES_DIR/bin/lib/bin-doctor.sh"
}

teardown() {
    export PATH="$REAL_PATH"
    [[ -n "${T:-}" ]] && rm -rf "$T"
}

# exe <path> — an executable stub that logs its argv to $LOG.
exe() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "${1##*/}" "$LOG" > "$1"
    chmod +x "$1"
}

# stub <name> <script body> — a fake command in $T/tools.
stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$T/tools/$1"
    chmod +x "$T/tools/$1"
}

# ── bd_manager_of ────────────────────────────────────────────────────

@test "manager_of classifies each install layout by path" {
    exe "$XDG_DATA_HOME/mise/installs/aqua-jq/1.8/jq"
    exe "$T/.linuxbrew/Cellar/jq/1.7/bin/jq"
    ln -s "../Cellar/jq/1.7/bin/jq" "$(mkdir -p "$T/.linuxbrew/bin" && echo "$T/.linuxbrew/bin/jq")"
    exe "$CARGO_HOME/bin/mdbook"
    exe "$XDG_DATA_HOME/uv/tools/ruff/bin/ruff"
    mkdir -p "$HOME/.local/bin"
    ln -s "$XDG_DATA_HOME/uv/tools/ruff/bin/ruff" "$HOME/.local/bin/ruff"
    exe "$T/npm/lib/node_modules/eslint/bin/eslint"
    mkdir -p "$T/npm/bin"
    ln -s ../lib/node_modules/eslint/bin/eslint "$T/npm/bin/eslint"
    exe "$T/opt/rustup/rustup"
    ln -s "$T/opt/rustup/rustup" "$CARGO_HOME/bin/cargo"
    exe "$DOTFILES_DIR/bin/claude"
    exe "$XDG_DATA_HOME/mise/shims/jq"

    [[ "$(bd_manager_of "$XDG_DATA_HOME/mise/installs/aqua-jq/1.8/jq")" == mise ]]
    [[ "$(bd_manager_of "$XDG_DATA_HOME/mise/shims/jq")" == mise ]]
    [[ "$(bd_manager_of "$T/.linuxbrew/bin/jq")" == brew ]]
    [[ "$(bd_manager_of "$CARGO_HOME/bin/mdbook")" == cargo ]]
    [[ "$(bd_manager_of "$CARGO_HOME/bin/cargo")" == rustup ]]
    [[ "$(bd_manager_of "$HOME/.local/bin/ruff")" == uv ]]
    [[ "$(bd_manager_of "$T/npm/bin/eslint")" == npm ]]
    [[ "$(bd_manager_of "$DOTFILES_DIR/bin/claude")" == wrapper ]]
    [[ "$(bd_manager_of /usr/bin/env)" == system ]]
}

# ── bd_check_shadows ─────────────────────────────────────────────────

@test "shadows: brew and mise copies of one command are one finding, winner first" {
    exe "$T/.linuxbrew/bin/jq"
    exe "$XDG_DATA_HOME/mise/installs/aqua-jq/1.8/jq"
    export PATH="$T/.linuxbrew/bin:$XDG_DATA_HOME/mise/installs/aqua-jq/1.8:$BASE_PATH"

    run bd_check_shadows "$ALLOW"
    [[ $status -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "shadow"$'\t'"jq"$'\t'"brew=$T/.linuxbrew/bin/jq, mise=$XDG_DATA_HOME/mise/installs/aqua-jq/1.8/jq" ]]
}

@test "shadows: system copies and dotfiles wrappers never count" {
    exe "$T/.linuxbrew/bin/env"
    exe "$T/.linuxbrew/bin/claude"
    exe "$DOTFILES_DIR/bin/claude"
    export PATH="$DOTFILES_DIR/bin:$T/.linuxbrew/bin:/usr/bin:$BASE_PATH"

    run bd_check_shadows "$ALLOW"
    [[ $status -eq 0 ]]
    [[ -z "$output" ]]
}

@test "shadows: a mise shim that only forwards to a cargo install is not a duplicate" {
    # mise's rust entry symlinks to ~/.cargo/bin, so mise makes shims for
    # every cargo-installed binary. Those shims are not a second install.
    exe "$CARGO_HOME/bin/bws"
    exe "$XDG_DATA_HOME/mise/shims/bws"
    exe "$XDG_DATA_HOME/mise/shims/jq"
    exe "$XDG_DATA_HOME/mise/installs/aqua-jq/1.8/jq"
    exe "$T/.linuxbrew/bin/jq"
    stub mise "echo '$XDG_DATA_HOME/mise/installs/aqua-jq/1.8'; echo '$CARGO_HOME/bin'"
    export PATH="$XDG_DATA_HOME/mise/shims:$CARGO_HOME/bin:$T/.linuxbrew/bin:$BASE_PATH"

    run bd_check_shadows "$ALLOW"
    [[ $status -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "shadow"$'\t'"jq"$'\t'* ]]
}

@test "shadows: the allowlist suppresses an accepted duplicate" {
    exe "$T/.linuxbrew/bin/jq"
    exe "$XDG_DATA_HOME/mise/installs/aqua-jq/1.8/jq"
    export PATH="$T/.linuxbrew/bin:$XDG_DATA_HOME/mise/installs/aqua-jq/1.8:$BASE_PATH"
    echo "shadow:jq   # accepted for this test" > "$ALLOW"

    run bd_check_shadows "$ALLOW"
    [[ $status -eq 0 ]]
    [[ -z "$output" ]]
}

# ── packages.yaml declarations ───────────────────────────────────────

@test "declared: npm entries yield both the key and the pkg name" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bd_declared "$PKGS" npm
    [[ $status -eq 0 ]]
    [[ "$output" == *"pi"* ]]
    [[ "$output" == *"@earendil-works/pi-coding-agent"* ]]
}

@test "declared: brew covers bare strings and map entries without a source" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bd_declared "$PKGS" brew
    [[ "$output" == *"tree"* ]]
    [[ "$output" == *"mold"* ]]
    [[ "$output" != *"ruff"* ]]
}

# ── cargo ────────────────────────────────────────────────────────────

@test "cargo: flags stray crates, stale metadata, and untracked files, not proxies" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    stub cargo "printf 'cargo-cache v0.8.3:\n    cargo-cache\nmdbook v0.5.4:\n    mdbook\ntilth v0.8.4:\n    tilth\n'"
    exe "$CARGO_HOME/bin/cargo-cache"
    exe "$CARGO_HOME/bin/mdbook"
    exe "$CARGO_HOME/bin/yazi"
    exe "$T/opt/rustup/rustup"
    ln -s "$T/opt/rustup/rustup" "$CARGO_HOME/bin/rustc"

    run bd_check_cargo "$PKGS" "$ALLOW"
    [[ $status -eq 0 ]]
    [[ "$output" == *"cargo-stray"$'\t'"mdbook"* ]]
    [[ "$output" == *"cargo-stray"$'\t'"tilth"* ]]
    [[ "$output" == *"cargo-stale"$'\t'"tilth"* ]]
    [[ "$output" == *"cargo-untracked"$'\t'"yazi"* ]]
    [[ "$output" != *"cargo-stray"$'\t'"cargo-cache"* ]]
    [[ "$output" != *"rustc"* ]]
    # exact finding set: mdbook and cargo-cache have real binaries, so
    # neither is stale or untracked even though mdbook is a stray.
    [[ "$output" != *"cargo-stale"$'\t'"cargo-cache"* ]]
    [[ "$output" != *"cargo-stale"$'\t'"mdbook"* ]]
    [[ "$output" != *"cargo-untracked"$'\t'"cargo-cache"* ]]
    [[ "$output" != *"cargo-untracked"$'\t'"mdbook"* ]]
    [[ "${#lines[@]}" -eq 4 ]]
}

# ── brew ─────────────────────────────────────────────────────────────

@test "brew: undeclared leaves are strays; rust beside rustup is a conflict" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    # shellcheck disable=SC2016  # $1 belongs to the stub script, not this shell
    stub brew 'case "$1" in
  leaves) printf "tree\nrust\nrustup\njq\ntinted-theming/tinted/tree\n" ;;
  list) exit 0 ;;
esac'
    echo "brew:rustup  # trust root" > "$ALLOW"

    run bd_check_brew "$PKGS" "$ALLOW"
    [[ $status -eq 0 ]]
    [[ "$output" == *"brew-stray"$'\t'"jq"* ]]
    [[ "$output" == *"brew-stray"$'\t'"rust"$'\t'* ]]
    [[ "$output" == *"conflict"$'\t'"rust"* ]]
    [[ "$output" != *$'\t'"rustup"$'\t'* ]]
    [[ "$output" != *$'\t'"tree"$'\t'* ]]
    [[ "$output" != *"tinted-theming/tinted/tree"* ]]
}

# ── npm / uv ─────────────────────────────────────────────────────────

@test "npm: a package declared by pkg: is not a stray; npm itself is ignored" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    stub npm "printf '/p/lib\n/p/lib/node_modules/npm\n/p/lib/node_modules/@earendil-works/pi-coding-agent\n/p/lib/node_modules/ccusage\n'"

    run bd_check_npm "$PKGS" "$ALLOW"
    [[ $status -eq 0 ]]
    [[ "$output" == "npm-stray"$'\t'"ccusage"$'\t'* ]]
    [[ "${#lines[@]}" -eq 1 ]]
}

@test "uv: tools not in packages.yaml are strays" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    stub uv "printf 'ruff v1.0.0\n- ruff\nprek v0.5.3\n- prek\n'"

    run bd_check_uv "$PKGS" "$ALLOW"
    [[ "$output" == "uv-stray"$'\t'"prek"$'\t'* ]]
    [[ "${#lines[@]}" -eq 1 ]]
}

# ── clean / outdated ─────────────────────────────────────────────────

@test "clean steps: only installed managers, cargo only with cargo-cache" {
    stub uv 'exit 0'
    stub cargo 'exit 1'
    run bd_clean_steps
    [[ "$output" == "uv"$'\t'"uv cache prune" ]]

    stub cargo 'exit 0'
    run bd_clean_steps
    [[ "${lines[0]}" == "cargo"$'\t'"cargo cache --autoclean" ]]
}

@test "clean steps never uninstall software unattended" {
    stub brew 'exit 0'
    stub mise 'exit 0'
    run bd_clean_steps
    [[ "$output" != *"brew autoremove"* ]]
    [[ "$output" != *"mise prune"* ]]
}

@test "bin-doctor clean --dry-run prints the plan and runs nothing" {
    stub uv "echo \"uv \$*\" >> '$LOG'"
    stub mise "echo \"mise \$*\" >> '$LOG'"

    run "$REAL_DOTFILES_DIR/bin/bin-doctor" clean --dry-run
    [[ $status -eq 0 ]]
    [[ "$output" == *"would run [mise] mise cache prune"* ]]
    [[ "$output" == *"would run [uv] uv cache prune"* ]]
    [[ "$output" != *"brew autoremove"* ]]
    [[ "$output" != *"mise prune"* ]]
    [[ ! -s "$LOG" ]]
}

@test "bin-doctor clean rejects an unknown flag and runs nothing" {
    stub uv "echo \"uv \$*\" >> '$LOG'"

    run "$REAL_DOTFILES_DIR/bin/bin-doctor" clean --dryrun
    [[ $status -eq 2 ]]
    [[ ! -s "$LOG" ]]
}

@test "bin-doctor clean runs every step and fails when one step fails" {
    stub uv "echo \"uv \$*\" >> '$LOG'; exit 1"
    stub npm "echo \"npm \$*\" >> '$LOG'"

    run "$REAL_DOTFILES_DIR/bin/bin-doctor" clean
    [[ $status -eq 1 ]]
    grep -qx "uv cache prune" "$LOG"
    grep -qx "npm cache verify" "$LOG"
}

# ── bd_bootstrap_path ───────────────────────────────────────────────

@test "bd_bootstrap_path puts mise shims first and linuxbrew HOME rustup ahead of linuxbrew HOME bin" {
    unset BIN_DOCTOR_KEEP_PATH
    mkdir -p "$HOME/.linuxbrew/bin" "$HOME/.linuxbrew/opt/rustup/bin" "$XDG_DATA_HOME/mise/shims"
    export PATH="$BASE_PATH"

    bd_bootstrap_path

    local idx_shims idx_rustup idx_brew
    idx_shims=$(tr ':' '\n' <<< "$PATH" | grep -nxF "$XDG_DATA_HOME/mise/shims" | head -1 | cut -d: -f1)
    idx_rustup=$(tr ':' '\n' <<< "$PATH" | grep -nxF "$HOME/.linuxbrew/opt/rustup/bin" | head -1 | cut -d: -f1)
    idx_brew=$(tr ':' '\n' <<< "$PATH" | grep -nxF "$HOME/.linuxbrew/bin" | head -1 | cut -d: -f1)

    [[ -n "$idx_shims" && -n "$idx_rustup" && -n "$idx_brew" ]]
    [[ "$idx_shims" -lt "$idx_rustup" ]]
    [[ "$idx_rustup" -lt "$idx_brew" ]]
}

# ── CLI check ────────────────────────────────────────────────────────

@test "bin-doctor check exits 0 when every binary has one path" {
    run env BIN_DOCTOR_PACKAGES="$PKGS" BIN_DOCTOR_ALLOW="$ALLOW" "$REAL_DOTFILES_DIR/bin/bin-doctor" check
    [[ $status -eq 0 ]]
    [[ "$output" == *"one install path"* ]]
}

@test "bin-doctor check exits 1 and names the fix for each category" {
    exe "$T/.linuxbrew/bin/jq"
    exe "$XDG_DATA_HOME/mise/installs/aqua-jq/1.8/jq"
    export PATH="$T/.linuxbrew/bin:$XDG_DATA_HOME/mise/installs/aqua-jq/1.8:$BASE_PATH"

    run env BIN_DOCTOR_PACKAGES="$PKGS" BIN_DOCTOR_ALLOW="$ALLOW" "$REAL_DOTFILES_DIR/bin/bin-doctor" check
    [[ $status -eq 1 ]]
    [[ "$output" == *"shadow — fix:"* ]]
    [[ "$output" == *"1 finding(s)"* ]]
}

# ── repo wiring ──────────────────────────────────────────────────────

@test "the shipped allowlist gives every entry a known kind" {
    local line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line// /}"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^(brew|cargo|uv|npm|shadow):[^:]+$ ]] || {
            echo "bad allowlist line: $line" >&2
            return 1
        }
    done < "$REAL_DOTFILES_DIR/packages/bin-doctor.allow"
}

@test "the weekly job runs bin-doctor clean on both platforms, resolved to the primary clone" {
    [[ -n "$CHEZMOI" ]] || skip "chezmoi not installed"
    local src="$REAL_DOTFILES_DIR/chezmoi" rendered primary_root
    export HOME="$REAL_HOME"
    export PATH="$REAL_PATH"
    command -v git >/dev/null 2>&1 || skip "git not installed"
    # A worktree's git-common-dir points at the main repo's .git, so its
    # parent is the primary clone — not this worktree, even though the
    # template renders from this worktree's chezmoi source.
    primary_root="$(dirname "$(git -C "$REAL_DOTFILES_DIR" rev-parse --path-format=absolute --git-common-dir)")"
    rendered=$("$CHEZMOI" --source "$src" execute-template < "$src/dot_config/systemd/user/bin-doctor-clean.service.tmpl")
    [[ "$rendered" == *"ExecStart=\"$primary_root/bin/bin-doctor\" clean"* ]]
    grep -qx "OnCalendar=weekly" "$src/dot_config/systemd/user/bin-doctor-clean.timer"
    grep -qx "Persistent=true" "$src/dot_config/systemd/user/bin-doctor-clean.timer"
    rendered=$("$CHEZMOI" --source "$src" execute-template < "$src/Library/LaunchAgents/com.dotfiles.bin-doctor-clean.plist.tmpl")
    [[ "$rendered" == *"<string>$primary_root/bin/bin-doctor</string>"* ]]
    [[ "$rendered" == *"<string>clean</string>"* ]]
}

@test "chezmoiignore keeps each platform's job off the other platform" {
    local ignore="$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    grep -q 'Library/LaunchAgents/com.dotfiles.bin-doctor-clean.plist' "$ignore"
    grep -q '.config/systemd/user/bin-doctor-clean.timer' "$ignore"
    grep -q '.config/systemd/user/bin-doctor-clean.service' "$ignore"
}
