#!/usr/bin/env bats
# Tests for bin/lib/npm-nightly.sh — the shadow prune shared by the tilth and
# hallouminate nightly installers.
#
# WHY these matter: npm_nightly_prune_shadows runs `npm rm -g` against a prefix
# the active npm does not own. Two properties have to hold every time. It must
# remove the stale copy (the warning it replaced was ignored for 34 nightlies,
# pinning the hallouminate MCP to 0.7.0). And it must never remove anything
# else — not the active prefix's own copy, not an unrelated package that
# happens to expose the same bin, and nothing at all when the active prefix
# cannot be trusted as a reference point.

bats_require_minimum_version 1.5.0

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
  source "$DOTFILES_DIR/bin/lib/npm-nightly.sh"
  SCAN=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/npmnightly.XXXXXX")" && pwd)
  PKG="@paulnsorensen/tilth-nightly"
  RM_LOG="$SCAN/rm.log"
  # The prune also scans mise's node installs. Point it at a sandbox so no
  # test can reach the real ~/.local/share/mise.
  export MISE_DATA_DIR="$SCAN/mise"
  MISE_NODE="$MISE_DATA_DIR/installs/node"
}

teardown() {
  [[ -n "${SCAN:-}" ]] || return 0
  rm -rf "$SCAN"
}

# An npm global prefix holding <pkg>, exposing its bin as <prefix>/bin/<bin>.
make_prefix() {
  local prefix="$1" pkg="$2" bin_name="${3:-tilth}"
  mkdir -p "$prefix/lib/node_modules/$pkg/bin" "$prefix/bin"
  printf '#!/usr/bin/env bash\n' > "$prefix/lib/node_modules/$pkg/bin/$bin_name"
  chmod +x "$prefix/lib/node_modules/$pkg/bin/$bin_name"
  ln -s "../lib/node_modules/$pkg/bin/$bin_name" "$prefix/bin/$bin_name"
}

# An npm in <prefix>/bin that logs its args and deletes the package tree, so a
# test can assert both that the prune fired and what it targeted.
give_prefix_an_npm() {
  local prefix="$1"
  mkdir -p "$prefix/bin"
  cat > "$prefix/bin/npm" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RM_LOG"
[[ "\$1" == "rm" && "\$2" == "-g" && "\$3" == "--prefix" && "\$4" == "$prefix" ]] || exit 1
rm -rf "\$4/lib/node_modules/\$5" "\$4/bin/tilth"
EOF
  chmod +x "$prefix/bin/npm"
}

# The active npm: only `prefix -g` is ever asked of it by the prune.
stub_active_npm() {
  local prefix="$1" bin_dir="$SCAN/active-npm-bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/npm" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "prefix -g" ]] && { echo "$prefix"; exit 0; }
exit 1
EOF
  chmod +x "$bin_dir/npm"
  echo "$bin_dir"
}

@test "removes a nightly copy held by a second npm prefix" {
  local active="$SCAN/active" second="$SCAN/second" npm_bin
  mkdir -p "$active"
  make_prefix "$second" "$PKG"
  give_prefix_an_npm "$second"
  npm_bin=$(stub_active_npm "$active")

  PATH="$npm_bin:$second/bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed the shadow copy"* ]]
  # The prune must call that prefix's own npm, not the active one.
  grep -qx "rm -g --prefix $second $PKG" "$RM_LOG"
  [ ! -e "$second/lib/node_modules/$PKG" ]
}

@test "real npm removes only the inactive prefix despite inherited active prefix" {
  local active="$SCAN/active" second="$SCAN/second" npm_bin node_bin
  node_bin=$(dirname "$(MISE_DATA_DIR='' node -p 'process.execPath')")
  mkdir -p "$SCAN/runtime-bin"
  ln -s "$node_bin/node" "$SCAN/runtime-bin/node"
  make_prefix "$active" "$PKG"
  make_prefix "$second" "$PKG"
  printf '{"name":"%s","version":"1.0.0","bin":{"tilth":"bin/tilth"}}\n' "$PKG" > "$second/lib/node_modules/$PKG/package.json"
  ln -s "$node_bin/npm" "$second/bin/npm"
  ln -s "$node_bin/node" "$second/bin/node"
  ln -s "$node_bin/../lib/node_modules/npm" "$second/lib/node_modules/npm"
  npm_bin=$(stub_active_npm "$active")

  PATH="$npm_bin:$second/bin:$SCAN/runtime-bin:/usr/bin:/bin" NPM_CONFIG_PREFIX="$active" \
    NPM_CONFIG_USERCONFIG=/dev/null NPM_CONFIG_GLOBALCONFIG="$SCAN/global.npmrc" \
    NPM_CONFIG_CACHE="$SCAN/cache" NPM_CONFIG_OFFLINE=true \
    NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false NPM_CONFIG_IGNORE_SCRIPTS=true \
    run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [ ! -e "$second/lib/node_modules/$PKG" ]
  [ -e "$active/lib/node_modules/$PKG" ]
}

@test "leaves the active prefix's own copy alone" {
  local active="$SCAN/active" npm_bin
  make_prefix "$active" "$PKG"
  give_prefix_an_npm "$active"
  npm_bin=$(stub_active_npm "$active")

  PATH="$npm_bin:$active/bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [[ "$output" != *"removed the shadow copy"* ]]
  [ ! -e "$RM_LOG" ]
  [ -e "$active/lib/node_modules/$PKG" ]
}

@test "leaves an unrelated package that exposes the same bin alone" {
  local active="$SCAN/active" upstream="$SCAN/upstream" npm_bin
  mkdir -p "$active"
  # Upstream public `tilth` — same bin name, different package tree.
  make_prefix "$upstream" "tilth"
  give_prefix_an_npm "$upstream"
  npm_bin=$(stub_active_npm "$active")

  PATH="$npm_bin:$upstream/bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [ ! -e "$RM_LOG" ]
  [ -e "$upstream/lib/node_modules/tilth" ]
}

@test "prunes nothing when the active prefix is not a real directory" {
  local second="$SCAN/second" npm_bin
  make_prefix "$second" "$PKG"
  give_prefix_an_npm "$second"
  # A stubbed or half-provisioned npm can report a prefix that does not exist.
  # Every other prefix would look like a shadow, so the prune must stand down.
  npm_bin=$(stub_active_npm "$SCAN/nonexistent-prefix")

  PATH="$npm_bin:$second/bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a directory"* ]]
  [ ! -e "$RM_LOG" ]
  [ -e "$second/lib/node_modules/$PKG" ]
}

@test "warns without removing when the shadow prefix has no usable npm" {
  local active="$SCAN/active" second="$SCAN/second" npm_bin
  mkdir -p "$active"
  make_prefix "$second" "$PKG"   # no npm in that prefix
  npm_bin=$(stub_active_npm "$active")

  PATH="$npm_bin:$second/bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not executable"* ]]
  [[ "$output" == *"remove that copy by hand"* ]]
  [ -e "$second/lib/node_modules/$PKG" ]
}

@test "prunes a prefix once when it exposes the bin twice on PATH" {
  local active="$SCAN/active" second="$SCAN/second" npm_bin
  mkdir -p "$active"
  make_prefix "$second" "$PKG"
  give_prefix_an_npm "$second"
  # A shim dir pointing at the same install — the real mise layout.
  mkdir -p "$second/shims"
  ln -s "../lib/node_modules/$PKG/bin/tilth" "$second/shims/tilth"
  npm_bin=$(stub_active_npm "$active")

  PATH="$npm_bin:$second/bin:$second/shims:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$RM_LOG")" -eq 1 ]
}

@test "keeps going when a removal fails" {
  local active="$SCAN/active" second="$SCAN/second" npm_bin
  mkdir -p "$active"
  make_prefix "$second" "$PKG"
  mkdir -p "$second/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$second/bin/npm"
  chmod +x "$second/bin/npm"
  npm_bin=$(stub_active_npm "$active")

  # A run_after installer must not abort the rest of `dots sync` over a shadow
  # it could not clear; the next sync retries.
  PATH="$npm_bin:$second/bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed"* ]]
  [[ "$output" == *"remove that copy by hand"* ]]
}

# ── npm_nightly_restart_hallouminate_daemon ───────────────────────────────
#
# WHY: the hallouminate daemon is a long-lived singleton.
# A nightly install does not replace the build that the daemon runs.
# On 2026-11-14, build 321 used 177% CPU and 2.5 GB RSS after build 345 installed the memory fixes.
# The helper restarts only a running daemon and never fails the sync.

# A stub `hallouminate` in its own bin dir. It logs its arguments, prints
# <status> for `daemon status`, and exits <restart_rc> for `daemon restart`.
stub_hallouminate() {
  local status="$1" restart_rc="${2:-0}" bin_dir="$SCAN/hallouminate-bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/hallouminate" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SCAN/hallouminate.log"
case "\$1 \$2" in
  "daemon status") echo "$status"; exit 0 ;;
  "daemon restart") exit $restart_rc ;;
esac
exit 0
EOF
  chmod +x "$bin_dir/hallouminate"
  echo "$bin_dir"
}

@test "restarts a running hallouminate daemon" {
  local bin_dir
  bin_dir=$(stub_hallouminate running)

  PATH="$bin_dir:/usr/bin:/bin" run npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  grep -qx "daemon restart" "$SCAN/hallouminate.log"
}

@test "does not start a hallouminate daemon when none runs" {
  local bin_dir
  bin_dir=$(stub_hallouminate "not running")

  PATH="$bin_dir:/usr/bin:/bin" run npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  # The status probe is the only call: no restart and no start.
  [ "$(cat "$SCAN/hallouminate.log")" = "daemon status" ]
}

@test "warns but succeeds when the hallouminate daemon restart fails" {
  local bin_dir
  bin_dir=$(stub_hallouminate running 1)

  PATH="$bin_dir:/usr/bin:/bin" run --separate-stderr npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  grep -qx "daemon restart" "$SCAN/hallouminate.log"
  [[ "$stderr" == *"hallouminate daemon restart"* ]]
}

@test "does nothing when hallouminate is not on PATH" {
  local empty_bin="$SCAN/empty-bin"
  mkdir -p "$empty_bin"

  PATH="$empty_bin" run npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does not use a PATH shadow when the selected hallouminate binary is missing" {
  local bin_dir
  bin_dir=$(stub_hallouminate running)

  PATH="$bin_dir:/usr/bin:/bin" run npm_nightly_restart_hallouminate_daemon "$SCAN/missing/hallouminate"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$SCAN/hallouminate.log" ]
}

@test "uses a selected hallouminate binary in a path with spaces" {
  local bin_dir selected
  bin_dir=$(stub_hallouminate running)
  mkdir -p "$SCAN/active prefix/bin"
  selected="$SCAN/active prefix/bin/hallouminate"
  cp "$bin_dir/hallouminate" "$selected"

  PATH="/usr/bin:/bin" run npm_nightly_restart_hallouminate_daemon "$selected"
  [ "$status" -eq 0 ]
  [ "$(cat "$SCAN/hallouminate.log")" = $'daemon status\ndaemon restart' ]
}

# 2026-11-14: mise moved node 26.13.0 -> 26.13.1. The 26.13.0 prefix kept an old
# nightly that no longer sat on PATH, so the PATH scan never saw it, yet an older
# session still ran it and restarted the daemon from that build.
@test "removes a nightly copy from a non-active mise node prefix" {
  local old="$MISE_NODE/26.13.0" active="$MISE_NODE/26.13.1" npm_bin
  make_prefix "$old" "$PKG"
  give_prefix_an_npm "$old"
  make_prefix "$active" "$PKG"
  give_prefix_an_npm "$active"
  npm_bin=$(stub_active_npm "$active")

  # The old prefix is off PATH, as it is after a mise node switch.
  PATH="$npm_bin:$active/bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed the shadow copy"* ]]
  # Each fake npm deletes only its own prefix, so this proves the old
  # prefix's npm ran and the active one's did not.
  [ "$(grep -c . "$RM_LOG")" -eq 1 ]
  grep -qx "rm -g --prefix $old $PKG" "$RM_LOG"
  [ ! -e "$old/lib/node_modules/$PKG" ]
  [ -e "$active/lib/node_modules/$PKG" ]
}

@test "leaves the active mise prefix alone when a partial-version link points at it" {
  local active="$MISE_NODE/26.13.1" npm_bin
  make_prefix "$active" "$PKG"
  give_prefix_an_npm "$active"
  # mise links partial versions to the full install (node/26 -> 26.13.1).
  ln -s 26.13.1 "$MISE_NODE/26"
  npm_bin=$(stub_active_npm "$MISE_NODE/26")

  PATH="$npm_bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [ ! -e "$RM_LOG" ]
  [ -e "$active/lib/node_modules/$PKG" ]
}

@test "leaves a non-mise prefix that is not on PATH alone" {
  local active="$MISE_NODE/26.13.1" other="$SCAN/other" npm_bin
  mkdir -p "$active"
  make_prefix "$other" "$PKG"
  give_prefix_an_npm "$other"
  npm_bin=$(stub_active_npm "$active")

  PATH="$npm_bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [ ! -e "$RM_LOG" ]
  [ -e "$other/lib/node_modules/$PKG" ]
}

@test "prunes no mise prefix when the active prefix is not a real directory" {
  local old="$MISE_NODE/26.13.0" npm_bin
  make_prefix "$old" "$PKG"
  give_prefix_an_npm "$old"
  npm_bin=$(stub_active_npm "$SCAN/nonexistent-prefix")

  PATH="$npm_bin:/usr/bin:/bin" run npm_nightly_prune_shadows "$PKG" tilth
  [ "$status" -eq 0 ]
  [ ! -e "$RM_LOG" ]
  [ -e "$old/lib/node_modules/$PKG" ]
}
