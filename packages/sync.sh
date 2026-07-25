#!/bin/bash
############################
# packages/sync.sh
# Unified package sync from flat packages.yaml
# Uses SHA-256 hash cache to skip when unchanged
############################

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$SCRIPT_DIR/packages.yaml}"
CACHE_DIR="${CACHE_DIR:-${HOME}/.local/state/dotfiles}"
CACHE_FILE="${CACHE_FILE:-$CACHE_DIR/packages.hash}"
PLATFORM="$(uname)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

FAILED=()

log_info()    { echo -e "${BLUE}[packages]${NC} $1"; }
log_success() { echo -e "${GREEN}[packages]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[packages]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[packages]${NC} $1" >&2; }

# Linux Homebrew/yq bootstrap helpers (also reused by bootstrap-linux.sh).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-linux-bootstrap.sh"

if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_warning "packages.yaml not found"
    exit 0
fi

########## Cache

check_cache() {
    if [[ "${FORCE_PACKAGES:-false}" == "true" ]]; then
        log_info "FORCE_PACKAGES set, bypassing cache"
        return 1
    fi
    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        log_info "UPGRADE_MODE set, bypassing cache"
        return 1
    fi
    [[ -f "$CACHE_FILE" ]] || return 1
    local current stored
    current=$(shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1)
    stored=$(<"$CACHE_FILE")
    [[ "$current" == "$stored" ]]
}

save_cache() {
    mkdir -p "$CACHE_DIR"
    shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"
}

if check_cache; then
    log_success "packages.yaml unchanged (cached), skipping"
    exit 0
fi

########## Query helpers
# Entry format: bare string OR single-key map (key = name, value = overrides)
# Map queries use: to_entries[0] | .key = name, .value.* = properties

# Brew formula names for this platform, skipping the other platform's entries.
# Usage: get_platform_pkgs [--dev]
get_platform_pkgs() {
    local want_dev="${1:-}"
    local skip_platform
    if [[ "$PLATFORM" == "Darwin" ]]; then
        skip_platform="linux"
    else
        skip_platform="mac"
    fi

    if [[ -z "$want_dev" ]]; then
        {
            yq -r ".packages[] | select(kind == \"scalar\")" "$PACKAGES_FILE" 2>/dev/null
            yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select((.value.source // \"brew\") == \"brew\" and (.value.dev // false) == false and (.value.platform == \"$skip_platform\" | not)) | .key" "$PACKAGES_FILE" 2>/dev/null
        }
    else
        yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select((.value.source // \"brew\") == \"brew\" and .value.dev == true and (.value.platform == \"$skip_platform\" | not)) | .key" "$PACKAGES_FILE" 2>/dev/null
    fi
}

# Explicit source names (tap, cask)
# Usage: get_source_pkgs <source> [--dev]
get_source_pkgs() {
    local source="$1" want_dev="${2:-}"
    if [[ -z "$want_dev" ]]; then
        yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select(.value.source == \"$source\" and (.value.dev // false) == false) | .key" "$PACKAGES_FILE" 2>/dev/null
    else
        yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select(.value.source == \"$source\" and .value.dev == true) | .key" "$PACKAGES_FILE" 2>/dev/null
    fi
}

########## Brew

# Cask names flagged `greedy: false` — excluded from the greedy upgrade pass
# because they self-update in-app and their cask reinstall triggers repeated
# sudo/admin prompts (e.g. docker-desktop).
get_no_greedy_casks() {
    yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select(.value.source == \"cask\" and .value.greedy == false) | .key" "$PACKAGES_FILE" 2>/dev/null
}

# Install brew packages from a list, skipping already-installed ones
# Usage: brew_install_pkgs <label> <pkg_list> <installed_list> [--cask]
brew_install_pkgs() {
    local label="$1" pkg_list="$2" installed="$3" cask_flag="${4:-}"
    [[ -z "$pkg_list" ]] && return 0

    echo -e "\n${GREEN}${label}:${NC}"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        # Tap-qualified keys (user/tap/formula) install under their short
        # name — `brew list` prints `moshi-hook`, not `rjyo/moshi/moshi-hook` —
        # so compare by the path tail.
        if echo "$installed" | grep -qx "${pkg##*/}"; then
            echo "  + $pkg"
        else
            echo "  Installing $pkg..."
            # shellcheck disable=SC2086  # cask_flag intentionally unquoted
            if ! brew install $cask_flag "$pkg" </dev/null; then
                log_error "Failed to install $pkg"
                FAILED+=("$pkg")
            fi
        fi
    done <<< "$pkg_list"
}

# Greedy-upgrade auto_updates casks, skipping any flagged `greedy: false`.
# With no exclusions, defer to the cheap one-shot `brew upgrade --cask
# --greedy-auto-updates`. Otherwise enumerate the greedy-outdated set and
# upgrade only the casks not on the exclude list.
upgrade_casks_greedy() {
    local excluded
    excluded=$(get_no_greedy_casks)

    if [[ -z "$excluded" ]]; then
        brew upgrade --cask --greedy-auto-updates </dev/null || log_warning "brew cask upgrade failed"
        return 0
    fi

    local outdated to_upgrade=()
    if ! outdated=$(brew outdated --cask --greedy-auto-updates --quiet 2>/dev/null); then
        log_warning "brew outdated --cask failed; skipping greedy cask upgrade"
        return 0
    fi
    while IFS= read -r cask; do
        [[ -z "$cask" ]] && continue
        if grep -qxF "$cask" <<< "$excluded"; then
            echo "  + $cask (self-updates; excluded from greedy upgrade)"
            continue
        fi
        to_upgrade+=("$cask")
    done <<< "$outdated"

    if ((${#to_upgrade[@]})); then
        brew upgrade --cask "${to_upgrade[@]}" </dev/null || log_warning "brew cask upgrade failed"
    fi
}

sync_brew() {
    # Install the OS build toolchain first so any sudo prompt is up front.
    bootstrap_brew_deps_linux

    # Pick up an already-installed-but-unsourced linuxbrew *before* deciding to
    # bootstrap, so a present brew doesn't trigger a redundant installer run.
    if ! command -v brew &>/dev/null; then
        linuxbrew_shellenv
    fi

    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Freshly installed linuxbrew still isn't on PATH — source it now.
        linuxbrew_shellenv
    fi

    if ! command -v brew &>/dev/null; then
        log_error "Homebrew install failed — brew not on PATH"
        FAILED+=("homebrew")
        return 0
    fi

    log_info "Syncing brew packages"

    # Taps first (other packages may depend on them)
    local taps
    taps=$(get_source_pkgs "tap")
    if [[ -n "$taps" ]]; then
        echo -e "\n${GREEN}Taps:${NC}"
        local tapped
        tapped=$(brew tap)
        while IFS= read -r tap; do
            [[ -z "$tap" ]] && continue
            if echo "$tapped" | grep -qx "$tap"; then
                echo "  + $tap"
            else
                echo "  Installing tap $tap..."
                if ! brew tap "$tap" </dev/null; then
                    log_error "Failed to tap $tap"
                    FAILED+=("tap:$tap")
                    continue
                fi
            fi
            # Homebrew's recent tap-trust gate refuses to load formulae from
            # untrusted third-party taps, so a fresh install from one fails. Trust
            # each present tap idempotently. `trust` is a newer subcommand; `|| true`
            # keeps older Homebrew (no `trust` command) from breaking sync.
            brew trust "$tap" </dev/null >/dev/null 2>&1 || true
        done <<< "$taps"
    fi

    local installed_formulae installed_casks
    installed_formulae=$(brew list --formulae 2>/dev/null || true)
    installed_casks=$(brew list --cask 2>/dev/null || true)

    # Casks are macOS-only — `brew install --cask` errors on Linux.
    brew_install_pkgs "Formulae" "$(get_platform_pkgs)" "$installed_formulae"
    if [[ "$PLATFORM" == "Darwin" ]]; then
        brew_install_pkgs "Casks" "$(get_source_pkgs "cask")" "$installed_casks" --cask
    fi

    if [[ "${DOTFILES_DEV:-false}" == "true" ]]; then
        brew_install_pkgs "Dev formulae" "$(get_platform_pkgs "--dev")" "$installed_formulae"
        if [[ "$PLATFORM" == "Darwin" ]]; then
            brew_install_pkgs "Dev casks" "$(get_source_pkgs "cask" "--dev")" "$installed_casks" --cask
        fi
    fi

    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        log_info "Upgrading brew packages..."
        brew update </dev/null || log_warning "brew update failed"
        # Formulae only. A bare `brew upgrade` also upgrades any genuinely
        # outdated cask (no exclude flag), so a `greedy: false` cask like
        # docker-desktop would be reinstalled here — prompting for sudo/admin —
        # whenever its installed version lags the cask. Route *all* cask
        # upgrades through upgrade_casks_greedy instead, which honors the
        # exclusion list. `brew outdated --cask --greedy-auto-updates` is a
        # superset of the plain outdated set, so nothing is missed.
        brew upgrade --formula </dev/null || log_warning "brew upgrade failed"
        # Casks flagged `auto_updates true` (e.g. Cursor) are skipped by a plain
        # `brew upgrade`; --greedy-auto-updates version-checks them and reinstalls
        # only on a diff. Excludes `version :latest` casks (no version to compare,
        # would reinstall every run).
        #
        # Casks flagged `greedy: false` (e.g. docker-desktop) are excluded from
        # the greedy pass: they self-update in-app and their cask reinstall
        # prompts for sudo/admin multiple times. There's no `brew upgrade`
        # exclude flag, so enumerate the greedy-outdated set and drop them.
        [[ "$PLATFORM" == "Darwin" ]] && upgrade_casks_greedy
    fi

    log_success "Brew sync complete"
}

########## mise (version-managed tool installs)
# mise itself is the one deliberately-unpinned bootstrap tool: `mise install`
# unconditionally converges to whatever ~/.config/mise/config.toml declares
# (chezmoi-deployed separately), so the pinned surfaces live in that config,
# not here.

sync_mise() {
    if ! command -v mise &>/dev/null; then
        if ! command -v brew &>/dev/null; then
            log_warning "brew not found — skipping mise bootstrap"
            return 0
        fi
        log_info "Bootstrapping mise..."
        if ! brew install mise; then
            log_error "Failed to install mise"
            FAILED+=("mise")
            return 0
        fi
    fi

    log_info "Converging mise-managed tool versions..."
    if ! mise install </dev/null; then
        log_warning "mise install failed — continuing"
    fi
}

########## Cargo

sync_cargo() {
    local cargo_pkgs
    cargo_pkgs=$(yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "cargo") | [.key, (.value.git // ""), (.value.branch // ""), (.value.version // ""), (.value.rev // "")] | join("|")' "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$cargo_pkgs" ]] && return 0

    if ! command -v cargo &>/dev/null; then
        # Bootstrap toolchain if rustup is installed but no toolchain yet
        if command -v rustup &>/dev/null; then
            log_info "Bootstrapping Rust stable toolchain..."
            if ! rustup default stable; then
                log_error "Failed to bootstrap Rust toolchain"
                FAILED+=("rustup-bootstrap")
                return 0
            fi
            # Brew-installed rustup keeps cargo proxies in opt/rustup/bin
            local rustup_prefix rustup_bin
            rustup_prefix="$(brew --prefix rustup 2>/dev/null || true)"
            rustup_bin="$rustup_prefix/bin"
            if [[ -n "$rustup_prefix" && -d "$rustup_bin" ]]; then
                export PATH="$rustup_bin:$PATH"
            elif [[ -f "$HOME/.cargo/env" ]]; then
                # shellcheck disable=SC1091
                source "$HOME/.cargo/env"
            fi
        fi
        if ! command -v cargo &>/dev/null; then
            log_error "cargo not found — cannot install cargo-source packages (rustup is no longer dev-gated; install failed?)"
            FAILED+=("cargo-toolchain")
            return 0
        fi
    fi

    log_info "Syncing cargo packages"
    local installed
    installed=$(cargo install --list 2>/dev/null | grep -E '^\S' | cut -d' ' -f1 || true)

    # Install pass — only touch packages that aren't installed yet. The
    # upgrade pass below handles already-installed packages idempotently
    # (via cargo-install-update) instead of force-reinstalling every time.
    # Pinned packages (version or rev) are installed unconditionally every
    # run so drift is corrected, and excluded from the upgrade pass below.
    local all_names=() pinned_names=()
    while IFS='|' read -r name git_url branch version rev; do
        [[ -z "$name" ]] && continue
        all_names+=("$name")

        if [[ -n "$version" || -n "$rev" ]]; then
            pinned_names+=("$name")
            if [[ -n "$rev" && -z "$git_url" ]]; then
                log_error "Invalid cargo package config for $name: rev requires git_url"
                FAILED+=("$name")
                continue
            fi
            local pin_args=()
            if [[ -n "$rev" ]]; then
                pin_args+=(--git "$git_url" --rev "$rev")
                echo "  Installing $name from $git_url@$rev (pinned)..."
            else
                pin_args+=(--version "$version")
                echo "  Installing $name@$version (pinned)..."
            fi
            if ! cargo install "${pin_args[@]}" "$name" </dev/null; then
                log_error "Failed to install $name"
                FAILED+=("$name")
            fi
            continue
        fi

        if echo "$installed" | grep -qx "$name"; then
            echo "  + $name"
            continue
        fi

        if [[ -n "$branch" && -z "$git_url" ]]; then
            log_error "Invalid cargo package config for $name: branch requires git_url"
            FAILED+=("$name")
            continue
        fi

        local install_args=()
        [[ -n "$git_url" ]] && install_args+=(--git "$git_url")
        [[ -n "$branch" ]] && install_args+=(--branch "$branch")
        install_args+=("$name")

        if [[ -n "$git_url" ]]; then
            local source_desc="$git_url"
            [[ -n "$branch" ]] && source_desc="$source_desc#$branch"
            echo "  Installing $name from $source_desc..."
        else
            echo "  Installing $name..."
        fi
        if ! cargo install "${install_args[@]}" </dev/null; then
            log_error "Failed to install $name"
            FAILED+=("$name")
        fi
    done <<< "$cargo_pkgs"

    # Upgrade pass — cargo-install-update checks crates.io / git tip per
    # package and skips anything already at latest. Avoids the previous
    # force-reinstall-everything-every-time behavior of `dots up`. Pinned
    # packages are excluded so a pin never drifts to latest.
    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        if command -v cargo-install-update &>/dev/null; then
            log_info "Upgrading cargo packages (skipping up-to-date)..."
            if ((${#pinned_names[@]})); then
                local unpinned_names=()
                local n
                for n in "${all_names[@]}"; do
                    if ! printf '%s\n' "${pinned_names[@]}" | grep -qxF "$n"; then
                        unpinned_names+=("$n")
                    fi
                done
                if ((${#unpinned_names[@]})); then
                    cargo install-update "${unpinned_names[@]}" --git </dev/null || log_warning "cargo install-update failed"
                fi
            else
                cargo install-update --all --git </dev/null || log_warning "cargo install-update failed"
            fi
        else
            log_warning "cargo-update not installed — skipping cargo upgrade pass"
            log_warning "  Install with: cargo install cargo-update"
        fi
    fi

    log_success "Cargo sync complete"
}

########## Rustup proxies
# Brew-installed rustup doesn't always create ~/.cargo/bin proxies for
# toolchain binaries (rust-analyzer, rustfmt, etc.). Ensure they exist.

sync_rustup_proxies() {
    command -v rustup &>/dev/null || return 0
    local sysroot
    sysroot="$(rustup run stable rustc --print sysroot 2>/dev/null || true)"
    [[ -n "$sysroot" && -d "$sysroot/bin" ]] || return 0
    local toolchain_bin="$sysroot/bin"

    local cargo_bin="${HOME}/.cargo/bin"
    mkdir -p "$cargo_bin"

    local proxied=(rust-analyzer rustfmt cargo-fmt clippy-driver)
    for bin in "${proxied[@]}"; do
        [[ -x "$toolchain_bin/$bin" ]] || continue
        if [[ ! -e "$cargo_bin/$bin" ]]; then
            log_info "Creating rustup proxy: $bin"
            if ! ln -sf "$toolchain_bin/$bin" "$cargo_bin/$bin"; then
                log_error "Failed to create proxy: $bin"
                FAILED+=("rustup-proxy:$bin")
            fi
        fi
    done
}

########## NPM

sync_npm() {
    local npm_pkgs skip_platform
    if [[ "$PLATFORM" == "Darwin" ]]; then skip_platform="linux"; else skip_platform="mac"; fi
    npm_pkgs=$(yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select(.value.source == \"npm\" and (.value.platform == \"$skip_platform\" | not)) | [.key, (.value.pkg // .key), (.value.version // \"\")] | @tsv" "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$npm_pkgs" ]] && return 0

    if ! command -v npm &>/dev/null; then
        log_warning "npm not found — skipping npm packages (install node to enable)"
        return 0
    fi

    log_info "Syncing npm packages"
    local installed outdated
    installed=$(npm ls -g --json 2>/dev/null | jq -r '.dependencies // {} | keys[]' || true)

    # In upgrade mode, ask npm once which globals are outdated. Anything
    # not in this set is at latest and gets skipped — no more
    # reinstall-every-package every `dots up`. `npm outdated -g` exits
    # non-zero when packages are outdated (deliberate, per docs); the
    # real failure mode we guard against is registry / network / auth
    # errors, where stdout is empty or non-JSON. In that case we don't
    # know what's outdated, so fall back to the old "upgrade everything
    # already-installed" behavior rather than silently skipping every
    # package as "(latest)".
    outdated=""
    local outdated_unknown=false
    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        local outdated_raw outdated_stderr
        outdated_stderr=$(mktemp)
        outdated_raw=$(npm outdated -g --json 2>"$outdated_stderr") || true
        if echo "$outdated_raw" | jq -e 'type == "object"' &>/dev/null; then
            outdated=$(echo "$outdated_raw" | jq -r 'keys[]?' 2>/dev/null || true)
        else
            outdated_unknown=true
            log_warning "npm outdated -g failed; upgrading all installed globals instead"
            [[ -s "$outdated_stderr" ]] && log_warning "  $(head -1 "$outdated_stderr")"
        fi
        rm -f "$outdated_stderr"
    fi

    while IFS=$'\t' read -r name pkg version; do
        [[ -z "$name" ]] && continue

        if [[ -n "$version" ]]; then
            echo "  Installing $pkg@$version (pinned)..."
            if ! npm install -g "$pkg@$version" </dev/null; then
                log_error "Failed to install $pkg@$version"
                FAILED+=("$pkg")
            fi
            continue
        fi

        local already=false
        echo "$installed" | grep -qx "$pkg" && already=true

        if $already; then
            if [[ "${UPGRADE_MODE:-false}" != "true" ]]; then
                echo "  + $name"
                continue
            fi
            if ! $outdated_unknown && ! echo "$outdated" | grep -qx "$pkg"; then
                echo "  + $name (latest)"
                continue
            fi
        fi

        local action="Installing"
        $already && action="Upgrading"
        echo "  $action $pkg..."
        if ! npm install -g "$pkg" </dev/null; then
            log_error "Failed to $action $pkg"
            FAILED+=("$pkg")
        fi
    done <<< "$npm_pkgs"

    log_success "NPM sync complete"
}

########## UV (Python tools via `uv tool install`)

sync_uv() {
    local uv_pkgs
    # `flags` is emitted as a space-joined string in the third TSV column.
    # Empty / missing flags collapse to an empty field.
    # Joined with "|", not @tsv/real tabs — see sync_cargo's comment: bash's
    # `read` collapses tab runs even under a custom IFS, silently swallowing
    # an empty field (e.g. no flags) sitting next to a pinned version.
    uv_pkgs=$(yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "uv") | [.key, (.value.pkg // .key), ((.value.flags // []) | join(" ")), (.value.version // ""), (.value.rev // "")] | join("|")' "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$uv_pkgs" ]] && return 0

    if ! command -v uv &>/dev/null; then
        log_warning "uv not found — skipping uv tools (install uv to enable)"
        return 0
    fi

    log_info "Syncing uv tool packages"
    local installed
    installed=$(uv tool list 2>/dev/null | awk '/^[a-zA-Z]/ {print $1}' || true)

    local all_names=() pinned_names=()
    while IFS='|' read -r name pkg flags_str version rev; do
        [[ -z "$name" ]] && continue
        all_names+=("$name")
        # shellcheck disable=SC2206  # word-splitting on flags_str is intentional
        local flags_array=($flags_str)

        if [[ -n "$version" || -n "$rev" ]]; then
            pinned_names+=("$name")
            local target
            if [[ -n "$rev" ]]; then
                # git+URL@ref pins carry the ref inline (e.g. @main); swap it
                # for the real commit so the URL stays a single well-formed
                # git+ spec instead of appending a second @ref.
                target="${pkg/@main/@$rev}"
            elif [[ -n "$version" ]]; then
                target="$pkg==$version"
            else
                target="$pkg"
            fi
            echo "  Installing $target (pinned)..."
            if ! uv tool install ${flags_array[@]+"${flags_array[@]}"} "$target" </dev/null; then
                log_error "Failed to install $target"
                FAILED+=("$pkg")
            fi
            continue
        fi

        if echo "$installed" | grep -qx "$name"; then
            echo "  + $name"
        else
            echo "  Installing $pkg${flags_str:+ ($flags_str)}..."
            if ! uv tool install ${flags_array[@]+"${flags_array[@]}"} "$pkg" </dev/null; then
                log_error "Failed to install $pkg"
                FAILED+=("$pkg")
            fi
        fi
    done <<< "$uv_pkgs"

    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        log_info "Upgrading uv tools..."
        if ((${#pinned_names[@]})); then
            local unpinned_names=() n
            for n in "${all_names[@]}"; do
                if ! printf '%s\n' "${pinned_names[@]}" | grep -qxF "$n"; then
                    unpinned_names+=("$n")
                fi
            done
            if ((${#unpinned_names[@]})); then
                uv tool upgrade "${unpinned_names[@]}" </dev/null || log_warning "uv tool upgrade failed"
            fi
        else
            uv tool upgrade --all </dev/null || log_warning "uv tool upgrade --all failed"
        fi
    fi

    log_success "UV sync complete"
}

########## gh extensions

sync_gh_extensions() {
    local ext_pkgs
    ext_pkgs=$(yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "gh-extension") | [.key, (.value.pkg // .key), (.value.version // "")] | @tsv' "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$ext_pkgs" ]] && return 0

    if ! command -v gh &>/dev/null; then
        log_warning "gh not found — skipping gh extensions (install gh to enable)"
        return 0
    fi

    log_info "Syncing gh extensions"
    local installed
    # gh extension list emits tab-separated rows: "gh <name>\t<owner>/<repo>\t<version>"
    installed=$(gh extension list 2>/dev/null | awk -F'\t' '{print $2}' || true)

    local all_names=() pinned_names=()
    while IFS=$'\t' read -r name pkg version; do
        [[ -z "$name" ]] && continue
        all_names+=("$name")

        if [[ -n "$version" ]]; then
            pinned_names+=("$name")
            echo "  Installing $pkg --pin $version..."
            if ! gh extension install "$pkg" --pin "$version" </dev/null; then
                log_error "Failed to install $pkg"
                FAILED+=("$pkg")
            fi
            continue
        fi

        if echo "$installed" | grep -qx "$pkg"; then
            echo "  + $name"
        else
            echo "  Installing $pkg..."
            if ! gh extension install "$pkg" </dev/null; then
                log_error "Failed to install $pkg"
                FAILED+=("$pkg")
            fi
        fi
    done <<< "$ext_pkgs"

    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        log_info "Upgrading gh extensions..."
        if ((${#pinned_names[@]})); then
            local unpinned_names=() n
            for n in "${all_names[@]}"; do
                if ! printf '%s\n' "${pinned_names[@]}" | grep -qxF "$n"; then
                    unpinned_names+=("$n")
                fi
            done
            if ((${#unpinned_names[@]})); then
                gh extension upgrade "${unpinned_names[@]}" </dev/null || log_warning "gh extension upgrade failed"
            fi
        else
            gh extension upgrade --all </dev/null || log_warning "gh extension upgrade --all failed"
        fi
    fi

    log_success "gh extensions sync complete"
}

########## Native AI-harness CLIs
# claude and omp are managed through their own native installers and
# self-updaters, NOT Homebrew — the brew cask/formula lag the fast-moving
# release channels and shadow-fight the native ~/.local/bin binary on PATH.
# claude and codex are mise-managed (see sync_mise); this section migrates
# any stale native/brew binary off PATH so mise's shim is the only thing
# left. omp has no mise plugin, so it keeps its own native install +
# self-update.

OMP_PIN="v17.1.2"

# Brew package to migrate off, per harness ("" = none; "cask:NAME" = cask).
native_harness_brew_pkg() {
    case "$1" in
        claude) echo "cask:claude-code" ;;
        omp)    echo "omp" ;;
        *)      echo "" ;;
    esac
}

# Uninstall a lingering Homebrew copy so it stops shadowing the native binary.
migrate_harness_off_brew() {
    local harness="$1" spec cask_flag=""
    spec="$(native_harness_brew_pkg "$harness")"
    [[ -z "$spec" ]] && return 0
    command -v brew &>/dev/null || return 0

    # Capture the list first, then match the here-string. A `brew list | grep
    # -qx` pipeline is unsafe under `set -o pipefail`: grep -q closes the pipe
    # on first match and the still-producing brew gets SIGPIPE (141), so the
    # pipeline reports failure even on a match — silently skipping migration.
    local installed
    if [[ "$spec" == cask:* ]]; then
        cask_flag="--cask"
        spec="${spec#cask:}"
        installed=$(brew list --cask 2>/dev/null || true)
    else
        installed=$(brew list --formulae 2>/dev/null || true)
    fi
    grep -qxF "$spec" <<<"$installed" || return 0

    log_info "  Removing Homebrew $spec (now native-managed)..."
    # shellcheck disable=SC2086  # cask_flag intentionally unquoted (may be empty)
    if ! brew uninstall $cask_flag "$spec" </dev/null; then
        log_warning "brew uninstall $spec failed — continuing"
    fi
}

# Remove a stale native-installed binary for a mise-migrated harness so
# mise's shim is the only thing left on PATH.
migrate_harness_off_native() {
    local harness="$1"
    local path="$HOME/.local/bin/$harness"
    [[ -e "$path" ]] || return 0
    log_info "  Removing native $harness binary (now mise-managed)..."
    rm -f "$path"
}

sync_native_harnesses() {
    log_info "Syncing native AI-harness CLIs..."

    local harness
    for harness in claude codex; do
        migrate_harness_off_brew "$harness"
        migrate_harness_off_native "$harness"
    done

    migrate_harness_off_brew "omp"

    if ! command -v omp &>/dev/null; then
        echo "  Installing omp (native)..."
        if curl -fsSL https://omp.sh/install | sh -s -- --ref "$OMP_PIN"; then
            hash -r 2>/dev/null || true
            log_success "  Installed omp"
        else
            log_warning "  omp native install failed — continuing"
        fi
    fi

    if [[ "${UPGRADE_MODE:-false}" == "true" ]] && command -v omp &>/dev/null; then
        echo "  Updating omp..."
        if ! omp update </dev/null; then
            log_warning "omp update failed — continuing"
        fi
    fi

    log_success "Native harness sync complete"
}
########## Main

if [[ "$PLATFORM" == "Darwin" ]]; then
    if ! command -v yq &>/dev/null; then
        if command -v brew &>/dev/null; then
            log_info "Bootstrapping yq..."
            brew install yq
        else
            log_warning "yq not found and brew not available"
            exit 1
        fi
    fi
elif [[ "$PLATFORM" == "Linux" ]]; then
    command -v yq &>/dev/null && yq_is_mikefarah || bootstrap_yq_linux || exit 1
fi

# Bootstrap uv on Linux. uv is the linchpin for the agent-profile / base-
# profile pipeline (chezmoi's run_onchange_*-{agent,base}-profile.sh.tmpl
# both bail without it), and it isn't in Ubuntu's apt. Use the official
# astral installer to drop it into ~/.local/bin without sudo.
bootstrap_uv_linux() {
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    log_info "Bootstrapping uv → $bin_dir"
    if ! curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$bin_dir" INSTALLER_NO_MODIFY_PATH=1 sh; then
        log_error "uv install script failed"
        return 1
    fi
    hash -r 2>/dev/null || true
}

if [[ "$PLATFORM" == "Linux" ]] && ! command -v uv &>/dev/null; then
    bootstrap_uv_linux || log_warning "Continuing without uv — base-profile render will be skipped"
fi

if [[ "$PLATFORM" == "Darwin" || "$PLATFORM" == "Linux" ]]; then
    sync_brew
fi

sync_mise
sync_cargo
sync_rustup_proxies
sync_npm
sync_uv
sync_gh_extensions
sync_native_harnesses

if ((${#FAILED[@]})); then
    echo ""
    log_error "failed to install ${#FAILED[@]} package(s): ${FAILED[*]}"
    log_warning "cache NOT saved due to install failures"
    exit 1
fi

save_cache
log_success "Package sync complete"
