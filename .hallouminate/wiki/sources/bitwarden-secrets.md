# Secrets

Bitwarden's Secrets Manager help page, verified 2026-08-06, defines a secret as a key/value object assigned to projects and documents creating and editing those objects in the web application.
Canonical source: [Secrets](https://bitwarden.com/help/secrets/)

## Supported claims

The Bitwarden Secrets Manager web application creates a secret through **New → Secret**. A secret has a name, value, notes, and project assignment. Selecting an existing secret opens its edit surface, where the value and project assignments can be changed.

This supports the dotfiles runbook's preference for entering and rotating provider credentials in the web application. The repository uses three named Secret objects; it does not model them as Password Manager login items.

## Project relevance

The web interface avoids placing a value in `bws secret create` process arguments. `bin/vault-provision:148-166` uses that CLI form only as a fallback when a record is missing, so creating all three records in the web application first keeps every value out of the process table.

_Source: <https://bitwarden.com/help/secrets/> · Updated: 2026-08-09 · Supersedes: none_
