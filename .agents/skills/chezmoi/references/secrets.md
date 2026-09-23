# Secrets

chezmoi supports four secret-handling strategies. Pick **one** per repo
unless you have a clear, written reason to mix.

## Decision tree

| Situation | Backend |
|---|---|
| Public dotfiles repo, daily laptop, you use a password manager | 1Password / Bitwarden CLI template functions |
| Private repo, offline-friendly, single user | age (`encrypted_` prefix) |
| Team-shared dotfiles (rare) | SOPS-encrypted `.chezmoidata/secrets.yaml` |
| First-bootstrap before any password manager exists | gitignored plaintext `.chezmoidata/local.yaml` (transitional) |

## 1Password (recommended for public repos)

Install `op`, sign in (`op signin`), then use template functions:

```go-template
export GITHUB_TOKEN="{{ onepasswordRead "op://Personal/GitHub/credential" }}"
export ANTHROPIC_API_KEY="{{ onepasswordRead "op://Dev/Anthropic/api-key" }}"
```

`chezmoi apply` invokes `op` at render time. Secrets never touch the
source repo. Other available functions: `onepassword`,
`onepasswordDocument`, `onepasswordItemFields`,
`onepasswordDetailsFields`.

## Bitwarden

```go-template
export GITHUB_TOKEN="{{ (bitwarden "item" "github-token").login.password }}"
```

Requires `bw` CLI logged in. Available functions: `bitwarden`,
`bitwardenAttachment`, `bitwardenFields`, `bitwardenSecrets` (Bitwarden
Secrets Manager).

## age (recommended for private repos)

age is a small, modern, GPG-free encryption tool. Install
(`brew install age` / `apt install age`), generate an identity:

```bash
age-keygen -o ~/.config/chezmoi/key.txt
chmod 600 ~/.config/chezmoi/key.txt
```

The file contains a header comment with the public key on the
`# public key: age1…` line (line 2 of the default `age-keygen`
output). Copy that value into the `recipient` setting below.

```toml
# ~/.config/chezmoi/chezmoi.toml
encryption = "age"

[age]
identity = "~/.config/chezmoi/key.txt"
recipient = "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Note: `encryption` must come before any other top-level section.

Then add files encrypted:

```bash
chezmoi add --encrypt ~/.ssh/config
```

The source becomes `encrypted_private_dot_ssh/encrypted_config.age`. The
decrypted version only ever lives at the target path. `chezmoi edit`
decrypts to a private temp dir for editing, then re-encrypts on save.

### Bootstrapping the age key on a new machine

The age identity must NOT live in the public dotfiles repo. Two options:

1. Put the identity in your password manager and have the bootstrap
   script fetch it.
2. Keep the identity passphrase-encrypted in the repo (`key.txt.age`)
   and have a `run_once_before_` script decrypt it on first init:

```sh
# .chezmoiscripts/run_once_before_decrypt-age-key.sh.tmpl
#!/bin/sh
if [ ! -f "${HOME}/.config/chezmoi/key.txt" ]; then
  mkdir -p "${HOME}/.config/chezmoi"
  chezmoi age decrypt --passphrase \
    "{{ .chezmoi.sourceDir }}/key.txt.age" \
    > "${HOME}/.config/chezmoi/key.txt"
  chmod 600 "${HOME}/.config/chezmoi/key.txt"
fi
```

Add `key.txt.age` to `.chezmoiignore` so chezmoi doesn't try to render
it as a target.

## gpg

Same model as age, but with gpg. Use only if you already have gpg keys
you trust.

```toml
encryption = "gpg"

[gpg]
recipient = "YOUR-LONG-KEY-ID"
```

Mute the noisy stderr with `args = ["--quiet"]`.

For passphrase-only (no key) encryption, set `gpg.symmetric = true`.

### Migrating from gpg to age

```bash
# decrypt every gpg-encrypted file and re-add as age
for encrypted_file in $(chezmoi managed --include=encrypted); do
  decrypted_file="${encrypted_file%.asc}"
  chezmoi cat "$encrypted_file" > "$decrypted_file"
  chezmoi re-add "$decrypted_file"
done
```

(Audit before running — destructive.)

`chezmoi re-add` does **not** process templates. If any of the
gpg-encrypted sources were also `.tmpl`, the loop above silently strips
templating from the source. For those files, run
`chezmoi add --encrypt --template "$decrypted_file"` instead, or migrate
them by hand.

## SOPS

For team-shared dotfiles where multiple people decrypt with their own
keys. SOPS encrypts only the *values* in YAML/JSON, leaving structure
visible — which is great for diff review.

```bash
sops --encrypt --in-place .chezmoidata/secrets.yaml
```

Configure chezmoi to read SOPS-decrypted output via the
`includeTemplate` / external command pattern documented at
<https://chezmoi.io/user-guide/encryption/sops/>.

## pass / KeePassXC

For users on `pass` (the standard Unix password store) or KeePassXC:

```go-template
export AWS_ACCESS_KEY_ID="{{ pass "aws/access-key" }}"
export DB_PASSWORD="{{ (keepassxc "Database/Production").Password }}"
```

KeePassXC requires `keepassxc-cli` and the database path configured in
`chezmoi.toml`:

```toml
[keepassxc]
database = "~/keepass.kdbx"
```

## Cached-secrets pattern (Bitwarden, slow CLIs)

If your password manager CLI is slow or requires unlocking on every
apply, write a small shell script that fetches and writes secrets to
`.chezmoidata/secrets.yaml` (gitignored). chezmoi reads the file at
apply time without the CLI being invoked:

```sh
# scripts/refresh-secrets.sh
bw unlock --raw > /tmp/.bw_session
export BW_SESSION=$(cat /tmp/.bw_session)

cat > ~/.local/share/chezmoi/.chezmoidata/secrets.yaml <<EOF
secrets:
  github_token: $(bw get password github-token)
  npm_token: $(bw get password npm-token)
EOF
```

Then use `{{ .secrets.github_token }}` in templates. The plaintext file
sits in the source dir unencrypted but is gitignored — fine because
it's the same machine that already has the rendered dotfiles.

## Anti-patterns

- Committing plaintext `.env` "because the repo is private". Repos leak.
- Mixing 1Password + age + SOPS without documenting why each one is
  needed.
- Putting the age identity (`key.txt`) in the dotfiles repo.
- Using `prompt*` template functions for secrets — they re-prompt on
  every `apply`.
- Using `output "op" "read" "..."` instead of the dedicated
  `onepasswordRead` function (works but bypasses chezmoi's caching).
