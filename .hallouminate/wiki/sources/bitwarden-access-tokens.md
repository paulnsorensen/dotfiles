# Access Tokens

Bitwarden's Secrets Manager access-token help page, verified 2026-08-06, documents machine-account authentication, configurable expiry, one-time token display, and revocation.
Canonical source: [Access Tokens](https://bitwarden.com/help/access-tokens/)

## Supported claims

A Secrets Manager access token authenticates a machine account. Operators create one from the machine account's **Access tokens** view, choose its name and expiration, and copy it when displayed. Bitwarden does not display that token again.

The documented default expiration is **Never**, but tokens can be revoked from the same machine-account view. An expired or revoked token can be replaced by creating another token.

## Project relevance

The dotfiles Linux workflow needs `BWS_ACCESS_TOKEN` only during `vault-provision`. Bitwarden's lifecycle controls therefore permit a short-lived maintenance token or immediate post-provision revocation instead of a permanent token in user configuration.

Token expiry or revocation prevents later Bitwarden fetches; it does not revoke provider credentials already copied into the local brokers.

_Source: <https://bitwarden.com/help/access-tokens/> · Updated: 2026-08-06 · Supersedes: none_
