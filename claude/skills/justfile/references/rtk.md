# Token-optimized output via rtk

When `just` recipes run inside an LLM agent's context (Claude Code, Cursor,
Conductor, CI logs piped to an agent), output verbosity = token cost. `just`
echoes each recipe line, then the underlying tool prints its own banner — a
typical TS pipeline is 60+ lines, most of it low-signal.

Use this reference once the universal levers (`@` prefix, `--silent --no-audit
--no-fund`, drop coverage from default `build`) aren't enough.

## rtk rewrite shell wrap

Route every recipe line through `rtk rewrite`. rtk ships deterministic filters
for 100+ tools (cargo, npm, pytest, go, git, biome, vitest) that trim banners,
dedupe, truncate. Unknown commands fall through untouched.

```just
set shell := ["bash", "-c", "set -euo pipefail; if r=$(rtk rewrite \"$0\" 2>/dev/null); then eval \"$r\"; else eval \"$0\"; fi"]
```

rtk's `[tee] mode = "failures"` config (default in recent versions) tees every
`rtk <wrapper>` invocation to `~/.local/share/rtk/tee/*.log` and the filter
decides what to echo live. Run `rtk config` to confirm.

## Hard-gate the noisy step with rtk err / rtk test

The shell wrap gets you filtered output, but some filters (notably vitest) still
print useful-but-verbose blocks — coverage tables, summaries — on success. For
the single noisiest recipe line, wrap it explicitly to suppress *all* output on
success and surface full output only on failure:

```just
build:
    npm install
    npm run lint:fix
    npm run build
    rtk test npm run test:coverage   # silent on pass, full dump on fail
```

- `rtk test CMD` — show only test failures
- `rtk err CMD` — show only errors/warnings (use for non-test commands)

`rtk rewrite` sees `rtk test ...` / `rtk err ...` as already-wrapped and falls
through, so the shell wrap and the explicit gate compose cleanly.

**Don't hard-gate every line** — success-case output like "Formatted 13 files"
or "Installed 42 packages in 1s" is signal that confirms the step actually ran.
Gate only the one or two recipe lines that dominate the success-case token
budget (usually coverage, sometimes a slow build).

## Portable fallback (no rtk)

Buffer output, print only on failure:

```bash
quiet_on_success() { local out; if ! out=$("$@" 2>&1); then echo "$out"; return 1; fi; }
```

## npm script-naming gotcha

rtk's `npm run <script>` wrapper infers the underlying tool from the script
name (e.g. `lint` → ESLint parser). If your `lint` script actually runs
`tsc --noEmit`, rtk will try to parse tsc output as ESLint JSON and fail.
Rename to `typecheck` — it's semantically correct (biome/eslint lints, tsc
typechecks) and removes the collision. Apply the same principle to any script
name that lies about its tool.
