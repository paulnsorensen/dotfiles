# Machine Accounts

Bitwarden's Secrets Manager machine-account help page, verified 2026-08-06, documents creating non-human identities and granting them project-level read or read/write access.
Canonical source: [Machine Accounts](https://bitwarden.com/help/machine-accounts/)

## Supported claims

Machine accounts authenticate automated workloads rather than people. A machine account receives access to selected projects through the project's or machine account's access configuration. Permissions can allow reading secrets or reading and writing secrets.

## Project relevance

A dotfiles machine account needs read access when all three Secret objects are created and updated by a human in the web application. Grant write access only when `vault-provision` is intentionally allowed to create missing records.

Project-scoped least privilege limits the access token to the one Secrets Manager project used by the local credential brokers.

_Source: <https://bitwarden.com/help/machine-accounts/> · Updated: 2026-08-09 · Supersedes: none_
