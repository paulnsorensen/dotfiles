### ADR-002: node:test runner + subset JSON-Schema validator, zero npm dependencies  [status: accepted]

- **Context:** The dotfiles repo has no root `package.json` and its test convention is bats; workflow tests are JS. Schema validation of stub fixtures needs a JSON-Schema checker.
- **Decision:** Use Node's builtin `node:test` runner (`tests/workflows/*.test.mjs`, invoked via a thin `tests/workflows-test.sh` that skips when node is absent) and a ~60-line subset validator covering `type/required/properties/items/enum` — the only keywords the shipped workflow scripts use — which throws on any unknown keyword.
- **Alternatives:** (a) bats shelling out to inline node strings — rejected: that is what made `workflows-parse.sh` unreadable. (b) vitest/jest + ajv — rejected: introduces npm dependency management to a repo that has none at root, for a validator subset a small function covers.
- **Consequences:** Zero new packages; tests run anywhere node exists (CI runners preinstall it). Cost: the validator must grow if scripts adopt new schema keywords — the fail-loud unknown-keyword rule turns that into a visible test error rather than silent acceptance.
