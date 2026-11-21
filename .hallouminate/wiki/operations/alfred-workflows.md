# Alfred workflows

Alfred workflows in this repo live as source under `alfred/workflows/<name>/` and install through Alfred's import dialog. Their logic lives in `bin/` scripts that run live from the clone. The `wt` workflow is the first one; it lists git worktrees and opens them.[^1]

## Install path: import, not the sync folder

`alfred-wt install` packages `alfred/workflows/wt/` into `$TMPDIR/Worktrees.alfredworkflow` and opens it. Alfred shows its import dialog. The package fills the `dotfiles_dir` workflow variable from the `__DOTFILES_DIR__` token.[^2]

Do not commit a partial `alfred/Alfred.alfredpreferences/` package to install workflows. When the sync folder points at `alfred/`, Alfred treats that package as the full preference set. A package that holds only `workflows/` can replace the live Alfred settings on that Mac. `alfred/.sync` only checks the sync-folder setting.[^3] Workflows and preference sync both need the Powerpack.

## The `wt` workflow

- Keyword `wt`. A script filter runs `bin/alfred-wt list`, and Alfred filters the items against `match` (`repo slug branch`).
- Roots: `$DEV_DIR/*/.worktrees/*` through `wt_find`, and `$T3_WORKTREES_DIR/*/*` (default `~/.t3/worktrees`).
- Enter runs `alfred-wt open terminal`: `open -na Ghostty --args -e alfred-wt session <path>`, which runs `zsh -lic cc` in the worktree. Terminal.app is the fallback.
- Cmd-Enter opens Zed. Option-Enter copies the path.
- The JSON sets `cache: {seconds: 300, loosereload: true}` (Alfred 5.5+). A scan of about 400 worktrees took 3.7 s on 2026-10-19, so Alfred shows the cached list and reloads in the background.

## Gotchas for workflow scripts

- Alfred runs scripts with `/bin/bash` 3.2 and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. It does not load zsh, so `cc`, `ccw`, and `ccs` do not exist there. Call `bin/` scripts, or start `zsh -lic`.
- Do not escape with `${var//pat/rep}`. Bash 5.2 enables `patsub_replacement`, so an unquoted `&` in the replacement becomes the match, and `&lt;` turns into `<lt;`. Quoting rules differ in 3.2. `bin/lib/alfred.sh` escapes JSON with `sed` and fills the plist token with an `awk` `index`/`substr` loop.[^4]
- Append Homebrew dirs to `PATH`; do not prepend them. Prepending would shadow the test mocks for `open` and `pbcopy`.

## Untested live boundaries

The Bats suite runs the real script against real git worktrees, but `open`, `pbcopy`, and the session shell are mocks. On 2026-10-19 nobody had yet checked on a Mac that Alfred imports the hand-written `info.plist`, that Ghostty's `-e` runs `alfred-wt session`, or that the code runs under bash 3.2.

[^1]: bin/alfred-wt, bin/lib/alfred.sh, alfred/workflows/wt/info.plist, tests/alfred-wt.bats
[^2]: bin/lib/alfred.sh `alfred_package_workflow`; tests/alfred-wt.bats "install packages the workflow"
[^3]: alfred/lib.sh:33-71; <https://www.alfredapp.com/help/advanced/sync/>
[^4]: tests/alfred-wt.bats tests 2 and 10 failed when the `sed` escape and the `&` XML escape were removed (mutation run on 2026-10-19).
