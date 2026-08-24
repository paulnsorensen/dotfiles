# mise's GitHub reads need `MISE_GITHUB_CREDENTIAL_COMMAND`, not a settings block

`mise install` resolves aqua-backend pins by asking GitHub for release lists. Unauthenticated, that runs against the **60/hr per-IP anonymous cap**, and a rate-limited 403 caches nothing — so once you blow the budget, every subsequent run re-requests and re-fails.

The trap is that `gh auth login` looks like it should already have solved this.

## Why `gh` being logged in isn't enough

mise's default token reader is `github.gh_cli_tokens`, which looks for an `oauth_token` field in `~/.config/gh/hosts.yml`. On macOS, `gh` stores its token in the **keychain**, so that field does not exist. mise finds nothing and falls back to anonymous. Nothing errors; the reads just quietly go unauthenticated.

The fix is to hand mise the token explicitly:

```sh
export MISE_GITHUB_CREDENTIAL_COMMAND="gh auth token"
```

Landed in #676.

## It has to be the env var

The natural-looking alternative — a `[settings]` block with `credential_command` in `~/.config/mise/config.toml` — **does not work here**, and the reason is non-obvious:

`sync_mise` runs `mise install` with `MISE_GLOBAL_CONFIG_FILE` aimed at the repo manifest. That demotes `~/.config/mise/config.toml` to a **non-global** config, and mise ignores `credential_command` in a non-global config, treating the file as untrusted (it asks for `mise trust`). See [[operations/mise-manifest-precedence]] for why that demotion happens at all.

A `settings.toml` doesn't work either — the mise version in use reads only `config.toml`.

So the env var is the only lever that survives the sync's own config plumbing.

## Wired in two places, both guarded

Both sites export it only when `gh` is actually present:

- `zsh/core.zsh:99-101` — interactive shells, just before `mise activate`.
- `packages/sync.sh:391-393` — bootstrap and non-interactive runs, which never source `core.zsh`.

The duplication is intentional. Removing either one leaves a real path unauthenticated.

## Which pins actually hit the network

Not all of them. A pin resolvable from the local install never asks GitHub. The ones that do are the **non-semver** pins, which can't be resolved locally and force a remote release-list fetch: `tmux-builds`, `protobuf/protoc`, `rust-analyzer`, and `nextest/cargo-nextest`.

Of those, three did cache their remote-versions list. Only `nextest/cargo-nextest` never cached and re-fetched 8× per `mise install` — because its fetches were the ones landing on 403s, and a 403 caches nothing. That is the self-perpetuating half.

<don't know> Whether the non-semver pins can be reshaped into locally-resolvable ones has not been investigated; the auth fix made the question non-urgent.

**Do not** read "these pins hit the network" as "these pins lack a prebuilt binary." That symptom belongs to [[operations/mise-aqua-backend-retypes]], whose fix is a disruptive backend migration. Applying it here would be wrong.

Related: [[operations/mise-manifest-precedence]], [[operations/omp-install-etxtbsy]] (found in the same investigation), [[operations/sync-and-chezmoi]].
