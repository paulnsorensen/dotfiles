# RTK-Only Profile (experimental)

This profile leans on **rtk** (Rust Token Killer) and **tilth** MCP to keep
tool output token-lean. Native Read/Write/Grep/Glob stay available — the goal
is not to block them, but to push high-volume I/O through proxies that strip
noise before it reaches your context.

## Why this profile exists

Default Claude Code sessions blow through tokens on verbose shell output
(git diff, test runs, build logs, ls trees). rtk's proxies summarize those
outputs heuristically; tilth's MCP reads source files with AST outlining.
rtkonly is the discipline session — you use the proxies by default and only
fall back to raw tools when the proxy can't answer the question.

## MCPs in scope

Generated strictly from `mcp-scope.yaml`:

- **tilth** — AST-aware symbol search (`tilth_search`), smart file read
  (`tilth_read`), glob discovery (`tilth_files`), blast radius (`tilth_deps`).
  First choice for code exploration.

No other MCPs load in this profile. Context7, Tavily, Serper, etc. are
filtered out at launch via `--strict-mcp-config`.

## Wrap shell commands with `rtk rewrite`

For any shell command you intend to run, ask rtk for the token-optimized form:

```
rtk rewrite <full command here>
```

rtk exits 0 and prints the rewritten command when an optimization exists; it
exits 1 with no output when the command is already optimal (run it as-is).
The existing PreToolUse hook (`rtk hook claude`) also auto-rewrites at the
harness layer, so explicit `rtk rewrite` is a belt-and-suspenders move —
useful when you want the rewritten form visible before committing to run it.

### Common proxies (invoke directly when you know the shape)

| You want | Invoke |
|----------|--------|
| List files | `rtk ls <path>` |
| Tree view | `rtk tree <path>` |
| Read file (non-code) | `rtk read <path>` |
| Git operation | `rtk git <subcommand>` |
| GitHub CLI | `rtk gh <subcommand>` |
| Grep | `rtk grep <pattern>` |
| Find files | `rtk find <args>` |
| Diff | `rtk diff <args>` |
| Run tests | `rtk test <cmd>` |
| Errors only | `rtk err <cmd>` |

For **code** reads, prefer tilth MCP (`tilth_read`, `tilth_search`) over
`rtk read` — tilth has AST-aware outlining that rtk does not.

## When to bypass rtk

- Native Edit/Write for small, targeted changes — no token benefit to
  wrapping.
- One-off conversational bash (`which foo`, `test -x bar`) — wrapping adds
  ceremony without savings.
- Anything rtk doesn't have a subcommand for and where `rtk rewrite` returns
  nothing.

## Token accounting

Run `rtk gain` at any time to see cumulative savings. The goal of this
profile is to produce visible, non-trivial gains compared to a vanilla
session on the same task.
