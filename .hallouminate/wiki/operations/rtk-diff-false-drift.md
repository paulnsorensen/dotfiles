# rtk `diff` rewrite can fake file drift

The rtk PreToolUse delegation rewrites a bare `diff a b` to a `git diff` form. Two consequences an agent comparing files must know:

- `git diff` reads `~/.gitattributes`; when it errors there (observed: "too many levels of symbolic links" on the `~/.gitattributes → $DOTFILES/gitattributes` symlink inside a sandboxed Bash tool, even though the target exists), the command exits non-zero **regardless of file equality**.
- Any `diff -q … && echo sync || echo DRIFT` exit-code check therefore reports false DRIFT for every file.

**Why it matters**: during the 2026-07-07 tool-reroute hook verification this produced a false "all deployed hook files drifted" conclusion; checksums showed everything in sync.

**Do instead**: compare with `shasum -a 256` / `cmp`, or bypass the rewrite with `rtk proxy diff a b`.

Related: [[dev-environment]] (rtk wiring), [[../architecture/config-drift]] (real drift classes — this gotcha is how to avoid *misdiagnosing* one).
