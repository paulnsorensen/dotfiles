# ADR-001: Put reusable credentials behind per-consumer system identities

## ADR-001: Put reusable credentials behind per-consumer system identities [status: accepted]

- **Context:** Same-user caches, environment variables, user keychains, and user services are readable or invocable by an adversarial coding agent. Linux user services cannot switch UID; a macOS LaunchDaemon cannot depend on an interactive unlocked user session.
- **Decision:** Run each credential consumer as a system service under its own static identity. Store one credential and one root-owned policy per consumer; expose only a pathname UNIX socket to the daily user.
- **Alternatives:** Keep the hardened user cache from PR #613; use a user service; rely on Keychain/desktop OAuth. All retain a same-UID bearer path or fail headless service requirements.
- **Consequences:** Credential values leave the daily UID and compromise is consumer-bounded. Installation now needs a privileged operator and platform-specific service assets; root and the service manager remain trusted.
