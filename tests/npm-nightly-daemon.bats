#!/usr/bin/env bats
# The daemon keeps its loaded build after a package replacement.
# These cases preserve stopped state and keep restart failures nonfatal.
# On 2026-11-14, build 321 used 177% CPU and 2.5 GB RSS after build 345 installed the memory fixes.

bats_require_minimum_version 1.5.0

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
  source "$DOTFILES_DIR/bin/lib/npm-nightly.sh"
  SCAN=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/npmdaemon.XXXXXX")" && pwd)
}

teardown() {
  [[ -n "${SCAN:-}" ]] || return 0
  rm -rf "$SCAN"
}

stub_hallouminate() {
  local daemon_status="$1" restart_rc="${2:-0}" status_rc="${3:-0}"
  local bin_dir="$SCAN/hallouminate-bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/hallouminate" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SCAN/hallouminate.log"
case "\$1 \$2" in
  "daemon status")
    [[ $status_rc -eq 0 ]] || echo "status probe failed" >&2
    printf '%s\n' "$daemon_status"
    exit $status_rc ;;
  "daemon restart")
    [[ $restart_rc -eq 0 ]] || echo "restart refused" >&2
    exit $restart_rc ;;
esac
exit 0
EOF
  chmod +x "$bin_dir/hallouminate"
  echo "$bin_dir"
}

stub_npm_prefix() {
  local prefix="$1" prefix_rc="${2:-0}" bin_dir="$SCAN/npm-bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/npm" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "prefix -g" ]] || exit 9
[[ $prefix_rc -eq 0 ]] || echo "prefix lookup failed" >&2
printf '%s\n' "$prefix"
exit $prefix_rc
EOF
  chmod +x "$bin_dir/npm"
  echo "$bin_dir"
}

@test "restarts a running hallouminate daemon" {
  local bin_dir
  bin_dir=$(stub_hallouminate running)

  PATH="$bin_dir:/usr/bin:/bin" run npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  [ "$(cat "$SCAN/hallouminate.log")" = $'daemon status\ndaemon restart' ]
}

@test "does not start a hallouminate daemon when none runs" {
  local bin_dir
  bin_dir=$(stub_hallouminate "not running")

  PATH="$bin_dir:/usr/bin:/bin" run npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  [ "$(cat "$SCAN/hallouminate.log")" = "daemon status" ]
}

@test "warns with the quoted selected command when daemon restart fails" {
  local bin_dir selected quoted
  bin_dir=$(stub_hallouminate running 1)
  selected="$SCAN/active prefix \$cash/hallouminate"
  mkdir -p "$(dirname "$selected")"
  cp "$bin_dir/hallouminate" "$selected"
  printf -v quoted '%q' "$selected"

  PATH="/usr/bin:/bin" run --separate-stderr npm_nightly_restart_hallouminate_daemon "$selected"
  [ "$status" -eq 0 ]
  [ "$(cat "$SCAN/hallouminate.log")" = $'daemon status\ndaemon restart' ]
  [[ "$stderr" == *"restart refused"* ]]
  [[ "$stderr" == *"Run $quoted daemon restart"* ]]
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

@test "warns without restarting when the status probe fails with running output" {
  local bin_dir
  bin_dir=$(stub_hallouminate running 0 1)

  PATH="$bin_dir:/usr/bin:/bin" run --separate-stderr npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"status probe failed"* ]]
  [[ "$stderr" == *"Cannot read hallouminate daemon status"* ]]
  [ "$(cat "$SCAN/hallouminate.log")" = "daemon status" ]
}

@test "checks the first status line when the daemon reports extra details" {
  local bin_dir
  bin_dir=$(stub_hallouminate $'running\nPID: 123')

  PATH="$bin_dir:/usr/bin:/bin" run npm_nightly_restart_hallouminate_daemon
  [ "$status" -eq 0 ]
  [ "$(cat "$SCAN/hallouminate.log")" = $'daemon status\ndaemon restart' ]
}

@test "resolves the installed daemon executable from the active npm prefix" {
  local bin_dir npm_bin prefix="$SCAN/active prefix"
  bin_dir=$(stub_hallouminate running)
  mkdir -p "$prefix/bin"
  cp "$bin_dir/hallouminate" "$prefix/bin/hallouminate"
  npm_bin=$(stub_npm_prefix "$prefix")

  PATH="$npm_bin:/usr/bin:/bin" run npm_nightly_restart_installed_hallouminate_daemon
  [ "$status" -eq 0 ]
  [ "$(cat "$SCAN/hallouminate.log")" = $'daemon status\ndaemon restart' ]
}

@test "warns without failing sync when npm prefix resolution fails" {
  local npm_bin bin_dir
  bin_dir=$(stub_hallouminate running)
  npm_bin=$(stub_npm_prefix "$SCAN/untrusted-prefix" 1)

  PATH="$npm_bin:$bin_dir:/usr/bin:/bin" run --separate-stderr npm_nightly_restart_installed_hallouminate_daemon
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"prefix lookup failed"* ]]
  [[ "$stderr" == *"Cannot resolve the active npm prefix"* ]]
  [[ "$stderr" == *"Run 'npm prefix -g'"* ]]
  [ ! -e "$SCAN/hallouminate.log" ]
}

@test "warns without falling back to PATH when npm returns an empty prefix" {
  local npm_bin bin_dir
  bin_dir=$(stub_hallouminate running)
  npm_bin=$(stub_npm_prefix "")

  PATH="$npm_bin:$bin_dir:/usr/bin:/bin" run --separate-stderr npm_nightly_restart_installed_hallouminate_daemon
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Cannot resolve the active npm prefix"* ]]
  [[ "$stderr" == *"Run 'npm prefix -g'"* ]]
  [ ! -e "$SCAN/hallouminate.log" ]
}
