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

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
  source "$DOTFILES_DIR/bin/lib/npm-nightly.sh"
  SCAN=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/npmnightly.XXXXXX")" && pwd)
  PKG="@paulnsorensen/tilth-nightly"
  RM_LOG="$SCAN/rm.log"
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
[[ "\$1" == "rm" ]] && rm -rf "$prefix/lib/node_modules/\$3" "$prefix/bin/tilth"
exit 0
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
  grep -qx "rm -g $PKG" "$RM_LOG"
  [ ! -e "$second/lib/node_modules/$PKG" ]
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
