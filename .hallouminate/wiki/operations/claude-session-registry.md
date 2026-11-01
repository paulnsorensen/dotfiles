# Claude session registry and cc-salvage

`bin/cc-salvage` (`bin/lib/cc-salvage.sh`) reopens dead Claude sessions in tmux. It reads the Claude session registry, which Claude owns. This page records the registry facts and launch gotchas that the tool depends on (PR #1411, 2026-10-21).

## Registry facts

- Claude writes one record per process: `~/.claude/sessions/<pid>.json`. Fields that cc-salvage reads: `pid`, `procStart`, `sessionId`, `cwd`, `name`, `entrypoint`, `kind`, `bridgeSessionId`.
- Claude removes its own record on a clean exit. A record that stays after its process ends marks a dead session.
- On Linux, `procStart` is field 22 of `/proc/<pid>/stat`.
- On macOS, `procStart` is the output of `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`. `ps` pads the output, and `%e` pads single-digit days, so compare with whitespace squeezed.
- Without `LC_ALL=C`, a non-English locale prints other day and month names. Every live session then looks dead, and a resume adds a second writer.
- Each record has a `<pid>.<hash>.key` sidecar. cc-salvage does not touch it.
- `sdk-cli` records with a `bridgeSessionId` are Remote Control spawns. Other `sdk-cli` records are headless runs.

## Why liveness compares procStart

A reboot can give an old pid to a new process. `kill -0` alone then reports a dead session as live, and cc-salvage skips it without a message. The start-time compare rejects the reused pid.

## Archive after resume

After `claude --resume` exits 0, `salvage_archive_record` moves every dead record of that session to `~/.claude/sessions/salvaged/<pid>.<sessionId>.<epoch>.json`. Without the move, the resumed session refreshes the transcript mtime, and the next run offers the session again. A live record never moves. The unique name matters: BSD `mv -n` exits 0 when it skips, so a name collision would leave the record in place.

Open follow-up: keep this state in a cc-salvage file instead of inside Claude's directory.

## tmux launch gotchas

- `tmux new-window -c` and `-n` expand `#` formats (tmux 3.7c). A cwd with `#S` opens the pane in `$HOME`. Pass `${cwd//#/##}`. `#(cmd)` does not run in these options.
- `new-window` takes its environment from the tmux server, not from the caller. `DOTFILES_DIR` is absent in the window, so launch through `bin/dotsclaude`, which finds its clone and exports it.
- Use `env CLAUDE_BIN=claude bin/dotsclaude`, so the `bin/claude` session guard can apply.
- On crabbot, the guard does not apply to salvage windows. In their PATH, the mise install directory and `mise/shims` come before `~/dotfiles/bin`, so `claude` runs the real binary (checked 2026-10-21).
- A tmux session name with `:` or `.` breaks `-t` targets, so `--session` rejects both.

## Remote Control on resume

- cc-salvage appends `--remote-control` as the last argument. The flag takes an optional name, so a later argument would become the name.
- With `--resume`, the flag first tries to reattach the earlier cloud session. One window reported "Couldn't reconnect to your Remote Control session".
- `/remote-control` typed in a resumed session reattached the earlier bridge id for some sessions. For other sessions, it created a new one.
- On 2026-10-21, six sessions connected. Every later attempt failed with "Session creation failed", also in a fresh session. The debug log shows only `[code-session] Session create request failed:`. The cause is not known; a cap on concurrent Remote Control sessions is the likely cause.

## Related gotcha: git auto maintenance in test temp repos

Every `git commit` starts a detached `git maintenance run --auto`. It creates `objects/maintenance.lock` while a test deletes its temp repo, and cleanup fails with `Directory not empty: 'objects'`. Set `maintenance.auto false` in temp test repos (PR #1421, `tests/harness_climb/support.py`).
