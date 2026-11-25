# shellcheck shell=bash
# agy-apparmor.sh — install the AppArmor profile that lets the Antigravity CLI
# (agy) terminal sandbox create user namespaces on Ubuntu-style hosts.
#
# Without the profile, agy logs "auto mode is unavailable because the terminal
# sandbox is unavailable" and asks before most commands.
# Sourcing sets no shell options. Test overrides:
#   AGY_APPARMOR_DIR     profile directory (default /etc/apparmor.d)
#   AGY_APPARMOR_SUDO    privilege command (default sudo; empty runs directly)
#   AGY_APPARMOR_SYSCTL  restriction flag file under /proc/sys

_agy_apparmor_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGY_APPARMOR_TEMPLATE="${_agy_apparmor_lib_dir%/bin/lib}/services/apparmor/antigravity"
unset _agy_apparmor_lib_dir

# agy_apparmor_binary_glob — print the path glob of every mise-installed agy.
agy_apparmor_binary_glob() {
    local data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
    printf '%s/installs/aqua-google-antigravity-antigravity-cli/*/antigravity\n' "$data"
}

# agy_apparmor_render — print the profile for the current user.
agy_apparmor_render() {
    local glob
    glob=$(agy_apparmor_binary_glob)
    if [[ ! "$glob" =~ ^/[A-Za-z0-9._/*-]+$ ]]; then
        echo "agy-apparmor: unsafe binary path: $glob" >&2
        return 1
    fi
    sed "s|__AGY_BINARY_GLOB__|$glob|" "$AGY_APPARMOR_TEMPLATE"
}

# agy_apparmor_needed — succeed when the kernel restricts unprivileged userns.
agy_apparmor_needed() {
    local flag="${AGY_APPARMOR_SYSCTL:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
    [[ -r "$flag" && "$(<"$flag")" == 1 ]]
}

# agy_apparmor_install — install and load the profile when the host needs it.
agy_apparmor_install() {
    local dir="${AGY_APPARMOR_DIR:-/etc/apparmor.d}" priv="${AGY_APPARMOR_SUDO-sudo}"
    local target="$dir/antigravity" rendered tmp
    local -a as_root=()
    [[ -n "$priv" ]] && as_root=("$priv")
    if ! agy_apparmor_needed; then
        echo "agy-apparmor: user namespaces are not restricted; no profile needed"
        return 0
    fi
    rendered=$(agy_apparmor_render) || return 1
    if [[ -f "$target" && "$(<"$target")" == "$rendered" ]]; then
        echo "agy-apparmor: $target is current"
        return 0
    fi
    tmp=$(mktemp) || return 1
    printf '%s\n' "$rendered" > "$tmp"
    if ! ${as_root[@]+"${as_root[@]}"} install -m 0644 "$tmp" "$target" \
        || ! ${as_root[@]+"${as_root[@]}"} apparmor_parser -r "$target"; then
        rm -f "$tmp"
        echo "agy-apparmor: could not install or load $target" >&2
        return 1
    fi
    rm -f "$tmp"
    echo "agy-apparmor: loaded $target; restart agy to get auto mode"
}
