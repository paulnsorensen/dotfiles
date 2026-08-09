# ADR-002: Authorize provider operations in a local MCP firewall

## ADR-002: Authorize provider operations in a local MCP firewall [status: accepted]

- **Context:** Hosted OAuth and MCP authentication establish a bearer session but do not attest which same-UID agent is calling or enforce the repo's per-tool policy. Socket peer UIDs likewise cannot distinguish same-user agents.
- **Decision:** Give agents a secretless stdio proxy. A root-owned per-consumer broker filters `tools/list` and `tools/call` against a hard ceiling, forwards reads, and holds writes pending an exact one-shot approval.
- **Alternatives:** Direct hosted OAuth; profile-only tool allowlists; a generic credential-fetch API. The first two are bypassable by an adversarial same-UID process, and the last exports the reusable credential the design must contain.
- **Consequences:** Every credentialed operation passes one auditable enforcement point and no API returns a credential value. Upstream tool-name changes fail closed and require policy maintenance.
