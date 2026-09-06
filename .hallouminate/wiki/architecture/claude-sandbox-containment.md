# Claude Bash sandbox containment

Status: proposed in `fix/harness-claude-sandbox`; full verification and deployment remain pending.

The proposed default enables strict containment for agent Bash commands.
`allowUnsandboxedCommands: false` blocks retries outside the sandbox.
`failIfUnavailable: true` stops Bash when sandbox support is unavailable.[^1]

The policy retains existing network and write allowances.
An empty `excludedCommands` list removes the old `gh *` exception.
Keeping this key lets the authoritative settings merger accept and replace the old list.

Permission grants reduce approval prompts; they do not replace process containment.
The Bash sandbox covers child processes, not MCP servers or tools.[^1]
This distinction prevents broad MCP grants from being mistaken for sandbox protection.

The strict default can block Linux hosts without required sandbox dependencies.
macOS uses built-in Seatbelt support.[^1]

[^1]: <https://code.claude.com/docs/en/sandboxing>

## Publication canary

A real Claude Code 2.1.261 session uses the proposed strict settings on this macOS host.
The sandbox denies an outside marker write and permits `npm view npm version`.
The sandboxed `gh api /zen` command fails with `x509: OSStatus -26276`.
The same gh command succeeds outside the Claude sandbox.
Setting `SSL_CERT_FILE=/etc/ssl/cert.pem` does not resolve the sandbox failure.[^canary]

The gh compatibility check remains unresolved.
Do not publish this default as fully verified.
Claude documents `enableWeakerNetworkIsolation` for access to the macOS system trust service.
That setting weakens network isolation, so this change does not enable it without an explicit decision.[^trust]

[^canary]: Isolated publication canaries, 2026-09-05; `.cheese/harness-audit-publication-checkpoint.md`.
[^trust]: <https://code.claude.com/docs/en/configuration>; sandbox `enableWeakerNetworkIsolation` reference.
