#!/bin/bash
############################
# packages/sync.sh
# Unified package sync from packages.yaml + the mise/OMP pins
# Uses a composite SHA-256 cache to skip unchanged successful state
############################

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$SCRIPT_DIR/packages.yaml}"
CACHE_DIR="${CACHE_DIR:-${HOME}/.local/state/dotfiles}"
CACHE_FILE="${CACHE_FILE:-$CACHE_DIR/packages.hash}"
PLATFORM="$(uname)"
MISE_CONFIG_FILE="${MISE_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml}"
MISE_BOOTSTRAP_CONFIG_FILE="${MISE_BOOTSTRAP_CONFIG_FILE:-$SCRIPT_DIR/../chezmoi/dot_config/mise/config.toml}"
# renovate: datasource=github-tags depName=can1357/oh-my-pi
OMP_PIN="v17.1.4"

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

mise_config_path() {
    if [[ -f "$MISE_CONFIG_FILE" ]]; then
        printf '%s\n' "$MISE_CONFIG_FILE"
    elif [[ -f "$MISE_BOOTSTRAP_CONFIG_FILE" ]]; then
        printf '%s\n' "$MISE_BOOTSTRAP_CONFIG_FILE"
    fi
}

cache_hash() {
    local mise_config
    mise_config="$(mise_config_path)"
    {
        shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1
        if [[ -n "$mise_config" ]]; then
            shasum -a 256 "$mise_config" | cut -d' ' -f1
        else
            printf 'mise-config-missing\n'
        fi
        printf '%s\n' "$OMP_PIN"
    } | shasum -a 256 | cut -d' ' -f1
}

check_cache() {
    if [[ "${FORCE_PACKAGES:-false}" == "true" || "${PACKAGES_BOOTSTRAP_ONLY:-false}" == "true" ]]; then
        log_info "Package cache bypassed"
        return 1
    fi
    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        log_info "UPGRADE_MODE set, bypassing cache"
        return 1
    fi
    [[ -f "$CACHE_FILE" ]] || return 1
    [[ "$(cache_hash)" == "$(<"$CACHE_FILE")" ]]
}

save_cache() {
    mkdir -p "$CACHE_DIR"
    cache_hash > "$CACHE_FILE"
}

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

# Repairs a class of drift `brew_install_pkgs` and `upgrade_casks_greedy`
# can't see: brew's own state says a managed cask is installed, but its app
# bundle was deleted out-of-band (e.g. dragged to the Trash). `brew list
# --cask` still lists it, so the install pass skips it as already-present,
# and there's no upgrade path that would ever reinstall it — real incident:
# Cursor.app vanished from /Applications while `brew list --cask` still
# showed `cursor`, requiring a manual `brew reinstall --cask cursor`.
# Two brew calls are cheap enough to run even when the manifest-hash cache
# short-circuits the rest of sync_brew.
heal_missing_cask_apps() {
    [[ "$PLATFORM" == "Darwin" ]] || return 0
    command -v brew &>/dev/null || return 0
    local managed installed
    managed=$(get_source_pkgs "cask")
    if [[ "${DOTFILES_DEV:-false}" == "true" ]]; then
        managed+=$'\n'"$(get_source_pkgs "cask" "--dev")"
    fi
    [[ -n "$managed" ]] || return 0
    installed=$(brew list --cask 2>/dev/null || true)
    local -a present=()
    local cask
    while IFS= read -r cask; do
        [[ -z "$cask" ]] && continue
        grep -qx "${cask##*/}" <<< "$installed" && present+=("${cask##*/}")
    done <<< "$managed"
    ((${#present[@]})) || return 0
    local json
    if ! json=$(brew info --cask --json=v2 "${present[@]}" 2>/dev/null); then
        log_warning "brew info --cask failed; skipping cask app heal"
        return 0
    fi
    local appdir="${CASK_APPDIR:-/Applications}" token app
    # shellcheck disable=SC2016  # $t in the yq expression is a yq variable, not shell
    while IFS=$'\t' read -r token app; do
        [[ -z "$token" || -z "$app" ]] && continue
        [[ -e "$appdir/$app" || -e "$HOME/Applications/$app" ]] && continue
        echo "  ! $token: $app missing from $appdir — reinstalling"
        if ! brew reinstall --cask "$token" </dev/null; then
            log_error "Failed to reinstall $token"
            FAILED+=("$token")
        fi
    done < <(yq -r '.casks[] | .token as $t | .artifacts[] | select(tag == "!!map") | .app | select(. != null) | .[] | select(tag == "!!str") | $t + "\t" + .' <<< "$json" 2>/dev/null)
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

    [[ "$PLATFORM" == "Darwin" ]] && heal_missing_cask_apps

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
        local -a upgrade_formulae=()
        local formula
        while IFS= read -r formula; do
            [[ -n "$formula" ]] && upgrade_formulae+=( "$formula" )
        done < <(get_platform_pkgs)
        if [[ "${DOTFILES_DEV:-false}" == "true" ]]; then
            while IFS= read -r formula; do
                [[ -n "$formula" ]] && upgrade_formulae+=( "$formula" )
            done < <(get_platform_pkgs "--dev")
        fi
        if ((${#upgrade_formulae[@]})); then
            brew upgrade --formula "${upgrade_formulae[@]}" </dev/null || log_warning "brew upgrade failed"
        fi
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
# mise itself is the one deliberately-unpinned bootstrap tool. The live
# chezmoi-deployed manifest wins; before first apply, the repo source manifest
# bootstraps chezmoi and the other exact pins.

sync_mise() {
    if ! command -v mise &>/dev/null; then
        if ! command -v brew &>/dev/null; then
            log_error "brew not found — cannot bootstrap mise"
            FAILED+=("mise")
            return 0
        fi
        log_info "Bootstrapping mise..."
        if ! brew install mise; then
            log_error "Failed to install mise"
            FAILED+=("mise")
            return 0
        fi
        hash -r 2>/dev/null || true
    fi

    if ! command -v mise &>/dev/null; then
        log_error "mise unavailable after bootstrap"
        FAILED+=("mise")
        return 0
    fi

    local mise_config
    mise_config="$(mise_config_path)"
    if [[ -z "$mise_config" ]]; then
        log_error "mise config not found: $MISE_CONFIG_FILE or $MISE_BOOTSTRAP_CONFIG_FILE"
        FAILED+=("mise-config")
        return 0
    fi

    log_info "Converging mise-managed tool versions from $mise_config..."
    if ! MISE_GLOBAL_CONFIG_FILE="$mise_config" mise install "$@" </dev/null; then
        log_error "mise install failed"
        FAILED+=("mise-install")
        return 0
    fi

    export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"
    hash -r 2>/dev/null || true
}

########## Cargo

sync_cargo() {
    local cargo_pkgs
    cargo_pkgs=$(yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "cargo") | [.key, (.value.git // ""), (.value.branch // ""), (.value.version // ""), (.value.rev // ""), (.value.gate_unless // "")] | join("|")' "$PACKAGES_FILE" 2>/dev/null)
    [[ -z "$cargo_pkgs" ]] && return 0

    if ! command -v cargo &>/dev/null; then
        log_error "cargo not found after mise convergence — cannot install cargo-source packages"
        FAILED+=("cargo-toolchain")
        return 0
    fi

    log_info "Syncing cargo packages"
    local installed
    installed=$(cargo install --list 2>/dev/null | grep -E '^\S' | cut -d' ' -f1 || true)

    # Pinned packages (version or rev) are installed unconditionally so drift
    # is corrected. Unpinned entries install once and never float in UPGRADE_MODE.
    while IFS='|' read -r name git_url branch version rev gate; do
        [[ -z "$name" ]] && continue

        if [[ -n "$gate" && "${!gate:-false}" == "true" ]]; then
            echo "  Skipping $name (gate_unless $gate=true)"
            continue
        fi

        if [[ -n "$version" || -n "$rev" ]]; then
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


    log_success "Cargo sync complete"
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
    local installed
    installed=$(npm ls -g --json 2>/dev/null | jq -r '.dependencies // {} | keys[]' || true)

    while IFS=$'\t' read -r name pkg version; do
        [[ -z "$name" ]] && continue

        if [[ -n "$version" ]]; then
            echo "  Installing $pkg@$version (pinned)..."
            if ! npm install -g "$pkg@$version" </dev/null; then
                log_error "Failed to install $pkg@$version"
                FAILED+=("$pkg")
            fi
        elif echo "$installed" | grep -qx "$pkg"; then
            echo "  + $name"
        else
            echo "  Installing $pkg..."
            if ! npm install -g "$pkg" </dev/null; then
                log_error "Failed to install $pkg"
                FAILED+=("$pkg")
            fi
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
        local unpinned_names=() n
        for n in "${all_names[@]}"; do
            if ! printf '%s\n' "${pinned_names[@]}" | grep -qxF "$n"; then
                unpinned_names+=("$n")
            fi
        done
        if ((${#unpinned_names[@]})); then
            log_info "Upgrading intentionally unpinned uv tools..."
            uv tool upgrade "${unpinned_names[@]}" </dev/null || log_warning "uv tool upgrade failed"
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

    while IFS=$'\t' read -r name pkg version; do
        [[ -z "$name" ]] && continue

        if [[ -n "$version" ]]; then
            echo "  Installing $pkg --pin $version..."
            if ! gh extension install "$pkg" --pin "$version" --force </dev/null; then
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


    log_success "gh extensions sync complete"
}

########## Native AI-harness CLIs
# claude and codex are mise-managed. Remove stale native/brew copies so mise's
# shim is the only one on PATH. OMP remains on its native installer, but the
# installer is always invoked with OMP_PIN whenever package sync is not cached.


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

    # --binary is required: omp.sh's installer defaults to a bun source build
    # whenever --ref is given, and that build (`bun install -g
    # packages/coding-agent` against the cloned monorepo) trips bun's
    # self-referential-workspace-loop check on the package's own dependency on
    # itself — reproduces even reinstalling an already-working pin, so it's a
    # bun/installer incompatibility, not a bad release. --binary fetches the
    # prebuilt release asset instead, sidestepping bun entirely.
    echo "  Converging omp to $OMP_PIN (native)..."
    if curl -fsSL https://omp.sh/install | sh -s -- --binary --ref "$OMP_PIN"; then
        hash -r 2>/dev/null || true
        log_success "  Converged omp to $OMP_PIN"
    else
        log_error "omp native install failed"
        FAILED+=("omp")
    fi

    log_success "Native harness sync complete"
}
# Claude is invoked by chezmoi later in this sync, so keep its mise binary
# present even when the package declaration cache is valid.
if check_cache; then
    log_success "Package manifests unchanged (cached), syncing Claude"
    heal_missing_cask_apps
    if ((${#FAILED[@]})); then
        log_error "failed to heal ${#FAILED[@]} package(s): ${FAILED[*]}"
        exit 1
    fi
    sync_mise "aqua:anthropics/claude-code@v2.1.219"
    exit 0
fi
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


if [[ "$PLATFORM" == "Darwin" || "$PLATFORM" == "Linux" ]]; then
    sync_brew
fi

failures_before_mise=${#FAILED[@]}
sync_mise
if ((${#FAILED[@]} > failures_before_mise)); then
    if [[ "${PACKAGES_BOOTSTRAP_ONLY:-false}" == "true" ]]; then
        log_error "package bootstrap failed: ${FAILED[*]}"
    else
        echo ""
        log_error "failed to install ${#FAILED[@]} package(s): ${FAILED[*]}"
        log_warning "cache NOT saved due to install failures"
    fi
    exit 1
fi

if [[ "${PACKAGES_BOOTSTRAP_ONLY:-false}" == "true" ]]; then
    if ((${#FAILED[@]})); then
        log_error "package bootstrap failed: ${FAILED[*]}"
        exit 1
    fi
    log_success "Package bootstrap complete"
    exit 0
fi
sync_cargo
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
