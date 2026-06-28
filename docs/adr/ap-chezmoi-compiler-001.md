# ADR-001: Move live agent deployment from `ap install` to C-lite compile/apply

- **Context:** `ap install` currently combines profile parsing, harness rendering, external source fetching, live file writes, merged-file preservation, manifest cleanup, and dropped-MCP reconciliation. The repo direction is for chezmoi to own live deployment while `ap` keeps the profile and harness compiler responsibilities.
- **Decision:** Add a C-lite pipeline: `ap fetch-sources`, `ap compile`, and `ap apply-compiled`, orchestrated by `dots sync`; make `ap install` fail with migration guidance.
- **Alternatives:** Keeping `ap install` as the live writer preserves current behavior but keeps the ownership boundary unclear. Moving full profile composition into chezmoi would duplicate parser/renderer logic in templates or shell.
- **Consequences:** The live path becomes explicit and drift-checkable, but the migration touches CLI, schema, profiles, chezmoi wrappers, tests, and docs in one PR.
