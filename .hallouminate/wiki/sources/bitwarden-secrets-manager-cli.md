# Secrets Manager CLI

Bitwarden's Secrets Manager CLI documentation, verified 2026-08-06, identifies `bws` as the purpose-built Secrets Manager client and documents access-token authentication plus project and secret operations.
Canonical source: [Secrets Manager CLI](https://bitwarden.com/help/secrets-manager-cli/)

## Supported claims

`bws` is separate from the Password Manager CLI `bw`. The documented authentication choices include the `BWS_ACCESS_TOKEN` environment variable, recommended for most use cases, and CLI profiles. The CLI can list projects and create, edit, get, and list secrets.

Secret creation and editing accept the secret value as a command-line argument. Default object output is JSON and includes secret values. Output formats include `none`, but suppressing output does not remove a positional or option value from process arguments.

## Project relevance

The dotfiles operator path authenticates with a temporary `BWS_ACCESS_TOKEN` environment variable. Human entry through the Bitwarden web application avoids exposing provider keys through CLI arguments.

Repository code reads secrets with `bws secret list -o env` and parses that shell-oriented renderer line-by-line, which constrains managed values to a single line. Because default object output includes secret values, `bws secret get`/`list` output must never be printed to an agent-visible terminal.

_Source: <https://bitwarden.com/help/secrets-manager-cli/> · Updated: 2026-08-09 · Supersedes: none_
