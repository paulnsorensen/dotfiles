# shellcheck shell=bash
# bin-doctor.sh — find binaries that bypass the one-install-path contract, and
# run the package managers' own cache cleanups.
#
# The contract: mise (chezmoi/dot_config/mise/config.toml) owns every tool it
# can pin; packages/packages.yaml owns the brew/cask/npm/uv/cargo/gh-extension
# remainder. A binary from any other path is a finding. Two copies of one
# command from two managers is a finding even when the right one wins PATH,
# because the loser silently takes over the day PATH order changes.
#
# Check functions print findings as TSV lines: <category>\t<name>\t<detail>.
# The bin/bin-doctor CLI formats them. Nothing here uninstalls anything.
#
# Functions only — no top-level side effects, so sourcing is safe. Written for
# bash 3.2 (macOS /bin/bash): no associative arrays, no ${var,,}, no mapfile.

# bd_resolve <path> — follow every symlink in <path> (portable stand-in for
# GNU `readlink -f`, which BSD readlink lacks). A relative link target stays
# joined to its link's directory without `..` normalization: callers only
# match path fragments, and skipping `cd -P` keeps a PATH scan fork-light.
bd_resolve() {
    local path="$1" target
    while [[ -L "$path" ]]; do
        target="$(readlink "$path")" || return 1
        if [[ "$target" == /* ]]; then
            path="$target"
        else
            path="${path%/*}/$target"
        fi
    done
    printf '%s\n' "$path"
}

# bd_manager_of <path> — name the manager that owns the command at <path>.
# Classify the unresolved path first: mise shims resolve to the mise binary
# itself (a brew file), and dotfiles wrappers deliberately shadow real tools.
bd_manager_of() {
    local path="$1" resolved cargo_home
    cargo_home="${CARGO_HOME:-$HOME/.cargo}"
    case "$path" in
        "${DOTFILES_DIR:-$HOME/Dev/dotfiles}"/bin/*) echo wrapper; return ;;
        */mise/shims/*) echo mise; return ;;
    esac
    resolved="$(bd_resolve "$path")"
    case "${resolved##*/}" in
        rustup | rustup-init) echo rustup; return ;;
    esac
    case "$resolved" in
        */opt/rustup/* | */Cellar/rustup/*) echo rustup ;;
        "$HOME"/.bun/*) echo bun ;;
        */lib/node_modules/*) echo npm ;;
        */mise/installs/*) echo mise ;;
        */uv/tools/*) echo uv ;;
        */pipx/venvs/*) echo pipx ;;
        */Cellar/* | */Caskroom/* | /opt/homebrew/* | */.linuxbrew/*) echo brew ;;
        "$cargo_home"/bin/*) echo cargo ;;
        "${GOBIN:-$HOME/go/bin}"/*) echo go ;;
        /usr/* | /bin/* | /sbin/* | /System/* | /snap/*) echo system ;;
        "$HOME"/.local/bin/*) echo local ;;
        *) echo other ;;
    esac
}

# bd_path_dirs — the unique, existing directories on PATH, in PATH order.
bd_path_dirs() {
    local dir seen=":"
    local IFS=:
    for dir in $PATH; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        [[ "$seen" == *":$dir:"* ]] && continue
        seen="$seen$dir:"
        printf '%s\n' "$dir"
    done
}

# bd_mise_bin_dirs — mise's active bin dirs, one per line, minus any that
# resolve into $CARGO_HOME/bin. mise's `rust` entry is a symlink there, so
# counting it would claim every `cargo install` binary for mise too.
bd_mise_bin_dirs() {
    local dir cargo_bin
    command -v mise >/dev/null 2>&1 || return 0
    cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
    mise bin-paths 2>/dev/null | while IFS= read -r dir; do
        [[ "$(bd_resolve "$dir")" == "$cargo_bin"* ]] && continue
        [[ "$dir" == "$cargo_bin"* ]] && continue
        printf '%s\n' "$dir"
    done
}

# bd_check_shadows [allow-file] — one `shadow` finding per command that two
# or more managers provide. System copies (/usr/bin and friends) and dotfiles
# wrappers are expected and never count. A mise shim counts as mise only when
# a real mise bin dir holds that command; otherwise it only forwards to
# another manager's copy. The detail lists each manager's first copy as
# manager=path, in PATH order, so the winner comes first.
bd_check_shadows() {
    local allow="${1:-}" dir entry name path manager managers copies current
    local mise_dirs hits
    mise_dirs="$(bd_mise_bin_dirs)"
    hits="$(
        bd_path_dirs | while IFS= read -r dir; do
            case "$dir" in
                (/usr/* | /bin | /sbin | /System/* | /snap/*) continue ;;
                ("${DOTFILES_DIR:-$HOME/Dev/dotfiles}"/bin) continue ;;
            esac
            for entry in "$dir"/*; do
                [[ -f "$entry" && -x "$entry" ]] || continue
                name="${entry##*/}"
                if [[ "$dir" == */mise/shims ]]; then
                    bd__in_dirs "$name" "$mise_dirs" || continue
                fi
                printf '%s\t%s\n' "$name" "$entry"
            done
        done
    )"
    [[ -n "$hits" ]] || return 0
    printf '%s\n' "$hits" | awk -F'\t' '
        { name[NR] = $1; line[NR] = $0; count[$1]++ }
        END { for (i = 1; i <= NR; i++) if (count[name[i]] > 1) print line[i] }
    ' | sort -s -t"$(printf '\t')" -k1,1 | {
        current=""
        managers=""
        copies=""
        while IFS=$'\t' read -r name path; do
            if [[ "$name" != "$current" ]]; then
                bd__emit_shadow "$allow" "$current" "$managers" "$copies"
                current="$name"
                managers=""
                copies=""
            fi
            manager="$(bd_manager_of "$path")"
            case "$manager" in system | wrapper) continue ;; esac
            [[ " $managers " == *" $manager "* ]] && continue
            managers="${managers:+$managers }$manager"
            copies="${copies:+$copies, }$manager=$path"
        done
        bd__emit_shadow "$allow" "$current" "$managers" "$copies"
    }
}

# bd__in_dirs <name> <newline-separated dirs> — succeed when a dir holds an
# executable <name>.
bd__in_dirs() {
    local name="$1" dir
    while IFS= read -r dir; do
        [[ -n "$dir" && -x "$dir/$name" ]] && return 0
    done <<< "$2"
    return 1
}

bd__emit_shadow() {
    local allow="$1" name="$2" managers="$3" copies="$4"
    [[ -n "$name" ]] || return 0
    # shellcheck disable=SC2086  # word-split the space-joined manager list
    set -- $managers
    [[ $# -ge 2 ]] || return 0
    bd_allowed "$allow" shadow "$name" && return 0
    printf 'shadow\t%s\t%s\n' "$name" "$copies"
}

# bd_declared <packages.yaml> <source> — the names packages.yaml declares for
# <source> (brew covers bare strings, `source: brew`, cask, and tap entries).
# Both the key and any `pkg:` value are printed, since npm/uv entries install
# under their package name.
bd_declared() {
    local file="$1" source="$2"
    command -v yq >/dev/null 2>&1 || return 1
    [[ -f "$file" ]] || return 1
    if [[ "$source" == brew ]]; then
        yq -r '.packages[] | select(kind == "scalar")' "$file"
        yq -r '.packages[] | select(kind == "map") | to_entries[0] | select((.value.source // "brew") == "brew" or .value.source == "cask" or .value.source == "tap") | .key' "$file"
    else
        yq -r ".packages[] | select(kind == \"map\") | to_entries[0] | select(.value.source == \"$source\") | (.key, (.value.pkg // \"\"))" "$file" | grep -v '^$'
    fi
}

# bd_allowed <allow-file> <kind> <name> — succeed when the allowlist accepts
# <kind>:<name>. Lines look like `brew:docker  # reason`; <kind> is a manager
# name or `shadow`.
bd_allowed() {
    local file="$1" manager="$2" name="$3"
    [[ -f "$file" ]] || return 1
    sed 's/#.*//' "$file" | tr -d ' \t' | grep -qxF "$manager:$name"
}

# bd__strays <category> <manager> <allow-file> <declared> <installed> — one
# finding per installed name that is neither declared nor allowlisted.
bd__strays() {
    local category="$1" manager="$2" allow="$3" declared="$4" installed="$5" name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$declared" | grep -qxF "$name" && continue
        bd_allowed "$allow" "$manager" "$name" && continue
        printf '%s\t%s\t%s\n' "$category" "$name" "$manager install not declared in packages.yaml"
    done <<< "$installed"
}

# bd_cargo_install_list — `cargo install --list` as TSV: <crate>\t<bin>.
bd_cargo_install_list() {
    command -v cargo >/dev/null 2>&1 || return 0
    cargo install --list 2>/dev/null | awk '
        /^[^ \t]/ { crate = $1; next }
        /^[ \t]+/ { gsub(/^[ \t]+/, ""); print crate "\t" $0 }
    '
}

# bd_check_cargo <packages.yaml> <allow-file> — stray crates, stale install
# metadata (cargo lists a binary that is gone), and untracked files in
# $CARGO_HOME/bin that no crate owns and that are not rustup proxies.
bd_check_cargo() {
    local file="$1" allow="$2" bin_dir list declared crate bin entry name
    command -v cargo >/dev/null 2>&1 || return 0
    bin_dir="${CARGO_HOME:-$HOME/.cargo}/bin"
    list="$(bd_cargo_install_list)"
    declared="$(bd_declared "$file" cargo || true)"
    bd__strays cargo-stray cargo "$allow" "$declared" "$(printf '%s\n' "$list" | cut -f1 | sort -u)"
    while IFS=$'\t' read -r crate bin; do
        [[ -n "$crate" ]] || continue
        [[ -e "$bin_dir/$bin" ]] && continue
        printf 'cargo-stale\t%s\t%s\n' "$crate" "cargo lists $bin but $bin_dir/$bin is missing"
    done <<< "$list"
    [[ -d "$bin_dir" ]] || return 0
    for entry in "$bin_dir"/*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name="$(basename "$entry")"
        printf '%s\n' "$list" | cut -f2 | grep -qxF "$name" && continue
        [[ "$(bd_manager_of "$entry")" == rustup ]] && continue
        bd_allowed "$allow" cargo "$name" && continue
        printf 'cargo-untracked\t%s\t%s\n' "$name" "$entry is owned by no installed crate"
    done
}

# bd_check_uv <packages.yaml> <allow-file> — uv tools not in packages.yaml.
bd_check_uv() {
    local installed
    command -v uv >/dev/null 2>&1 || return 0
    installed="$(uv tool list 2>/dev/null | awk '/^[^ \t-]/ { print $1 }')"
    bd__strays uv-stray uv "$2" "$(bd_declared "$1" uv || true)" "$installed"
}

# bd_check_npm <packages.yaml> <allow-file> — global npm packages (active
# prefix only) not in packages.yaml. npm and corepack ship with node.
bd_check_npm() {
    local installed
    command -v npm >/dev/null 2>&1 || return 0
    installed="$(npm ls -g --depth=0 --parseable 2>/dev/null |
        sed -n 's|.*/node_modules/||p' | grep -vxE 'npm|corepack' || true)"
    bd__strays npm-stray npm "$2" "$(bd_declared "$1" npm || true)" "$installed"
}

# bd_check_brew <packages.yaml> <allow-file> — brew leaves not declared, and
# the `rust` formula installed beside rustup (two toolchains, one PATH).
bd_check_brew() {
    local leaves declared name short
    command -v brew >/dev/null 2>&1 || return 0
    leaves="$(brew leaves 2>/dev/null || true)"
    declared="$(bd_declared "$1" brew || true)"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        short="${name##*/}"
        printf '%s\n' "$declared" | grep -qxF -e "$name" -e "$short" && continue
        bd_allowed "$2" brew "$short" && continue
        printf 'brew-stray\t%s\t%s\n' "$name" "brew leaf not declared in packages.yaml or the allowlist"
    done <<< "$leaves"
    if printf '%s\n' "$leaves" | grep -qxF rust && brew list --formula rustup >/dev/null 2>&1; then
        printf 'conflict\t%s\t%s\n' rust "brew formula rust shadows the rustup toolchains that mise pins"
    fi
}

# bd_check_unmanaged — managers packages.yaml has no source for. Every
# binary they installed is outside the contract.
bd_check_unmanaged() {
    local go_bin entry name
    if command -v pipx >/dev/null 2>&1; then
        pipx list --short 2>/dev/null | while read -r name _; do
            [[ -n "$name" ]] && printf 'unmanaged\t%s\t%s\n' "$name" "pipx install; packages.yaml has no pipx source (use source: uv)"
        done
    fi
    go_bin="${GOBIN:-$HOME/go/bin}"
    if [[ -d "$go_bin" ]]; then
        for entry in "$go_bin"/*; do
            [[ -f "$entry" ]] || continue
            printf 'unmanaged\t%s\t%s\n' "$(basename "$entry")" "go install in $go_bin; packages.yaml has no go source"
        done
    fi
    if [[ -d "$HOME/.bun/bin" ]]; then
        for entry in "$HOME/.bun/bin"/*; do
            name="$(basename "$entry")"
            case "$name" in bun | bunx | '*') continue ;; esac
            printf 'unmanaged\t%s\t%s\n' "$name" "bun global install; packages.yaml has no bun source"
        done
    fi
}

# bd_clean_steps — the cache cleanups to run on this machine, one per line as
# <manager>\t<command>. Each command only deletes data its manager can
# re-download or rebuild, runs without a prompt, and leaves installed
# versions alone. Managers that are not installed are skipped.
bd_clean_steps() {
    if command -v cargo >/dev/null 2>&1 && cargo cache --version >/dev/null 2>&1; then
        printf 'cargo\tcargo cache --autoclean\n'
    fi
    if command -v brew >/dev/null 2>&1; then
        printf 'brew\tbrew cleanup --prune=30\n'
    fi
    if command -v mise >/dev/null 2>&1; then
        printf 'mise\tmise cache prune\n'
    fi
    command -v uv >/dev/null 2>&1 && printf 'uv\tuv cache prune\n'
    command -v npm >/dev/null 2>&1 && printf 'npm\tnpm cache verify\n'
    command -v pnpm >/dev/null 2>&1 && printf 'pnpm\tpnpm store prune\n'
    command -v bun >/dev/null 2>&1 && printf 'bun\tbun pm cache rm\n'
    command -v go >/dev/null 2>&1 && printf 'go\tgo clean -cache -testcache\n'
    return 0
}

# bd_outdated_steps — read-only update reports, one per line as
# <manager>\t<command>. Pinned surfaces (mise, packages.yaml) still move only
# through Renovate PRs; these reports show what the pins lag behind.
bd_outdated_steps() {
    command -v mise >/dev/null 2>&1 && printf 'mise\tmise outdated\n'
    command -v brew >/dev/null 2>&1 && printf 'brew\tbrew outdated\n'
    if command -v cargo >/dev/null 2>&1 && cargo install-update --version >/dev/null 2>&1; then
        printf 'cargo\tcargo install-update --list\n'
    fi
    command -v uv >/dev/null 2>&1 && printf 'uv\tuv tool list --outdated\n'
    command -v npm >/dev/null 2>&1 && printf 'npm\tnpm outdated -g\n'
    return 0
}

# bd_bootstrap_path — prepend every manager's bin dir that exists, so later
# entries win: mise shims first, then rustup proxies ahead of brew. launchd
# and systemd start jobs with a bare PATH and never read shell rc files.
# BIN_DOCTOR_KEEP_PATH=1 keeps PATH as is (tests use it).
bd_bootstrap_path() {
    local dir
    [[ "${BIN_DOCTOR_KEEP_PATH:-}" == 1 ]] && return 0
    for dir in \
        "$HOME/.local/bin" \
        "${CARGO_HOME:-$HOME/.cargo}/bin" \
        /home/linuxbrew/.linuxbrew/bin \
        /home/linuxbrew/.linuxbrew/opt/rustup/bin \
        "$HOME/.linuxbrew/bin" \
        "$HOME/.linuxbrew/opt/rustup/bin" \
        /usr/local/bin \
        /opt/homebrew/bin \
        /opt/homebrew/opt/rustup/bin \
        "${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"; do
        [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]] && PATH="$dir:$PATH"
    done
    export PATH
}
