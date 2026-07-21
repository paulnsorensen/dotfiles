# Rectangle Pro sync — idempotence via hash stamp

`rectangle/.sync` runs unconditionally on every `dots sync` (like every dir `.sync`). Before 2026-07-20 it always rewrote the shortcut defaults, `killall cfprefsd`, and hard-restarted Rectangle Pro (`pkill -9` + `open`) — so every sync (i.e. every commit, per repo convention) SIGKILLed the app. The user experienced this as Rectangle Pro "continually crashing".

## Why diagnosis was tricky

SIGKILL produces **no crash report** — zero `Rectangle Pro-*.ips` under `~/Library/Logs/DiagnosticReports/` despite constant "crashes". Absence of crash reports for a repeatedly-dying app is the signature of an external `kill -9`, not an app bug.

## The fix

`rectangle_sync` stamps a SHA-256 of the desired config (shortcut table + the three QoL defaults) into `defaults write <bundle> dotfilesKeymapHash`. On later runs a matching stamp skips all writes, the `cfprefsd` kill, and the restart. Restart only fires when the keymap actually changed.

Deliberate choice: hash stamp, **not** live `defaults read` comparison of shortcut leaves — float-vs-int number printing makes text comparison of leaf values fragile (could mis-compare in either direction: perpetual restarts or never reapplying).

## Gotchas

- Don't delete the `dotfilesKeymapHash` key from `com.knollsoft.Hookshot` — the next sync would kill/restart the app once to re-stamp.
- The stamp write must land **before** `killall cfprefsd` (see comment in `rectangle/lib.sh`).
- `bash .sync` from inside `rectangle/` fails (`BASH_SOURCE` has no dir component to strip) — invoke by full path, as the orchestrator does.

Related: [[operations/sync-and-chezmoi]]
