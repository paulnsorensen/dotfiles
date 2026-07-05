# RTK-Only Profile (experimental)

This profile leans on **rtk** (Rust Token Killer) and the **tilth** MCP to keep tool output token-lean. The goal is to push high-volume I/O through proxies that strip noise before it reaches your context.

## Why this profile exists

Default sessions blow through tokens on verbose shell output (git diff, test runs, build logs, ls trees). rtk's proxies summarize those outputs heuristically; tilth's MCP reads source files with AST outlining. rtkonly is the discipline session — use the proxies by default and fall back to raw tools only when the proxy can't answer the question.

## MCPs in scope

Generated strictly from `mcp-scope.yaml`:

- **tilth** — AST-aware symbol search (`tilth_search`), smart file read (`tilth_read`), glob discovery (`tilth_files`), blast radius (`tilth_deps`). First choice for code exploration.

## Working standards

- **Token budgets are not advisory.** Treat context as finite — push verbose operations through the proxies below; summarize before a step balloons context.
- **Calibrate claims.** Tag opinions `<certain>` / `<speculative>` / `<don't know>`.
- **Be succinct.** Answer → minimal support → stop.

## Wrap shell commands with `rtk rewrite`

For any shell command you intend to run, ask rtk for the token-optimized form:

```
rtk rewrite <full command here>
```

rtk exits 0 and prints the rewritten command when an optimization exists; it exits 1 with no output when the command is already optimal (run it as-is). The PreToolUse hook (`rtk hook claude`) also auto-rewrites at the harness layer, so explicit `rtk rewrite` is redundant — useful when you want the rewritten form visible before committing to run it.

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

For **code** reads, prefer the tilth MCP (`tilth_read`, `tilth_search`) over `rtk read` — tilth has AST-aware outlining that rtk does not.

## When to bypass rtk

- Small, targeted edits — no token benefit to wrapping.
- One-off conversational bash (`which foo`, `test -x bar`) — wrapping adds ceremony without savings.
- Anything rtk doesn't have a subcommand for and where `rtk rewrite` returns nothing.

## Token accounting

Run `rtk gain` at any time to see cumulative savings. The goal of this profile is to produce visible, meaningful gains compared to a vanilla session on the same task.
