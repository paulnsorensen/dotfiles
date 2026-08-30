# mise config precedence can deadlock `dots sync`

Pointing `mise install` at the tracked manifest does **not** make it install what the manifest says. The live `~/.config/mise/config.toml` still wins. In August 2026 that single fact wedged `dots sync` on one machine for eight days, and every re-run reproduced the wedge exactly.

If you read one thing here: **the manifest is an input to package convergence, not an output of it.** The live config has to be correct *before* `mise install` runs, because nothing downstream can fix it.

## Why the live file wins

mise's precedence is **proximity-based**, not "global loses". `MISE_GLOBAL_CONFIG_FILE` names the *global* config; `~/.config/mise/config.toml` is then loaded as a **non-global** config nearer to the working directory, so it lands later in the chain and takes priority.

Confirm it on any box rather than trusting this paragraph:

```
MISE_GLOBAL_CONFIG_FILE=/tmp/some-manifest.toml mise config ls
```

`~/.config/mise/config.toml` still appears, ordered *after* the manifest, and it is the file actually supplying the tools. Verified on mise 2026.7.14.

That demotion has a second consequence, which is why the GitHub-auth fix looks so strange: a non-global config is also untrusted, so mise ignores `credential_command` inside it. See [[operations/mise-github-auth]].

## The deadlock

A pin bump lands in the repo. The affected machine's live `config.toml` is two days stale. Then:

1. `.sync` exports `MISE_CONFIG_FILE` at the repo source and `sync_mise` runs `MISE_GLOBAL_CONFIG_FILE="$mise_config" mise install` (`packages/sync.sh:396`). The live config outranks it, so **the bumped version is never requested**.
2. `verify_harness_versions` (`.sync:45-74`) checks the installed `omp` and `codex` binaries and gates the final `chezmoi apply` on them matching (`.sync:146`). It compares against **hardcoded literals** in `.sync` — `omp/18.0.5` at `:57-58`, `codex-cli 0.146.0` at `:70-71` — not against the manifest, and it covers only those two harnesses. (The OMP literal is now renovate-locked to its install pin; see [[sync-and-chezmoi]].)
3. The gate sees the old binary and skips the final apply (`.sync:157-159`), recording a `harness-versions` failure.
4. That skipped apply was **the only step that would have refreshed the live `config.toml`** to the new pin.

So the stale config causes the gate to fail, and the failing gate skips the step that would have cured the stale config. No amount of re-running escapes it — each attempt reads the same stale file and takes the same branch. Retrying is not a fix; it is the symptom.

## The fix is ordering, and it lives in the prepare phase

`apply_mise_manifest` (`.sync-lib.sh:147-158`) applies **just that one file** ahead of everything else:

```sh
chezmoi --source "$source_dir" apply --force ~/.config/mise/config.toml
```

It is called from `chezmoi/.sync:43`, inside the `CHEZMOI_SYNC_PHASE=prepare` branch that exits before any generated config is applied. Package convergence runs next and now reads a current live config. Landed in #677.

Failure there is deliberately **non-fatal** (`.sync-lib.sh:153-157`) — it warns and continues, because `verify_harness_versions` remains the authority on whether convergence actually produced the pinned harnesses. Do not "improve" this by making it exit 1.

### Do not delete this as redundant

The obvious-looking cleanup is fatal. `.sync` *already* exports `MISE_CONFIG_FILE` pointing at `chezmoi/dot_config/mise/config.toml` for both calls into `packages/sync.sh` — the bootstrap-only call at `:113-116` and the main convergence call at `:140-141` — which makes `apply_mise_manifest` look like belt-work someone forgot to remove.

It isn't. Those exports predate the deadlock (`#523`, `#589`) and were in place *while it ran*. They are necessary but not sufficient: they set `MISE_GLOBAL_CONFIG_FILE`, and mise demotes that below the live file. Only `apply_mise_manifest` makes the live file right. Remove it and the eight-day deadlock comes back, with no test failing to warn you.

For the same reason, PR #677 never touched `.sync` at all. Its files were `.sync-lib.sh`, `chezmoi/.sync`, `chezmoi/lib/install-external.sh`, `packages/sync.sh`, and two test files. An earlier version of this page credited the `.sync` exports with the fix; that was wrong.

## Bootstrap still works

`mise_config_path` (`packages/sync.sh:44-50`) prefers `MISE_CONFIG_FILE` and falls back to `MISE_BOOTSTRAP_CONFIG_FILE`, so a fresh machine with no live config yet resolves against the repo source. Proximity precedence only bites once a live file exists.

Related: [[operations/sync-and-chezmoi]] (the prepare → package-sync → final-apply phase ordering this lives inside), [[operations/mise-aqua-backend-retypes]] (a different mise pin failure — backend retyping, not precedence), [[operations/mise-github-auth]] and [[operations/omp-install-etxtbsy]] (the two sibling failures found in the same investigation).
