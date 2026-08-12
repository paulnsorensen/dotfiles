# MCP secret handling — local per-consumer brokers

Managed MCP credentials never enter the daily user's environment or harness
configuration. Every managed Context7, Tavily, and Todoist registration
launches `agent-secret-proxy` with one fixed UNIX-socket path. A separate system
service owns the reusable credential and enforces the consumer's MCP tool
ceiling.

## Trust boundary

- The **daily user** launches harnesses and is assumed adversarial.
- Each **broker service identity** owns one upstream consumer and no other
  credential.
- The **operator identity** is distinct from the daily user and alone can open
  the control socket used for mutation approval.
- Root and the OS service manager remain trusted.

The installer creates separate request and control sockets with mode `0600` and
different owners. The broker binds both sockets as root, then permanently drops
to the service identity before accepting traffic
(`scripts/agent-secret-broker.py`, `Broker.start`).

CPython's `socket` module has no `getpeereid()` and exposes neither the
constant nor a helper for macOS peer-credential lookup. On Darwin the broker
reads peer UID via `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` into a
`struct xucred` (`scripts/agent-secret-broker.py:30-33`); missing this dropped
every client connection until fixed.

## Credential lifecycle

`bin/vault-provision` is the only vault-reading operator path. It resolves the
configured 1Password or Bitwarden provider, reads only the three managed runtime
fields, and writes each value to a distinct root-owned mode-`0600` credential
file. `bin/agent-secret-install` installs the matching root-owned policy and
service definition.

The provisioner snapshots the selected Node runtime into a root-owned,
non-writable service runtime and pins exact npm MCP package versions. This
prevents the daily user or a package manager from replacing an upstream
executable after provisioning.

`.env` contains non-secret settings only. `zsh/core.zsh`, `bin/cc-env-exec`,
`bin/dots`, and `agents/mcp/sync.sh` clear the retired credential names before
launching a child. They also remove the obsolete
`$XDG_CACHE_HOME/dotfiles/secrets.env` file.

`bws -o env` output quotes values. The legacy shell-sourcing flow stripped
those quotes for free; the broker path reads the raw bytes, so
`vault_secret_value` must strip the matched surrounding quote pair itself or
every credential file ends up quote-wrapped and rejected by the upstream API.

Provisioning distinguishes an absent Bitwarden Secret from a provider or transport failure: only absence may enter the interactive creation path. The Node snapshot prefix comes from `node -p process.execPath`, must contain the matching npm/npx tree, and rejects Homebrew Cellar roots so provisioning cannot copy a package-manager prefix wholesale. On macOS, changing a broker plist requires a bounded `bootout` wait followed by bounded `bootstrap` retries; `kickstart` alone would restart the old loaded definition.[^provision-hardening]

[^provision-hardening]: `bin/vault-provision:75-106,146-167`; `bin/lib/vault.sh:325-345`; `bin/agent-secret-install:218-257`

## Operator workflow

1. Install packages with `dots sync`. Put the three provider API keys in the
   selected vault source.
2. Run `bin/vault-provision --request-user <daily-user> --operator-user
   <separate-operator>` from an authenticated operator session, as the user and
   not under `sudo` — the script sudos internally, and readiness needs the
   user's own Keychain session. A `sudo`'d run also leaves a root-owned
   `~/.cache/dotfiles/vault-resolution.lock` that blocks later user runs.
   `DOTFILES_DIR` resolves script-relative rather than from the environment, so
   an inherited `DOTFILES_DIR` pointing at another clone can no longer anchor
   the install elsewhere. Reprovisioning replaces the root-owned snapshots and
   restarts every Linux or macOS broker.
3. When an agent receives a pending write, inspect it as the operator with
   `/usr/local/libexec/dotfiles/agent-secretctl --consumer <name> pending`.
4. Approve only the matching request with
   `/usr/local/libexec/dotfiles/agent-secretctl --consumer <name> approve
   --nonce <nonce>`. Any argument change, replay, or 60-second expiry fails
   closed.

## MCP enforcement

The broker exposes only policy-listed tools from `tools/list`. A read call is
forwarded without interaction. A write call first returns a pending nonce and
canonical argument digest; it is forwarded only after `agent-secretctl` submits
an approval matching consumer, tool, canonical arguments, nonce, and expiry.
Approvals expire after 60 seconds and are consumed once.

The upstream process receives a fresh minimal environment containing only
`HOME`, `PATH`, `NO_COLOR`, and that consumer's one credential variable.
Responses and errors are recursively redacted before they cross the request
socket.

Unknown tools, changed arguments, missing nonces, expired approvals, replayed
approvals, unsafe policy files, and user-writable upstream executables all fail
closed.

## Managed configuration surfaces

The fixed proxy command is canonical in `agents/mcp/registry.yaml` and is
mirrored by `profiles/*/profile.yaml`,
`chezmoi/.chezmoidata/claude.yaml`,
`chezmoi/dot_omp/private_agent/mcp.json`, and
`chezmoi/private_dot_copilot/mcp-config.json.tmpl`. No managed entry has an
`env` or `envFile` credential delivery channel.

See [[agent-secret-isolation-001]], [[agent-secret-isolation-002]], and
[[agent-secret-isolation-003]] for the accepted identity, firewall, and approval
decisions.

[[../operations/bitwarden-secrets-manager]] is the provider-side runbook for the
Bitwarden path: exact Secret names, machine-account permission, the temporary
root-shell access token, and key rotation.
