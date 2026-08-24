# Bitwarden Secrets Manager operations

The dotfiles Bitwarden provider uses the **Secrets Manager** product and its `bws` CLI, not Password Manager items or the `bw` CLI. A human maintains three provider credentials in one project; `bin/vault-provision` copies them across a privileged operator boundary into root-owned per-consumer credential files.

This page is the provider-side runbook. [[../architecture/mcp-secret-handling]] owns the runtime broker, socket, and approval design.

## Install and enable the right product

Open Bitwarden's web application and use the product switcher to select Secrets Manager. If it is not enabled, activate a Secrets Manager organization and plan. The Free tier is sufficient for this single-project, single-machine-account topology; current plan details live in [[../sources/bitwarden-secrets-manager-plans]].

Install the separate `bws` client. Do not substitute the Password Manager CLI `bw`. `bin/lib/vault.sh:198-201` reports `cargo install bws --locked` when `bws` is missing. The workstation had `bws` 2.1.0 when this runbook was verified. The canonical onboarding sequence is [[../sources/bitwarden-secrets-manager-quick-start]].

## Create the project and Secret objects

Create one Secrets Manager project, such as `dotfiles`. Then follow [Bitwarden's **New → Secret** instructions](https://bitwarden.com/help/secrets/#create-a-secret) and assign these exact Secret objects to that project:

| Secret name | Consumer | Required content |
|---|---|---|
| `CONTEXT7_API_KEY` | context7 | Context7 API key |
| `TAVILY_API_KEY` | tavily | Tavily API key |
| `TODOIST_API_KEY` | todoist | Todoist API token |

These three names are the complete runtime set. `bin/lib/vault.sh:348-350` is the canonical list, and `bin/lib/vault.sh:314-317` refuses any other key with `refusing non-runtime secret key`; `tests/vault.bats:101-105` locks that refusal. Retired names — including `GH_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, `GITHUB_APP_PRIVATE_KEY`, and `SERPER_API_KEY` — are actively unset before any child exec at `bin/lib/vault.sh:19-40`, locked by `tests/vault.bats:74-92`. Do not recreate them as Secret objects.

These are Secrets Manager **Secret** records, not Password Manager login items. See [[../sources/bitwarden-secrets]].

### Create them in the web application, not the CLI

Enter and edit values in the web application so secret material never appears in process arguments.

When a Secret is missing, `bin/vault-provision:148-166` falls back to a hidden prompt and then runs `bws secret create "$key" "$value" "$project_id"` — which places the value in `bws` process arguments, visible to anything that can read the process table. That fallback also requires a write-capable machine account. Creating all three records in the web application first avoids both.

### Single-line values only

The Bitwarden fetch path uses **env output**: `bin/lib/vault.sh:300-302` runs `bws secret list "$project_id" -o env`, and `bin/lib/vault.sh:329-342` matches `KEY=` on a physical line and strips one surrounding quote pair. A value containing a newline is truncated at its first newline, because the env renderer emits `KEY="VALUE"` on one line without escaping. See [[../sources/bws-2-1-0-output-rendering]].

All three managed credentials are single-line API keys, so this is sufficient today. Do not add a multiline credential to this project without first changing the fetch path — a truncated key fails at the consumer, not at provisioning.

`tests/vault.bats:107-159` locks the parsing behaviour: quoted values are unwrapped, unquoted values pass through unchanged, and an unmatched interior quote is preserved.

## Non-secret settings in `.env`

Keep only these Bitwarden-related keys in the checkout's `.env`:

```dotenv
DOTFILES_VAULT_PROVIDER=bitwarden
BWS_PROJECT_ID=<project-uuid>
```

`bin/lib/vault.sh:56-57` is the exported allowlist; unknown keys and every retired secret name are dropped, locked by `tests/vault.bats:51-72`. `.env.example:6-19` documents the supported non-secret fields.

Never put `BWS_ACCESS_TOKEN` or any provider credential in `.env`, shell startup files, a tmux environment, a systemd user environment, an agent prompt, or a user-owned token file.

## Machine account and least privilege

Create a Secrets Manager machine account, grant it access to this project, and issue an access token as documented in [[../sources/bitwarden-machine-accounts]] and [[../sources/bitwarden-access-tokens]].

Grant **read** permission. The fetch path only lists secrets in the one configured project. Grant **read and write** only if you intend to use the missing-record fallback above; with all three records present, the runtime machine account stays read-only.

## Linux access-token boundary

On Linux, `BWS_ACCESS_TOKEN` belongs only in a temporary interactive **root shell** for the provisioning transaction. `bin/lib/vault.sh:143-147` deliberately reads the Linux token from the operator environment instead of a same-user file; on macOS the same function reads the login Keychain (`security find-generic-password -s bws_access_token`, `bin/lib/vault.sh:137-142`). Enter it from a separate terminal outside the coding-agent session:

```bash
sudo -i
cd /path/to/the/dotfiles-checkout

set +x
read -rsp 'BWS access token: ' BWS_ACCESS_TOKEN
printf '\n'
export BWS_ACCESS_TOKEN

status=0
bin/vault-provision \
  --request-user paul \
  --operator-user root || status=$?

unset BWS_ACCESS_TOKEN
exit "$status"
```

The hidden `read` avoids echo and shell history. Elevating before entry keeps the variable out of the ordinary user's process environment. Do not pass the token through `env BWS_ACCESS_TOKEN=...` or `sudo --preserve-env`; those forms either expose it in process arguments or first place it in the agent user's environment.

`--request-user` and `--operator-user` must resolve to different UIDs — `bin/vault-provision:55-58` exits 2 otherwise. The request user is the daily user whose agents get the broker socket; the operator user is the separate identity that can approve writes.

This boundary assumes agents cannot become root. Unrestricted passwordless `sudo`, root-equivalent container access, or permission to inspect root processes defeats every machine-local storage boundary.

## Access-token lifetime

`BWS_ACCESS_TOKEN` is needed only while `vault-provision` resolves the provider and downloads the current values. The installed brokers never receive it. Bitwarden defaults token expiry to **Never**, but this workflow needs only the shortest expiry covering the maintenance transaction; alternatively revoke the token immediately after successful provisioning and create a new one for the next rotation.

Revoking or expiring the BWS token blocks later Bitwarden fetches. It does not revoke provider credentials already copied into local credential files.

## What provisioning installs

`bin/vault-provision` writes each value to `/etc/dotfiles/agent-secret/credentials/<consumer>.credential`, root-owned mode `0600` (`bin/vault-provision:255-263`). It snapshots the selected Node runtime into a root-owned non-writable tree and pins exact MCP package versions (`bin/vault-provision:90-133,292-297`), then records non-secret provider provenance in `/etc/dotfiles/agent-secret/provider.json` (`bin/vault-provision:301-303`).

`tests/vault-provision.bats:56-129` locks the credential modes, the absence of credential values in policy files, the pinned upstream argv, the per-consumer tool ceilings, and the provenance record.

## Rotate a provider key

There is no automatic synchronization from Bitwarden into the local credential files. Rotate a key as an explicit cutover:

1. Generate the replacement at the upstream provider. Keep the old key active during the cutover when the provider supports overlap.
2. In Secrets Manager, open the existing Secret record, replace its Value, and save it. Preserve the exact name and project assignment.
3. In a separate root terminal, enter `BWS_ACCESS_TOKEN` with the transaction above and rerun `bin/vault-provision`.
4. Exercise a harmless read through the affected MCP consumer. Provisioning rewrites the credential file and restarts the broker service — `bin/agent-secret-install:207-209` on Linux, `bin/agent-secret-install:230-231` on macOS.
5. Revoke the old provider key only after the new broker path succeeds.
6. Unset and, when using a maintenance token, revoke the BWS access token.

If the provider cannot keep two keys active, steps 1–5 become a brief non-overlapping cutover. Never revoke the old key before the local smoke test when overlap is available.

## Verification and failure handling

`bws project list --output table` is safe for confirming project access because it does not print secret values. Run it only inside the temporary privileged token session. Avoid printing `bws secret list` output to a terminal: documented object output contains secret values. See [[../sources/bitwarden-secrets-manager-cli]].

Provisioning fails before installing anything when the provider is unresolved (`bin/vault-provision:60-64`), and `bin/lib/vault.sh:196-208` names the exact cause — missing `bws`, unset `BWS_PROJECT_ID`, or an empty token. A missing Secret reports `Bitwarden secret '<KEY>' is missing` at `bin/lib/vault.sh:339-342`.

After a successful provision, test the changed consumer rather than inspecting its credential file. Agents should receive MCP results, never raw secret values.

_Source: Bitwarden official documentation and the PR #616 broker implementation as of `b09e39c` · Updated: 2026-08-09 · Supersedes: ad hoc `.env` credential export and undocumented key-rotation procedure_
