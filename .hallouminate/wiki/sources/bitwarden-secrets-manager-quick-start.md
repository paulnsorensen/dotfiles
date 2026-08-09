# Secrets Manager Quick Start

Bitwarden's Secrets Manager quick start, verified 2026-08-06, documents the end-to-end product flow: open Secrets Manager, create a project, create a machine account, grant project access, issue an access token, install `bws`, and authenticate it.
Canonical source: [Secrets Manager Quick Start](https://bitwarden.com/help/secrets-manager-quick-start/)

## Supported claims

Secrets Manager is opened from the Bitwarden web application's product switcher. The documented sequence creates a project and a machine account, assigns project access, creates an access token, then uses the `bws` CLI with `BWS_ACCESS_TOKEN`.

## Project relevance

This is the canonical onboarding sequence for the dotfiles Bitwarden provider. On a machine where `bws` is already installed, the remaining work is the web-side project, Secret objects, machine-account permission, access token, and local nonsecret project identifier.

_Source: <https://bitwarden.com/help/secrets-manager-quick-start/> · Updated: 2026-08-06 · Supersedes: none_
