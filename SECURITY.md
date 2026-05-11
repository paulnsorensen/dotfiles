# Security policy

This is a personal dotfiles repository. The `main` branch is the only
supported state.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** via GitHub's
private advisory flow:

<https://github.com/paulnsorensen/dotfiles/security/advisories/new>

If that is not available, email <paulnsorensen@gmail.com>.

When reporting, please include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof-of-concept.
- Affected commit SHA.

I aim to acknowledge reports within a reasonable window. Please give
me time to ship a fix before public disclosure.

## Scope

In scope:

- Shell scripts, hooks, and tooling tracked in this repository.

Out of scope:

- Third-party tools installed via `packages.yaml` (report upstream).
- Claude Code itself, MCP servers, and external plugins.
