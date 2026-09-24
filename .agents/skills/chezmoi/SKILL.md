---
name: chezmoi
description: >
  Guides dotfile management with chezmoi when the user says "set up dotfiles",
  "manage my dotfiles", "bootstrap a new machine", "chezmoi", "encrypt my SSH
  key in dotfiles", "template dotfiles per OS", "add secrets to dotfiles",
  "what should be in my .chezmoi.toml.tmpl", or asks how to share configs
  across macOS, Linux, and servers. Also use when the user wants the one-liner
  that sets up a fresh machine, or is about to commit something sensitive to a
  dotfiles repo. Covers source-state filename attributes (`dot_`, `private_`,
  `encrypted_`, `run_once_`), Go templates, scripts, and secret backends. Do
  NOT use for stow, yadm, rcm, or other dotfile managers, generic git repo
  setup, or password-manager setup unrelated to dotfiles.
model: sonnet
effort: medium
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(chezmoi:*), Bash(git:*), Bash(age:*), Bash(gpg:*), mcp__context7__resolve-library-id, mcp__context7__query-docs, mcp__tavily__tavily_extract
license: MIT
---

# chezmoi

Manage dotfiles across machines with [chezmoi](https://chezmoi.io/): source-state semantics, Go templates, and at-rest encryption.

## Mental model

chezmoi maps a **source directory** (`~/.local/share/chezmoi`, a git repo) to a **target directory** (the user's home).
Source filenames carry attribute prefixes that set the target name and behavior.
chezmoi renders a source file with a `.tmpl` suffix as a Go `text/template`.
Files under `.chezmoitemplates/` are reusable fragments; they produce no target files.
A per-machine config file holds machine variables.

In this repo, the source tree is `$DOTFILES/chezmoi`. Edit its plain
and `.tmpl` files directly, then run `dots sync` to deploy (see
`AGENTS.md`). Only `encrypted_` files need `chezmoi edit`.

Most trouble has two causes:

1. Editing an `encrypted_` source file directly instead of `chezmoi edit $TARGET`. This breaks the decrypt round-trip. Editing a plain or `.tmpl` source file directly is normal; `chezmoi edit` only adds editor convenience there.
2. Committing plaintext secrets "because the repo is private". Repos leak, forks leak, and history is permanent.

## Config file vs. config template

Both accept `toml`, `yaml`, `json`, or `jsonc`, detected by extension.
Two formats present at the same time is an error, not "first one wins".

| File | Path | Who writes it |
|---|---|---|
| `chezmoi.<fmt>` (the *config*) | `$XDG_CONFIG_HOME/chezmoi/`, default `~/.config/chezmoi/`. **Not** in the source repo. | `chezmoi init` (or `apply --init`) generates it from the template. Per-machine. Holds tokens and machine settings; never commit it. |
| `.chezmoi.<fmt>.tmpl` (the *config template*) | Source-state root. **Committed** to the dotfiles repo. | You write it. Use `promptBoolOnce` / `promptChoiceOnce` / `promptStringOnce` so a fresh machine answers once on first init. |

Override the location with `--config <path>`; add `--config-format <fmt>` for an unusual extension.
Inspect effective values with `chezmoi cat-config` and `chezmoi dump-config`.

## Protocol

### 1. Route the request

| User says | Go to |
|---|---|
| "set up chezmoi from scratch" / "new machine" | §2, then `references/bootstrap.md` |
| "add this file to my dotfiles" | §3 |
| "make this dotfile depend on OS / host" | `references/templating.md` |
| "encrypt this" / "store this token" | `references/secrets.md` |
| "run a script on first apply" / script order | `references/scripts.md` |
| "only manage part of this file" | `references/partial-files.md` |
| "chezmoi did something weird" | `references/pitfalls.md` |

### 2. Bootstrap a new machine

This one-liner clones, renders templates, and applies:

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply $GITHUB_USERNAME
```

### 3. Add a file

```bash
chezmoi add ~/.zshrc                  # plain copy
chezmoi add --template ~/.gitconfig   # add as a template (.tmpl suffix added)
chezmoi add --encrypt ~/.ssh/config   # encrypted at rest
chezmoi chattr +template ~/.zshrc     # turn a managed file into a template
chezmoi edit ~/.zshrc                 # edit the SOURCE; handles decrypt + .tmpl
```

Then run the safe-apply ritual (§5).

### 4. File-naming reference

Prefixes must appear in a fixed order, and the allowed set depends on the target type.
The canonical source is `/reference/source-state-attributes/`.

| Prefix | Effect on target |
|---|---|
| `dot_` | Add a leading `.` (`dot_zshrc` → `~/.zshrc`) |
| `private_` | Remove group and world permissions (0600 / 0700) |
| `readonly_` | Remove all write bits |
| `executable_` | Add the executable bit |
| `empty_` | Keep an empty file (the default removes it) |
| `encrypted_` | Decrypt the source with age/gpg before writing the target |
| `symlink_` | Create a symlink; the file content is the link target |
| `exact_` (dirs) | Delete target entries that the source does not have |
| `create_` | Create the target only when it is missing; never overwrite |
| `modify_` | The source is a script or template that produces the target content |
| `run_` | The source is a script to run, not a target file |
| `before_` / `after_` | Order scripts relative to file updates |
| `once_` (scripts) | Run only when these contents never ran successfully |
| `onchange_` (scripts) | Run only when the contents change for this filename |
| `remove_` | Remove the target if it exists |
| `external_` (dirs) | Mark an external directory (pairs with `.chezmoiexternal.<fmt>`); child attributes are ignored |
| `literal_` (anywhere) | Stop parsing attributes from this point |

Allowed order per target type (another order is a parse error):

| Target type | Allowed prefixes (in order) | Optional suffix |
|---|---|---|
| Directory | `remove_`, `external_`, `exact_`, `private_`, `readonly_`, `dot_` | — |
| Regular file | `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_` | `.tmpl` |
| Create file | `create_`, `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_` | `.tmpl` |
| Modify file | `modify_`, `encrypted_`, `private_`, `readonly_`, `executable_`, `dot_` | `.tmpl` |
| Remove file | `remove_`, `dot_` | — |
| Script | `run_`, `once_` or `onchange_`, `before_` or `after_` | `.tmpl` |
| Symlink | `symlink_`, `dot_` | `.tmpl` |

chezmoi strips `.age` / `.asc` when the matching encryption is configured.

### 5. Safe-apply ritual

Before an apply that touches important files, inspect the plan:

```bash
chezmoi status              # one line per changed file
chezmoi diff                # unified diff of pending changes
chezmoi apply --dry-run -v  # full plan, including scripts that would run
chezmoi apply               # only after the above looks right
```

For routine pulls on a trusted machine:

```bash
chezmoi update                                           # git pull --autostash --rebase + apply
chezmoi git pull -- --autostash --rebase && chezmoi diff # preview only, no apply
```

### 6. Edit safely

```bash
chezmoi edit ~/.zshrc       # open the source in $EDITOR; handles .tmpl + encryption
chezmoi cd                  # subshell in the source directory (for git)
chezmoi re-add              # refresh the source from the edited target
chezmoi merge ~/.zshrc      # 3-way merge target ↔ source ↔ destination
chezmoi merge-all           # 3-way merge every differing file (--init re-renders config first)
```

Editor order: `edit.command` → `$VISUAL` → `$EDITOR` → `vi`.
chezmoi warns when the editor returns before `edit.minDuration` (default `1s`); set it to `0` to silence the warning.

## Hard rules

Each rule prevents a real foot-gun:

1. **Never commit plaintext secrets**, even to a private repo. Pick exactly one backend per repo from `references/secrets.md`; mixing backends adds moving parts, not security.
2. **Never edit an `encrypted_` source file directly.** Use `chezmoi edit $TARGET` so the decrypt round-trip happens. Editing a plain or `.tmpl` source file directly is normal.
3. **Inspect before applying** shared or important files with `chezmoi diff` or `chezmoi apply --dry-run -v`. `exact_` deletes unmanaged entries; see it coming.
4. **Use `prompt*` functions only in the config template** (`.chezmoi.toml.tmpl`). In regular templates they prompt on every apply, diff, and status.
5. **Wrap chezmoi; do not replace it.** Do not write a competing dotfile manager or a shim around `chezmoi apply`.

## Special files and directories

chezmoi ignores source entries that begin with `.`, **except** the specials below.
It evaluates them in this order: `.chezmoiroot` → `.chezmoi.<fmt>.tmpl` → data files → `.chezmoitemplates/` → `.chezmoiignore` → `.chezmoiremove` → externals → `.chezmoiversion`.

| Path | Role |
|---|---|
| `.chezmoiroot` | One line that points at a sub-directory as the source root |
| `.chezmoi.<fmt>.tmpl` | Config template for the first `chezmoi init` (and `--init`) |
| `.chezmoidata.<fmt>` / `.chezmoidata/` | Data merged into the template `.` namespace before any render |
| `.chezmoitemplates/` | Reusable template fragments; no target files |
| `.chezmoiscripts/` | Scripts without a target file; honor `run_before_` / `run_after_` |
| `.chezmoiignore` | Per-target ignore list; source-relative and templatable |
| `.chezmoiremove` | Targets to remove on apply; templatable |
| `.chezmoiexternal.<fmt>` / `.chezmoiexternals/` | Files or archives pulled from URLs at apply time |
| `.chezmoiversion` | Minimum chezmoi version for this source repo |

The directory forms (`.chezmoidata/`, `.chezmoiexternals/`) merge in lexical order with same-prefix file forms.

## Gotchas

- `chezmoi doctor` is the first command when something is off. The first-aid kit is in `references/pitfalls.md`.
- `chezmoi init` before `.chezmoi.toml.tmpl` exists skips per-machine prompts silently. Land the template before host-specific files.
- When you migrate config formats, delete the old file in the same commit; two config files is an error.
- `chezmoi <unknown>` runs `chezmoi-<unknown>` from `$PATH` (git-style plugins). A typo can run an unrelated binary.
- Script errors (`exec format error`, `permission denied`) and CRLF breakage are in `references/scripts.md` and `references/pitfalls.md`.

## References

Read on demand:

- `references/bootstrap.md` — designing a full setup: `.chezmoi.toml.tmpl` recipe, repo layout, CI.
- `references/templating.md` — per-OS / per-host templates, data files, missing-key and empty-render rules.
- `references/secrets.md` — choosing or using a secret backend (1Password, Bitwarden, age, gpg, SOPS).
- `references/scripts.md` — `run_` scripts, script order, and the apply order.
- `references/partial-files.md` — chezmoi must own only part of a file (`modify_`, shared fragments).
- `references/pitfalls.md` — unexpected apply behavior; diagnostic commands.
- `references/docs-index.md` — the question goes deeper than these files; fetch the live docs page.
