# agent-tty Command Cookbook for tui-verify

Concrete command shapes for the capture matrix. Check the installed agent-tty
and Node versions before use.

## Session lifecycle

```bash
HOME_DIR="$(mktemp -d)"
SID=$(agent-tty --home "$HOME_DIR" create --json --cols 80 --rows 24 --shell /bin/zsh | jq -r '.result.sessionId')
```

Positional args after `--` become a COMMAND, not shell args — do not pass
shell flags like `-il` there; it kills the session. Use `--shell` instead.

## Launch + wait for readiness

```bash
agent-tty --home "$HOME_DIR" run "$SID" '<launch-command>' --no-wait --json
agent-tty --home "$HOME_DIR" wait "$SID" --screen-stable-ms 1000 --timeout 20000 --json
```

The flag is `--timeout`, not `--timeout-ms`. `run` does not return the child's
exit status — don't rely on it for pass/fail; use `wait --text`/`--regex` on
an observable output token instead.

## Driving a state transition with batch

```bash
agent-tty --home "$HOME_DIR" batch "$SID" '[
  { "sendKeys": ["slash"] },
  { "wait": { "text": "Search:" } },
  { "type": "query-that-has-results", "noWait": true },
  { "wait": { "screenStableMs": 500 } }
]' --json
```

Each `wait` step observes only screen state produced after the preceding
input step — it cannot race ahead and match a stale screen.

## Capture

```bash
agent-tty --home "$HOME_DIR" snapshot "$SID" --format text --json | jq -r '.result.text'
PNG=$(agent-tty --home "$HOME_DIR" screenshot "$SID" --json | jq -r '.result.artifactPath')
cp "$PNG" ".cheese/tui-verify/<slug>/<state>-80x24.png"
```

## Resize mid-session

```bash
agent-tty --home "$HOME_DIR" resize "$SID" --cols 40 --rows 15 --json
agent-tty --home "$HOME_DIR" wait "$SID" --screen-stable-ms 800 --json
```

## Interaction checks

```bash
# Rapid input
agent-tty --home "$HOME_DIR" type "$SID" "$(python3 -c 'print("x"*100)')" --json

# SIGINT + alt-screen cleanup check
agent-tty --home "$HOME_DIR" send-keys "$SID" Ctrl+C --json
agent-tty --home "$HOME_DIR" snapshot "$SID" --format text --json | jq -r '.result.text'
# Inspect the prompt; screen stability alone is not proof.
```

## Teardown

```bash
agent-tty --home "$HOME_DIR" destroy "$SID" --json
```
