# rtk `diff` rewrite can fake file drift (historical)

**Status: historical.** rtk was removed from this repo on 2026-09-11 (see [[dev-environment]] § rtk wiring for the benchmark evidence). The tool-reroute hook no longer delegates to rtk, so this rewrite cannot occur. The page stays as a record of the failure shape.

The rtk PreToolUse delegation rewrote a bare `diff a b` to a `git diff` form. Two consequences an agent comparing files had to know:

- `git diff` reads `~/.gitattributes`; when it errors there (observed: "too many levels of symbolic links" on the `~/.gitattributes → $DOTFILES/gitattributes` symlink inside a sandboxed Bash tool, even though the target exists), the command exits non-zero **regardless of file equality**.
- Any `diff -q … && echo sync || echo DRIFT` exit-code check therefore reported false DRIFT for every file.

**Why it mattered**: during the 2026-07-07 tool-reroute hook verification this produced a false "all deployed hook files drifted" conclusion; checksums showed everything in sync.

**Lesson that survives rtk**: compare files with `shasum -a 256` / `cmp`, not with a wrapper that may rewrite `diff`.

Related: [[dev-environment]] (rtk removal), [[../architecture/config-drift]] (real drift classes — this gotcha is how to avoid *misdiagnosing* one).
